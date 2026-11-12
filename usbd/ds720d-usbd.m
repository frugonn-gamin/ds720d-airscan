/*
 * ds720d-usbd — démon root minimal donnant un accès SCSI (Bulk-Only Transport) au
 * scanneur Brother DS-720D (Avision/Novatek) sans kext ni bibliothèque tierce.
 *
 * Le DS-720D se présente en USB comme un périphérique de stockage de masse
 * (classe 08/06/50) et macOS y attache IOUSBMassStorageDriver. La capture « en place »
 * (IOUSBHost DeviceCapture) ne détache pas les pilotes de stockage de masse ; on
 * procède donc comme libusb : démontage du petit volume du scanneur, puis
 * USBDeviceReEnumerate(kUSBReEnumerateCaptureDeviceMask) — le périphérique revient
 * « capturé », sans aucun pilote noyau — puis SetConfiguration et USBInterfaceOpen.
 * À l'arrêt, kUSBReEnumerateReleaseDeviceMask le rend à macOS.
 *
 * Protocole socket (little-endian) :
 *   requête : "DSQ1" op:u8 cdblen:u8 dir:u8 lun:u8 len:u32 timeout_ms:u32 cdb[16] [+ len octets si OUT]
 *   réponse : "DSR1" result:i32 csw:u8 pad[3] payload:u32 residue:u32 [+ payload octets]
 *   op : 1 = SCSI, 2 = RESET (BOT reset recovery), 3 = INFO ; dir : 0 aucun, 1 IN, 2 OUT
 */
#import <Foundation/Foundation.h>
#import <IOKit/IOCFPlugIn.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/usb/IOUSBLib.h>
#import <IOUSBHost/IOUSBHost.h>

#include <errno.h>
#include <grp.h>
#include <signal.h>
#include <stdarg.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

#define DEFAULT_SOCK "/var/run/ds720d-usbd.sock"
#define BROTHER_VID 0x04f9
#define MAX_XFER (64u * 1024u * 1024u)

enum { OP_SCSI = 1, OP_RESET = 2, OP_INFO = 3 };
enum { DIR_NONE = 0, DIR_IN = 1, DIR_OUT = 2 };
enum { RES_OK = 0, RES_NODEV = -4, RES_IO = -1, RES_DENIED = -100, RES_BADOP = -101 };

typedef IOUSBDeviceInterface650 **DevIf;
typedef IOUSBInterfaceInterface800 **IntfIf;

static const uint16_t known_pids[] = { 0x60e2 /* DS-720D */ };

static DevIf gDev;                    /* voie A : IOUSBLib */
static IntfIf gIntf;
static UInt8 gPipeIn, gPipeOut, gIfNum;
static IOUSBHostDevice *hDev;         /* voie B : IOUSBHost */
static IOUSBHostInterface *hIntf;
static IOUSBHostPipe *hIn, *hOut;
static int gOpen;                     /* 0 fermé, 1 IOUSBLib, 2 IOUSBHost */
static int gCaptured;                 /* le scanneur a été soustrait à macOS */
static uint16_t gPid, gForcedPid;
static char gSerial[128];
static uint32_t gTag = 1;
static int gAllowAll;
static time_t gRetryAfter;   /* temporisation après un échec, pour ne pas réinitialiser le scanneur en boucle */
static volatile sig_atomic_t gStop;

static void logmsg(const char *fmt, ...) {
    char ts[32];
    time_t t = time(NULL);
    strftime(ts, sizeof ts, "%Y-%m-%d %H:%M:%S", localtime(&t));
    fprintf(stderr, "%s ds720d-usbd: ", ts);
    va_list ap;
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
}

static void put32(uint8_t *p, uint32_t v) { p[0] = v; p[1] = v >> 8; p[2] = v >> 16; p[3] = v >> 24; }
static uint32_t get32(const uint8_t *p) { return p[0] | (p[1] << 8) | (p[2] << 16) | ((uint32_t)p[3] << 24); }

