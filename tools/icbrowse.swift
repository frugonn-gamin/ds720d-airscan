// Liste les scanneurs vus par ImageCaptureCore (la pile native utilisée par Transfert d'images / Aperçu).
// Usage : swift icbrowse.swift [secondes] [nom-a-ouvrir]
import Foundation
import ImageCaptureCore

final class Browser: NSObject, ICDeviceBrowserDelegate, ICScannerDeviceDelegate {
    let browser = ICDeviceBrowser()
    let target: String?
    init(target: String?) {
        self.target = target
        super.init()
        browser.delegate = self
        let mask = ICDeviceTypeMask.scanner.rawValue
            | ICDeviceLocationTypeMask.local.rawValue
            | ICDeviceLocationTypeMask.shared.rawValue
            | ICDeviceLocationTypeMask.bonjour.rawValue
            | ICDeviceLocationTypeMask.bluetooth.rawValue
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue: mask)!
        browser.start()
    }
    func deviceBrowser(_ b: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        print("+ \(device.name ?? "?") | transport=\(device.transportType ?? "?") | type=\(device.type.rawValue)")
        if let t = target, device.name?.contains(t) == true, let s = device as? ICScannerDevice {
            s.delegate = self
            s.requestOpenSession()
        }
    }
    func deviceBrowser(_ b: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {}
    func didRemove(_ device: ICDevice) {}
    func device(_ device: ICDevice, didOpenSessionWithError error: (any Error)?) {
        print("  session ouverte: \(error.map { "\($0)" } ?? "OK")")
        guard let s = device as? ICScannerDevice else { return }
        for u in s.availableFunctionalUnitTypes {
            print("  unité fonctionnelle disponible: \(u)")
        }
    }
    func device(_ device: ICDevice, didCloseSessionWithError error: (any Error)?) {}
    func scannerDevice(_ scanner: ICScannerDevice, didSelect functionalUnit: ICScannerFunctionalUnit, error: (any Error)?) {
        let fu = functionalUnit
        print("  unité sélectionnée: type=\(fu.type.rawValue) résolutions=\(fu.supportedResolutions.map { String($0) }.joined(separator: ","))")
        if let f = fu as? ICScannerFunctionalUnitDocumentFeeder {
            print("  chargeur: recto-verso=\(f.supportsDuplexScanning) papier=\(f.documentLoaded)")
            if let dir = ProcessInfo.processInfo.environment["SCAN_TO"] {
                f.resolution = 200
                f.pixelDataType = .RGB
                f.bitDepth = .depth8Bits
                f.duplexScanningEnabled = true
                f.documentType = .typeA4
                scanner.transferMode = .fileBased
                scanner.downloadsDirectory = URL(fileURLWithPath: dir)
                scanner.documentName = "scan"
                scanner.documentUTI = "public.jpeg"
                print("  lancement d'une numérisation vers \(dir)")
                scanner.requestScan()
            }
        }
    }
    func scannerDevice(_ scanner: ICScannerDevice, didScanTo url: URL) {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        print("  page reçue: \(url.lastPathComponent) (\(size) octets)")
    }
    func scannerDevice(_ scanner: ICScannerDevice, didCompleteScanWithError error: (any Error)?) {
        print("  numérisation terminée: \(error.map { "\($0)" } ?? "OK")")
    }
}

let secs = CommandLine.arguments.count > 1 ? Double(CommandLine.arguments[1]) ?? 8 : 8
let target = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : nil
let b = Browser(target: target)
RunLoop.main.run(until: Date().addingTimeInterval(secs))
_ = b
