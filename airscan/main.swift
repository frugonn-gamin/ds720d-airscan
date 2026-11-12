// ds720d-airscan — pont AirScan (eSCL + Bonjour) pour le Brother DS-720D.
// Usage : ds720d-airscan [--port 9290] [--lan] [--name "Brother DS-720D"] [--socket /var/run/ds720d-usbd.sock] [--trace]
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

setvbuf(stderr, nil, _IOLBF, 0)
let dateFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f }()
func log(_ s: String) { FileHandle.standardError.write(Data("\(dateFmt.string(from: Date())) ds720d-airscan: \(s)\n".utf8)) }

var port: UInt16 = 9290
var lan = false
var name = DS720D.makeModel
var socketPath = "/var/run/ds720d-usbd.sock"
var trace = false
var args = CommandLine.arguments.dropFirst()
while let a = args.popFirst() {
    switch a {
    case "--port": port = UInt16(args.popFirst() ?? "") ?? port
    case "--lan": lan = true
    case "--name": name = args.popFirst() ?? name
    case "--socket": socketPath = args.popFirst() ?? socketPath
    case "--trace": trace = true
    default:
        FileHandle.standardError.write(Data("usage: ds720d-airscan [--port N] [--lan] [--name NOM] [--socket CHEMIN] [--trace]\n".utf8))
        exit(2)
    }
}

/// Icône du scanneur (celle du pilote Brother si présent).
func loadIcon() -> Data? {
    let url = URL(fileURLWithPath: "/Library/Image Capture/TWAIN Data Sources/DS-720D.ds/Resources/Sheetfed.icns")
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    var best: CGImage?
    for i in 0..<CGImageSourceGetCount(src) {
        if let img = CGImageSourceCreateImageAtIndex(src, i, nil), img.width <= 256, img.width > (best?.width ?? 0) { best = img }
    }
    guard let img = best else { return nil }
    let out = NSMutableData()
    guard let d = CGImageDestinationCreateWithData(out as CFMutableData, UTType.png.identifier as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(d, img, nil)
    return CGImageDestinationFinalize(d) ? out as Data : nil
}

let device = DS720D(socketPath: socketPath)
device.trace = trace
let host = ProcessInfo.processInfo.hostName
let escl = ESCLService(device: device, uuid: "6ad5b8d4-7c2e-4f0e-9a1b-d5720d000001")
escl.icon = loadIcon()

let server = HTTPServer(port: port, lan: lan) { escl.handle($0) }
do { try server.start() } catch { log("\(error)"); exit(1) }
log("eSCL sur \(lan ? "0.0.0.0" : "127.0.0.1"):\(port) — \(lan ? "réseau local" : "ce Mac uniquement")")

// Annonce Bonjour uniquement quand le scanneur est réellement joignable (branché).
let bonjour = BonjourService()
func txtRecord() -> [(String, String)] {
    let h = lan ? host : "localhost"
    return [("txtvers", "1"), ("vers", "2.63"), ("rs", "eSCL"), ("ty", DS720D.makeModel),
            ("pdl", documentFormats.joined(separator: ",")), ("uuid", escl.uuid), ("cs", "color,grayscale,binary"),
            ("is", "adf"), ("duplex", "T"), ("note", ""),
            ("adminurl", "http://\(h):\(port)/"), ("representation", "http://\(h):\(port)/icon.png")]
}
Thread.detachNewThread {
    var last: Bool?
    while true {
        let ok = device.isReachable()
        if ok != last {
            if ok {
                if bonjour.register(name: name, type: "_uscan._tcp", port: port, txt: txtRecord(), localOnly: !lan) {
                    log("scanneur connecté — annoncé sur Bonjour sous « \(name) »")
                }
            } else {
                bonjour.unregister()
                log("scanneur non joignable — annonce Bonjour retirée")
            }
            last = ok
        }
        sleep(5)
    }
}

signal(SIGTERM) { _ in exit(0) }
dispatchMain()