static int pid_wanted(uint16_t pid) {
    if (gForcedPid) return pid == gForcedPid;
    for (size_t i = 0; i < sizeof known_pids / sizeof *known_pids; i++)
        if (known_pids[i] == pid) return 1;
    return 0;
}

static uint16_t int_prop(io_registry_entry_t e, CFStringRef key) {
    uint16_t v = 0;
    CFTypeRef r = IORegistryEntryCreateCFProperty(e, key, kCFAllocatorDefault, 0);
    if (r && CFGetTypeID(r) == CFNumberGetTypeID()) CFNumberGetValue(r, kCFNumberSInt16Type, &v);
    if (r) CFRelease(r);
    return v;
}

static io_service_t find_device(void) {
    io_iterator_t it;
    if (IOServiceGetMatchingServices(MACH_PORT_NULL, IOServiceMatching("IOUSBHostDevice"), &it) != KERN_SUCCESS)
        return 0;
    io_service_t s, found = 0;
    while ((s = IOIteratorNext(it))) {
        if (!found && int_prop(s, CFSTR("idVendor")) == BROTHER_VID && pid_wanted(int_prop(s, CFSTR("idProduct")))) {
            found = s;
            continue;
        }
        IOObjectRelease(s);
    }
    IOObjectRelease(it);
    return found;
}

/* Vrai si un pilote noyau est attaché au périphérique ou à l'une de ses interfaces. */
static int has_kernel_driver(io_service_t dev) {
    io_iterator_t it;
    if (IORegistryEntryCreateIterator(dev, kIOServicePlane, kIORegistryIterateRecursively, &it) != KERN_SUCCESS) return 0;
    io_registry_entry_t e;
    int found = 0;
    while ((e = IOIteratorNext(it))) {
        if (IOObjectConformsTo(e, "IOUSBMassStorageInterfaceNub") || IOObjectConformsTo(e, "AppleUSBHostCompositeDevice"))
            found = 1;
        IOObjectRelease(e);
    }
    IOObjectRelease(it);
    return found;
}

/* Démonte proprement le petit volume FAT du scanneur (évite l'alerte « disque non éjecté »). */
static void unmount_scanner_volume(io_service_t dev) {
    io_iterator_t it;
    if (IORegistryEntryCreateIterator(dev, kIOServicePlane, kIORegistryIterateRecursively, &it) != KERN_SUCCESS) return;
    io_registry_entry_t e;
    while ((e = IOIteratorNext(it))) {
        if (IOObjectConformsTo(e, "IOMedia")) {
            CFTypeRef whole = IORegistryEntryCreateCFProperty(e, CFSTR("Whole"), kCFAllocatorDefault, 0);
            CFTypeRef bsd = IORegistryEntryCreateCFProperty(e, CFSTR("BSD Name"), kCFAllocatorDefault, 0);
            if (whole == kCFBooleanTrue && bsd && CFGetTypeID(bsd) == CFStringGetTypeID()) {
                NSString *disk = [@"/dev/" stringByAppendingString:(__bridge NSString *)bsd];
                NSTask *t = [NSTask launchedTaskWithExecutableURL:[NSURL fileURLWithPath:@"/usr/sbin/diskutil"]
                                                        arguments:@[@"unmountDisk", @"force", disk] error:nil
                                               terminationHandler:nil];
                [t waitUntilExit];
                logmsg("volume du scanneur démonté (%s)", disk.UTF8String);
            }
            if (whole) CFRelease(whole);
            if (bsd) CFRelease(bsd);
        }
        IOObjectRelease(e);
    }
    IOObjectRelease(it);
}

