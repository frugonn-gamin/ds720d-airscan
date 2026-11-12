# Brother DS-720D: reverse engineering for a native AirScan bridge

Source: `BrotherScannerDS720DUSEU_O1.dmg`, a package signed and notarized by Brother on 2021-07-28.

**Legend:** ✅ = confirmed (on the Mac or in the code) · 🔬 = static analysis, not yet verified on the device.

## Vendor driver contents

| Component | Architecture | Problem on macOS 26 / Apple Silicon |
|---|---|---|
| `BrKernel.kext` 2.7 (SCSI pass-through to user space) | x86_64 + arm64e | Third-party kexts are blocked without lowering security (Reduced Security). The kext is installed but not loaded. ✅ |
| `DS-720D.ds` TWAIN source 1.5.5 + `Resources/DS-720D.dylib` (Avision "AvDrv" library) | x86_64 / i386 | Requires Rosetta. Needs the kext. Only TWAIN apps can use it. |
| `DSmobileCapture.app` 3.0 | x86_64 | Requires Rosetta and the kext. |

There is no Image Capture (ICA) module. The scanner is therefore invisible to Image Capture, Preview and Printers & Scanners.

## USB ✅

| Item | Value |
|---|---|
| VID / PID | `04f9:60e2` |
| Serial | readable through `kUSBSerialNumberString` (also stored in the NVM at +0x2e) |
| Interface | mass storage class 08, subclass 06, protocol 0x50 (BOT), 2 bulk endpoints |
| Standard INQUIRY | "Brother / DS-720D / 0.27", peripheral type 0 |
| Fake volume | a 1 MiB read-only FAT volume that macOS mounts as "NO NAME" |

**Holding the interface.** macOS attaches `IOUSBMassStorageDriver` and then the disk stack. Ejecting the volume does not free the interface. `SCSITaskLib` is not published for this device: the GenericIniter runs, but its properties are not merged. The only supported way to drive the scanner from user space is **libusb with root**: kernel driver detach (capture), then BOT. That is the job of `ds720d-usbd`.

## Novatek transport (MsdcNvt) 🔬

The USB controller is a Novatek **NT96226**. Avision commands are not sent as raw SCSI. They are tunneled through 16-byte vendor CDBs with this layout:

```
[op] 07 [addr BE32] [len BE32] [p0 p1 p2 p3 p4 p5]
```

| op | p0 p1 p2 | Purpose |
|---|---|---|
| C5 | FF 02 00 | IN 4 → `"NOVA"` |
| C5 | FF 03..06 | IsLock / IsFinish / Lock / UnLock (IN 16; u32 at 0 = 0x10, u32 at 8 = result) |
| C5 | 02 03 i | SetData(iCmd), OUT |
| C5 | 02 01 i, then 02 02 i | GetData(iCmd), IN; the second stage returns the result |
| C3 | 00 00 00 | Read device memory at `addr`, ≤ 64 KiB per transfer |

**Lock protocol.** SetData and GetData run between Lock and UnLock. IsFinish is polled before UnLock, and between the two GetData stages.

**Meaning of iCmd:**
- 0: Avision CDB (padded to 10 bytes) plus its data.
- 1: status (u32).
- 2: image descriptor `<6I` = status, ?, ?, W, H, addr. Status values: 0 = wait, 1 = data at addr, 2 = abort, 3 = end of page.
- 3 / 4: VID / PID.

## Avision sequence for one sheet 🔬

1. INQUIRY `12 00 00 00 05 00`, then the full length. Then READ NVM `28 00 69 00 0a 0d 00 00 80 00` (serial at +0x2e).
2. MEDIA CHECK `08 00 00 00 02 00`: byte 0, bit 0 = paper present.
3. Lamp: READ `28 00 a0 00 0a 0d 00 00 02 00`. If byte 0 is 0, SEND `2a 00 a0 … 01 00` with payload `01`.
4. SEND colour matrix: `2a 00 83 … 12 00` with the identity matrix (3×3 BE16, 0x0400 = 1.0).
5. SET WINDOW `24 … 4f 00` with a 0x4f-byte payload (see `avision.py: set_window`):
   - full width of 2592 px at 300 dpi, colour 24-bit;
   - Y = 300 or 600 dpi;
   - 11 background lines;
   - for duplex, the line count is doubled and the length gets +125/300".