static DevIf create_dev_if(io_service_t svc) {
    IOCFPlugInInterface **plug = NULL;
    SInt32 score;
    kern_return_t kr = IOCreatePlugInInterfaceForService(svc, kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID, &plug, &score);
    if (kr != KERN_SUCCESS || !plug) { logmsg("plugin IOUSBDevice : 0x%08x", kr); return NULL; }
    DevIf d = NULL;
    HRESULT hr = (*plug)->QueryInterface(plug, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID650), (LPVOID *)&d);
    IODestroyPlugInInterface(plug);
    if (hr || !d) { logmsg("QueryInterface IOUSBDevice650 : 0x%08x", (unsigned)hr); return NULL; }
    return d;
}

static IntfIf create_intf_if(io_service_t svc, int verbose) {
    IOCFPlugInInterface **plug = NULL;
    SInt32 score;
    kern_return_t kr = IOCreatePlugInInterfaceForService(svc, kIOUSBInterfaceUserClientTypeID, kIOCFPlugInInterfaceID, &plug, &score);
    if (kr != KERN_SUCCESS || !plug) {
        if (verbose) {
            CFTypeRef types = IORegistryEntryCreateCFProperty(svc, CFSTR("IOCFPlugInTypes"), kCFAllocatorDefault, 0);
            logmsg("plugin IOUSBInterface : 0x%08x (IOCFPlugInTypes %s)", kr, types ? "présent" : "absent");
            if (types) CFRelease(types);
        }
        return NULL;
    }
    IntfIf i = NULL;
    HRESULT hr = (*plug)->QueryInterface(plug, CFUUIDGetUUIDBytes(kIOUSBInterfaceInterfaceID942), (LPVOID *)&i);
    if (hr || !i) hr = (*plug)->QueryInterface(plug, CFUUIDGetUUIDBytes(kIOUSBInterfaceInterfaceID800), (LPVOID *)&i);
    IODestroyPlugInInterface(plug);
    if (hr || !i) { if (verbose) logmsg("QueryInterface IOUSBInterface : 0x%08x", (unsigned)hr); return NULL; }
    return i;
}

static io_service_t find_interface_child(io_service_t dev) {
    io_iterator_t it;
    if (IORegistryEntryGetChildIterator(dev, kIOServicePlane, &it) != KERN_SUCCESS) return 0;
    io_service_t c, found = 0;
    while ((c = IOIteratorNext(it))) {
        if (!found && IOObjectConformsTo(c, "IOUSBHostInterface")) { found = c; continue; }
        IOObjectRelease(c);
    }
    IOObjectRelease(it);
    return found;
}

/* Ferme l'interface et les objets IOUSBHost, et ferme (sans le libérer) le périphérique IOUSBLib :
   le client qui a demandé la capture doit rester vivant, comme le fait libusb. */
static void close_interfaces(void) {
    if (gIntf) { (*gIntf)->USBInterfaceClose(gIntf); (*gIntf)->Release(gIntf); gIntf = NULL; }
    hIn = hOut = nil;
    if (hIntf) { [hIntf destroy]; hIntf = nil; }
    if (hDev) { [hDev destroy]; hDev = nil; }
    if (gDev) (*gDev)->USBDeviceClose(gDev);
    gOpen = 0;
}

/* Ferme tout et rend le scanneur à macOS (pilote de stockage et petit volume reviennent). */
static void close_device(void) {
    close_interfaces();
    if (gDev) {
        if (gCaptured) (*gDev)->USBDeviceReEnumerate(gDev, kUSBReEnumerateReleaseDeviceMask);
        (*gDev)->Release(gDev);
        gDev = NULL;
        if (gCaptured) logmsg("périphérique rendu à macOS");
    }
    gCaptured = 0;
}

static uint64_t gCurID, gFailedID;   /* entrée de registre du périphérique (change à chaque branchement) */
static int gFailures;   /* échecs consécutifs : délai progressif 30 s, 1, 2, 4, 8 puis 10 min */

static int fail_open(const char *what, IOReturn kr) {
    int delay = 30 << (gFailures < 5 ? gFailures : 5);
    if (delay > 600) delay = 600;
    gFailures++;
    gFailedID = gCurID;
    logmsg("%s (0x%08x) — nouvel essai dans %d s", what, kr, delay);
    int was_captured = gCaptured;
    close_device();
    /* Rendu à macOS, le scanneur réapparaît sous une nouvelle entrée de registre : on la note pour
       ne pas la confondre avec un rebranchement par l'utilisateur. */
    for (int i = 0; was_captured && i < 50; i++) {
        usleep(100000);
        io_service_t s = find_device();
        if (!s) continue;
        uint64_t id = 0;
        IORegistryEntryGetRegistryEntryID(s, &id);
        IOObjectRelease(s);
        if (id != gCurID) { gFailedID = id; break; }
    }
    gRetryAfter = time(NULL) + delay;
    return RES_IO;
}

/* Voie A : IOUSBLib, séquence de libusb (darwin_restore_state) : même client périphérique,
   fermé puis rouvert après la capture. */
static int open_iousblib(io_service_t svc) {
    IOReturn kr;
    UInt8 cur = 0;
    (*gDev)->GetConfiguration(gDev, &cur);
    if (cur == 0) {
        IOUSBConfigurationDescriptorPtr cfg = NULL;
        UInt8 value = 1;
        if ((*gDev)->GetConfigurationDescriptorPtr(gDev, 0, &cfg) == kIOReturnSuccess && cfg) value = cfg->bConfigurationValue;
        kr = (*gDev)->SetConfiguration(gDev, value);
        logmsg("A : configuration %u appliquée (0x%08x)", value, kr);
    }
    for (int i = 0; i < 30 && !gIntf; i++) {
        IOUSBFindInterfaceRequest req = { kIOUSBFindInterfaceDontCare, kIOUSBFindInterfaceDontCare,
                                          kIOUSBFindInterfaceDontCare, kIOUSBFindInterfaceDontCare };
        io_iterator_t it;
        io_service_t ifsvc = 0;
        if ((*gDev)->CreateInterfaceIterator(gDev, &req, &it) == kIOReturnSuccess) { ifsvc = IOIteratorNext(it); IOObjectRelease(it); }
        if (!ifsvc) ifsvc = find_interface_child(svc);
        if (ifsvc) { gIntf = create_intf_if(ifsvc, i == 0 || i == 29); IOObjectRelease(ifsvc); }
        else if (i == 0 || i == 29) logmsg("A : aucune interface publiée (essai %d)", i);
        if (!gIntf) usleep(100000);
    }
    if (!gIntf) return 0;
    for (int i = 0; i < 20; i++) {
        kr = (*gIntf)->USBInterfaceOpen(gIntf);
        if (kr == kIOReturnSuccess) break;
        usleep(100000);
    }
    if (kr != kIOReturnSuccess) { logmsg("A : USBInterfaceOpen : 0x%08x", kr); return 0; }
    (*gIntf)->GetInterfaceNumber(gIntf, &gIfNum);
    UInt8 n = 0;
    gPipeIn = gPipeOut = 0;
    (*gIntf)->GetNumEndpoints(gIntf, &n);
    for (UInt8 ref = 1; ref <= n; ref++) {
        UInt8 dir, num, type, interval;
        UInt16 mps;
        if ((*gIntf)->GetPipeProperties(gIntf, ref, &dir, &num, &type, &mps, &interval) != kIOReturnSuccess) continue;
        if (type != kUSBBulk) continue;
        if (dir == kUSBIn) gPipeIn = ref; else if (dir == kUSBOut) gPipeOut = ref;
    }
    if (!gPipeIn || !gPipeOut) { logmsg("A : endpoints bulk introuvables"); return 0; }
    gOpen = 1;
    return 1;
}