6. RESERVE `16`, SCAN `1b 00 00 00 00 80`, then a READ loop `28 00 00 00 0a 0d LLLLLL 00` until end of page. In duplex, the READs alternate front / rear.
7. RELEASE `17`, then MEDIA CHECK to move to the next sheet.

**What the firmware does and does not handle:**
- The firmware does the shading. The host sends neither calibration data nor a gamma table.
- On the host side the driver:
  - crops the image (4 px on the left, 11 lines at the top);
  - mirrors the rear side;
  - applies the gamma LUT;
  - scales X for any resolution other than 300 dpi;
  - converts to gray / black-and-white.

## Findings on the real device (2026-11-09) ✅

- **MsdcNvt tunnel validated:** `NOVA`, VID/PID via GetData(3/4), Avision INQUIRY of 165 bytes (peripheral type 06, "BROTHER DS-720D", rev 0.27), NVM with the serial number at +0x2e.
- **Colour, simplex, 300 dpi, A4:** 3,600 lines × 7,776 bytes. Paper detected from line 10 to line 3507.
- **Line-planar data:** each line is R (2,592 bytes), then G (2,592 bytes), then B (2,592 bytes). This matches bit 6 of INQUIRY byte 0x5e (value 0x44). The host interleaves the planes.
- **Linear output:** paper white reads about 175 raw. Converting with Brother's `DS-720D.icc` profile to sRGB gives 246/247/240. For gray and black-and-white, the tone curve is taken from that same profile (a gray ramp passed through ColorSync).
- **Auto-crop:** the area outside the paper reads about 4 (black), so cropping to the paper edges is reliable.
- **Duplex:** each READ returns an 80-line block (descriptor W = 2592, H = 240 plane lines). Blocks **alternate front / back**. A single end of page (`st=3`) closes the whole sheet; we saw 47 + 47 blocks. Waiting for a second end of page leaves a READ pending until the 60 s timeout, and the job aborts → fixed.
- **End-to-end validation** (ImageCaptureCore → eSCL → DS-720D), duplex colour at 200 dpi: 2 JPEG pages in about 15 s, red ink rendered correctly.
- **Installed package v1.1.0 (2026-11-12):** Image Capture → eSCL, grayscale, 150 dpi, duplex. Front 2478×3505, back 2479×3504. The back comes out the right way round, so mirroring the rear side is correct. Grayscale through eSCL is therefore validated as well.
- **Still to check:** native 600 dpi; B&W through eSCL.

## AirScan side ✅

- `escl.py` announces `_uscan._tcp` through `DNSServiceRegister`. By default it is local-only: interface -1, target `localhost`.
- ImageCaptureCore (`tools/icbrowse.swift`) sees the scanner as `ICTransportTypeTCPIP`, with a document feeder unit, duplex, and 150–600 dpi.
- A complete scan through ImageCaptureCore works: an eSCL job, then NextDocument ×2, then 404.

## macOS access rule (2026-11-12) ✅

- **Symptom.** Opening the scanner's USB interface fails for a root service:
  - IOUSBLib: `IOCreatePlugInInterfaceForService` → `0xe00002be`;
  - IOUSBHost: `0xe00002c9`;
  - libusb: `LIBUSB_ERROR_OTHER`.
- **Cause, read in the kernel log:**
  - `sandboxd: tcc_server_message_request_authorization(kTCCServiceSystemPolicyRemovableVolumes) failed: missing 'auth_value'`;
  - then `System Policy: … deny iokit-open-service IOUSBHostInterface`.
- **What macOS requires.** Raw USB access to a mass-storage class interface needs the "Removable Volumes" permission. That permission can only be decided for a program started from the user's session. "Full Disk Access" given to a LaunchDaemon is not enough.
- **Why it worked at first.** The libusb daemon was launched with `sudo` from a terminal app that had Full Disk Access.
- **Dead ends:**
  - user-side "seize" mode (IOUSBHost `DeviceSeize`, no root): refused by the disk driver;
  - a setuid binary: rejected for security reasons.
- **Fix adopted.** A session agent launches the root daemon through a sudo rule restricted to that one command (see README).