/* Voie B : IOUSBHost (le périphérique est déjà capturé, aucun pilote n'occupe l'interface). */
static int open_iousbhost(io_service_t svc) {
    NSError *err = nil;
    hDev = [[IOUSBHostDevice alloc] initWithIOService:svc options:IOUSBHostObjectInitOptionsNone
                                                queue:nil error:&err interestHandler:nil];
    if (!hDev) { logmsg("B : IOUSBHostDevice : %s (0x%08x)", err.localizedDescription.UTF8String, (unsigned)err.code); return 0; }
    for (int i = 0; i < 30 && !hIntf; i++) {
        io_service_t ifsvc = find_interface_child(svc);
        if (!ifsvc) {
            if (i == 2) {
                BOOL ok = [hDev configureWithValue:1 matchInterfaces:NO error:&err];
                logmsg("B : configuration appliquée (%s)", ok ? "OK" : err.localizedDescription.UTF8String);
            }
            usleep(100000);
            continue;
        }
        hIntf = [[IOUSBHostInterface alloc] initWithIOService:ifsvc options:IOUSBHostObjectInitOptionsNone
                                                        queue:nil error:&err interestHandler:nil];
        IOObjectRelease(ifsvc);
        if (!hIntf) {
            if (i == 0 || i == 29) logmsg("B : IOUSBHostInterface : %s (0x%08x)", err.localizedDescription.UTF8String, (unsigned)err.code);
            usleep(100000);
        }
    }
    if (!hIntf) return 0;
    const IOUSBInterfaceDescriptor *ifd = hIntf.interfaceDescriptor;
    const IOUSBConfigurationDescriptor *cfd = hIntf.configurationDescriptor;
    gIfNum = ifd ? ifd->bInterfaceNumber : 0;
    uint8_t epIn = 0x81, epOut = 0x02;
    if (ifd && cfd) {
        const IOUSBEndpointDescriptor *ep = NULL;
        while ((ep = IOUSBGetNextEndpointDescriptor(cfd, ifd, (const IOUSBDescriptorHeader *)ep))) {
            if ((ep->bmAttributes & 3) != kIOUSBEndpointTypeBulk) continue;
            if (ep->bEndpointAddress & 0x80) epIn = ep->bEndpointAddress; else epOut = ep->bEndpointAddress;
        }
    }
    hIn = [hIntf copyPipeWithAddress:epIn error:&err];
    hOut = [hIntf copyPipeWithAddress:epOut error:&err];
    if (!hIn || !hOut) { logmsg("B : pipes bulk : %s", err.localizedDescription.UTF8String); return 0; }
    gOpen = 2;
    return 1;
}

static int open_device(void) {
    if (gOpen) return RES_OK;
    io_service_t svc = find_device();
    if (!svc) return RES_NODEV;
    IORegistryEntryGetRegistryEntryID(svc, &gCurID);
    if (gCurID == gFailedID && time(NULL) < gRetryAfter) { IOObjectRelease(svc); return RES_IO; }
    if (gCurID != gFailedID && gFailedID) { gFailures = 0; logmsg("nouveau branchement détecté, nouvel essai immédiat"); }
    gPid = int_prop(svc, CFSTR("idProduct"));
    gSerial[0] = 0;
    CFTypeRef sn = IORegistryEntryCreateCFProperty(svc, CFSTR(kUSBSerialNumberString), kCFAllocatorDefault, 0);
    if (sn && CFGetTypeID(sn) == CFStringGetTypeID()) CFStringGetCString(sn, gSerial, sizeof gSerial, kCFStringEncodingUTF8);
    if (sn) CFRelease(sn);

    /* Un seul client périphérique, conservé de la capture jusqu'à la libération (comme libusb). */
    if (!gDev) gDev = create_dev_if(svc);
    if (!gDev) { IOObjectRelease(svc); return fail_open("interface IOUSBDevice indisponible", kIOReturnError); }
    /* Séquence exacte de libusb (darwin_open + darwin_reenumerate_device + darwin_restore_state) :
       périphérique ouvert AVANT la capture, puis fermé et rouvert après. */
    IOReturn kr = (*gDev)->USBDeviceOpenSeize(gDev);
    if (kr != kIOReturnSuccess) logmsg("USBDeviceOpenSeize (avant capture) : 0x%08x", kr);
    if (!gCaptured) {
        if (has_kernel_driver(svc)) unmount_scanner_volume(svc);
        kr = (*gDev)->USBDeviceReEnumerate(gDev, kUSBReEnumerateCaptureDeviceMask);
        if (kr != kIOReturnSuccess) { IOObjectRelease(svc); return fail_open("capture du périphérique refusée (root requis)", kr); }
        gCaptured = 1;
        /* La capture ne ré-énumère pas : on attend seulement le retrait des pilotes macOS. */
        int i = 0;
        while (has_kernel_driver(svc) && i++ < 100) usleep(100000);
        if (has_kernel_driver(svc)) { IOObjectRelease(svc); return fail_open("les pilotes macOS ne se sont pas détachés", kIOReturnTimeout); }
        logmsg("scanneur capturé (pilotes macOS détachés)");
        (*gDev)->USBDeviceClose(gDev);
        kr = (*gDev)->USBDeviceOpenSeize(gDev);
        if (kr != kIOReturnSuccess) logmsg("USBDeviceOpenSeize (après capture) : 0x%08x", kr);
    }

    int ok = open_iousblib(svc);
    if (!ok) {
        close_interfaces();
        logmsg("voie IOUSBLib indisponible, essai par IOUSBHost");
        ok = open_iousbhost(svc);
    }
    IOObjectRelease(svc);
    if (!ok) return fail_open("ouverture de l'interface USB impossible", kIOReturnNotFound);
    gRetryAfter = 0;
    gFailures = 0;
    logmsg("DS prêt via %s (pid 0x%04x, série '%s', interface %u)", gOpen == 1 ? "IOUSBLib" : "IOUSBHost", gPid, gSerial, gIfNum);
    return RES_OK;
}

static int fatal_code(IOReturn c) {
    return c == kIOReturnNoDevice || c == kIOReturnNotResponding || c == kIOReturnNotOpen ||
           c == kIOReturnOffline || c == kIOReturnNotAttached;
}

static void clear_stall(int in) {
    if (gOpen == 2) [(in ? hIn : hOut) clearStallWithError:nil];
    else if (gOpen == 1) (*gIntf)->ClearPipeStallBothEnds(gIntf, in ? gPipeIn : gPipeOut);
}

static IOReturn bulk(int in, void *buf, uint32_t len, uint32_t tmo, uint32_t *done) {
    if (gOpen == 2) {
        NSError *err = nil;
        NSUInteger n = 0;
        NSMutableData *d = len ? [NSMutableData dataWithBytesNoCopy:buf length:len freeWhenDone:NO] : nil;
        BOOL ok = [(in ? hIn : hOut) sendIORequestWithData:d bytesTransferred:&n completionTimeout:tmo / 1000.0 error:&err];
        if (done) *done = (uint32_t)n;
        return ok ? kIOReturnSuccess : (IOReturn)(err ? err.code : kIOReturnError);
    }
    IOReturn kr;
    if (in) {
        UInt32 size = len;
        kr = (*gIntf)->ReadPipeTO(gIntf, gPipeIn, buf, &size, tmo, tmo);
        if (done) *done = size;
    } else {
        kr = (*gIntf)->WritePipeTO(gIntf, gPipeOut, buf, len, tmo, tmo);
        if (done) *done = kr == kIOReturnSuccess ? len : 0;
    }
    if (kr == kIOUSBTransactionTimeout) clear_stall(in);
    return kr;
}

static void reset_recovery(void) {
    if (gOpen == 2) {
        IOUSBDeviceRequest req = { .bmRequestType = 0x21, .bRequest = 0xff, .wValue = 0, .wIndex = gIfNum, .wLength = 0 };
        [hIntf sendDeviceRequest:req data:nil bytesTransferred:NULL completionTimeout:2 error:nil];
    } else if (gOpen == 1) {
        IOUSBDevRequestTO req = {0};
        req.bmRequestType = USBmakebmRequestType(kUSBOut, kUSBClass, kUSBInterface);
        req.bRequest = 0xff;
        req.wIndex = gIfNum;
        req.noDataTimeout = req.completionTimeout = 2000;
        (*gIntf)->ControlRequestTO(gIntf, 0, &req);
    } else {
        return;
    }
    clear_stall(1);
    clear_stall(0);
}

static int bot_exec(const uint8_t *cdb, uint8_t cdblen, uint8_t lun, uint8_t dir, uint8_t *data, uint32_t len,
                    uint32_t tmo, uint8_t *csw_status, uint32_t *actual, uint32_t *residue) {
    if (!tmo) tmo = 30000;
    uint8_t cbw[31] = {0};
    uint32_t tag = gTag++;
    put32(cbw, 0x43425355);
    put32(cbw + 4, tag);
    put32(cbw + 8, dir == DIR_NONE ? 0 : len);
    cbw[12] = dir == DIR_IN ? 0x80 : 0x00;
    cbw[13] = lun & 0x0f;
    cbw[14] = cdblen;
    memcpy(cbw + 15, cdb, cdblen);
    *actual = 0;

    uint32_t n = 0;
    IOReturn kr = bulk(0, cbw, sizeof cbw, 5000, &n);
    if (kr) {
        if (kr == kIOUSBPipeStalled) reset_recovery();
        return fatal_code(kr) ? RES_NODEV : RES_IO;
    }
    if (dir != DIR_NONE && len) {
        kr = bulk(dir == DIR_IN, data, len, tmo, &n);
        if (kr == kIOUSBPipeStalled) clear_stall(dir == DIR_IN);
        else if (kr) return fatal_code(kr) ? RES_NODEV : RES_IO;
        *actual = n;
    }
    uint8_t csw[512];
    for (int attempt = 0; attempt < 2; attempt++) {
        kr = bulk(1, csw, sizeof csw, tmo, &n);
        if (kr == kIOUSBPipeStalled) { clear_stall(1); continue; }
        break;
    }
    if (kr) return fatal_code(kr) ? RES_NODEV : RES_IO;
    if (n != 13 || get32(csw) != 0x53425355 || get32(csw + 4) != tag) {
        logmsg("CSW invalide (len %u)", n);
        reset_recovery();
        return RES_IO;
    }
    *residue = get32(csw + 8);
    *csw_status = csw[12];
    if (*csw_status == 2) reset_recovery();
    return RES_OK;
}

static int read_full(int fd, void *buf, size_t n) {
    uint8_t *p = buf;
    while (n) {
        ssize_t k = read(fd, p, n);
        if (k <= 0) { if (k < 0 && errno == EINTR) continue; return -1; }
        p += k; n -= (size_t)k;
    }
    return 0;
}
static int write_full(int fd, const void *buf, size_t n) {
    const uint8_t *p = buf;
    while (n) {
        ssize_t k = write(fd, p, n);
        if (k <= 0) { if (k < 0 && errno == EINTR) continue; return -1; }
        p += k; n -= (size_t)k;
    }
    return 0;
}

static void serve_client(int fd) {
    for (;;) @autoreleasepool {
        uint8_t hdr[32];
        if (read_full(fd, hdr, sizeof hdr)) return;
        if (memcmp(hdr, "DSQ1", 4)) { logmsg("requête invalide"); return; }
        uint8_t op = hdr[4], cdblen = hdr[5], dir = hdr[6], lun = hdr[7];
        uint32_t len = get32(hdr + 8), tmo = get32(hdr + 12);
        const uint8_t *cdb = hdr + 16;
        if (len > MAX_XFER || cdblen > 16 || dir > DIR_OUT) { logmsg("paramètres invalides"); return; }
        uint8_t *buf = NULL;
        if (len) {
            buf = malloc(len);
            if (!buf) return;
            if (dir == DIR_OUT && read_full(fd, buf, len)) { free(buf); return; }
        }
        int32_t result = RES_OK;
        uint8_t csw = 0xff;
        uint32_t actual = 0, residue = 0;
        char info[256];
        if (op == OP_INFO) {
            result = open_device();
            snprintf(info, sizeof info, "vid=0x%04x pid=0x%04x serial=%s connected=%d", BROTHER_VID, gPid, gSerial, gOpen != 0);
            actual = (uint32_t)strlen(info);
        } else if (op == OP_RESET) {
            if ((result = open_device()) == RES_OK) reset_recovery();
        } else if (op == OP_SCSI) {
            if (!gAllowAll && cdb[0] == 0x3b) {     /* WRITE BUFFER (firmware) refusé */
                logmsg("commande 0x%02x refusée", cdb[0]);
                result = RES_DENIED;
            } else if ((result = open_device()) == RES_OK) {
                result = bot_exec(cdb, cdblen, lun, dir, buf, len, tmo, &csw, &actual, &residue);
                if (result == RES_NODEV) {
                    logmsg("scanneur déconnecté");
                    close_interfaces();
                    if (gDev) { (*gDev)->Release(gDev); gDev = NULL; }
                    gCaptured = 0;
                }
            }
        } else {
            result = RES_BADOP;
        }
        uint8_t rh[20] = {'D', 'S', 'R', '1'};
        put32(rh + 4, (uint32_t)result);
        rh[8] = csw;
        uint32_t payload = op == OP_INFO ? actual : (op == OP_SCSI && dir == DIR_IN && result == RES_OK) ? actual : 0;
        put32(rh + 12, payload);
        put32(rh + 16, residue);
        int bad = write_full(fd, rh, sizeof rh);
        if (!bad && payload) bad = write_full(fd, op == OP_INFO ? (const void *)info : buf, payload);
        free(buf);
        if (bad) return;
    }
}

static void on_signal(int s) { (void)s; gStop = 1; }

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *sock_path = DEFAULT_SOCK, *group = "staff";
        for (int i = 1; i < argc; i++) {
            if (!strcmp(argv[i], "-s") && i + 1 < argc) sock_path = argv[++i];
            else if (!strcmp(argv[i], "-g") && i + 1 < argc) group = argv[++i];
            else if (!strcmp(argv[i], "-p") && i + 1 < argc) gForcedPid = (uint16_t)strtoul(argv[++i], NULL, 0);
            else if (!strcmp(argv[i], "--allow-all")) gAllowAll = 1;
            else { fprintf(stderr, "usage: %s [-s socket] [-g groupe] [-p pid] [--allow-all]\n", argv[0]); return 2; }
        }
        setvbuf(stderr, NULL, _IOLBF, 0);
        struct sigaction sa = {0};
        sa.sa_handler = on_signal;   /* sans SA_RESTART : accept() est interrompu */
        sigaction(SIGTERM, &sa, NULL);
        sigaction(SIGINT, &sa, NULL);
        signal(SIGPIPE, SIG_IGN);

        int ls = socket(AF_UNIX, SOCK_STREAM, 0);
        struct sockaddr_un sun = {0};
        sun.sun_family = AF_UNIX;
        strlcpy(sun.sun_path, sock_path, sizeof sun.sun_path);
        unlink(sock_path);
        if (bind(ls, (struct sockaddr *)&sun, sizeof sun) || listen(ls, 4)) {
            logmsg("socket %s: %s", sock_path, strerror(errno));
            return 1;
        }
        struct group *gr = getgrnam(group);
        if (gr && geteuid() == 0) chown(sock_path, 0, gr->gr_gid);
        chmod(sock_path, 0660);
        logmsg("en écoute sur %s (groupe %s)", sock_path, group);
        open_device();
        while (!gStop) {
            int fd = accept(ls, NULL, NULL);
            if (fd < 0) { if (errno == EINTR) continue; break; }
            serve_client(fd);
            close(fd);
        }
        close_device();
        close(ls);
        unlink(sock_path);
        logmsg("arrêt");
    }
    return 0;
}
