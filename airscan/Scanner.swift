// Logique de numérisation du DS-720D et rendu des pages (ImageIO / ColorSync).
//
// Constats sur l'appareil réel :
//  * données en plans par ligne (R 2592 o, G 2592 o, B 2592 o) si le bit 6 de l'octet 0x5e de l'INQUIRY est mis ;
//  * sortie linéaire : le profil ICC Brother (s'il est installé) ou les courbes ToneLUT la ramènent en sRGB ;
//  * fond hors papier quasi noir (~4) -> recadrage automatique ;
//  * recto-verso : blocs alternés recto / verso, une seule fin de page pour la feuille ; verso en miroir.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct ScanSettings {
    var colorMode = "RGB24"      // RGB24 | Grayscale8 | BlackAndWhite1
    var xres = 300, yres = 300
    var x = 0, y = 0             // unités : 1/300 de pouce
    var width = 2550, height = 3508
    var duplex = false
    var format = "image/jpeg"
    var intent = "Document"
}

struct RawPage {
    let width: Int, height: Int, ydpi: Int
    var rgb: [UInt8]            // RGB entrelacé, 3 o / pixel
}

final class DS720D {
    static let makeModel = "Brother DS-720D"
    static let resolutions = [150, 200, 300, 600]
    static let colorModes = ["RGB24", "Grayscale8", "BlackAndWhite1"]
    static let minWidth = 650, maxWidth = 2550, minHeight = 1063, maxHeight = 9600, defaultHeight = 3508
    static let iccPath = "/Library/Image Capture/TWAIN Data Sources/DS-720D.ds/Resources/icc/DS-720D.icc"
    static let autocrop = ProcessInfo.processInfo.environment["DS720D_AUTOCROP"] != "0"

    let socketPath: String
    let lock = NSLock()
    private(set) var busy = false
    private(set) var serial = "inconnu"
    private var transport: Transport?
    private var av: Avision?
    private var planar = true
    let iccSpace: CGColorSpace?
    var trace = false

    init(socketPath: String) {
        self.socketPath = socketPath
        if let d = FileManager.default.contents(atPath: DS720D.iccPath) {
            iccSpace = CGColorSpace(iccData: d as CFData)
        } else {
            iccSpace = nil
        }
    }

    private func connect() throws -> Avision {
        if let a = av { return a }
        let t = Transport(path: socketPath)
        let a = Avision(MsdcNvt(t))
        a.trace = trace
        guard try a.nvt.isAvailable() else { throw DeviceError("le DS-720D ne répond pas au protocole Novatek") }
        let inq = try a.inquiry()
        planar = inq.count > 0x5E && inq[0x5E] & 0x40 != 0
        let nvm = try a.readNVM()
        let sn = nvm[0x2E..<min(nvm.count, 0x2E + 20)].prefix { $0 != 0 }
        serial = String(decoding: sn, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        transport = t
        av = a
        log("DS-720D prêt (série \(serial), données \(planar ? "planaires" : "entrelacées"), profil ICC \(iccSpace != nil ? "Brother" : "intégré"))")
        return a
    }

    private func reset() {
        transport?.close()
        transport = nil
        av = nil
    }

    /// Exécute une opération sur le scanneur ; en cas d'erreur, la connexion est réinitialisée.
    private func withDevice<T>(_ f: (Avision) throws -> T) throws -> T {
        do { return try f(try connect()) } catch { reset(); throw error }
    }

    func isReachable() -> Bool {
        if busy { return true }
        lock.lock(); defer { lock.unlock() }
        return (try? withDevice { try $0.nvt.isAvailable() }) ?? false
    }

    func adfState() -> String {
        if busy { return "ScannerAdfProcessing" }
        lock.lock(); defer { lock.unlock() }
        guard let loaded = try? withDevice({ try $0.paperLoaded() }) else { return "ScannerAdfEmpty" }
        return loaded ? "ScannerAdfLoaded" : "ScannerAdfEmpty"
    }

    // MARK: numérisation

    func scan(_ s: ScanSettings, emit: (RawPage, Bool) -> Void, cancelled: () -> Bool) throws {
        lock.lock()
        busy = true
        defer { busy = false; lock.unlock() }
        try withDevice { av in
            guard try av.paperLoaded() else { throw DeviceError("pas de papier dans le chargeur") }
            try av.ensureLamp()
            try av.sendColorMatrix()
            let yres = s.yres > 300 ? 600 : 300
            while !cancelled() {
                let sides = try scanSheet(av, s, yres)
                for (i, raw) in sides.enumerated() where raw.count >= Avision.pixels * 3 {
                    emit(process(raw, s, yres: yres, rear: i == 1), i == 1)
                }
                if try !av.paperLoaded() { break }
            }
        }
    }

    private func scanSheet(_ av: Avision, _ s: ScanSettings, _ yres: Int) throws -> [[UInt8]] {
        try av.setWindow(yres: yres, length300: s.y + s.height, duplex: s.duplex)
        try av.reserve()
        try av.startScan()
        let bpl = Avision.pixels * 3
        let chunk = (2 * 1024 * 1024 / bpl) * bpl
        var bufs: [[UInt8]] = [[], []]
        bufs[0].reserveCapacity(bpl * 4000)
        if s.duplex { bufs[1].reserveCapacity(bpl * 4000) }
        var n = 0
        var done = false
        do {
            while !done {
                let side = s.duplex ? n % 2 : 0
                // Constaté : les blocs alternent recto/verso, une seule fin de page clôt la feuille.
                done = try av.readImage(chunk, into: &bufs[side])
                n += 1
                if n > 4000 { throw DeviceError("flux image interminable") }
            }
        } catch {
            try? av.release(cancel: true)
            throw error
        }
        try av.release()
        if trace { log("feuille lue en \(n) blocs : recto \(bufs[0].count) o, verso \(bufs[1].count) o") }
        return s.duplex ? bufs : [bufs[0]]
    }

    private func process(_ raw: [UInt8], _ s: ScanSettings, yres: Int, rear: Bool) -> RawPage {
        let P = Avision.pixels, bpl = P * 3
        let lines = raw.count / bpl
        var rgb = [UInt8](repeating: 0, count: lines * bpl)
        let planar = self.planar
        raw.withUnsafeBufferPointer { src in
            rgb.withUnsafeMutableBufferPointer { dst in
                for yy in 0..<lines {
                    let o = yy * bpl
                    for x in 0..<P {
                        let d = o + 3 * (rear ? P - 1 - x : x)
                        if planar {
                            dst[d] = src[o + x]; dst[d + 1] = src[o + P + x]; dst[d + 2] = src[o + 2 * P + x]
                        } else {
                            dst[d] = src[o + 3 * x]; dst[d + 1] = src[o + 3 * x + 1]; dst[d + 2] = src[o + 3 * x + 2]
                        }
                    }
                }
            }
        }
        var left: Int, top: Int, right: Int, bottom: Int
        if DS720D.autocrop {
            (left, top, right, bottom) = paperBox(rgb, lines)
        } else {
            left = Avision.leftSkip + s.x
            right = min(P, left + s.width)
            top = Avision.bgLines + s.y * yres / 300
            bottom = min(lines, top + s.height * yres / 300)
        }
        let w = max(1, right - left), h = max(1, bottom - top)
        var out = [UInt8](repeating: 0, count: w * h * 3)
        rgb.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                for yy in 0..<h {
                    let so = (top + yy) * bpl + left * 3
                    let dob = yy * w * 3
                    for i in 0..<(w * 3) { dst[dob + i] = src[so + i] }
                }
            }
        }
        return RawPage(width: w, height: h, ydpi: yres, rgb: out)
    }

    /// Boîte englobante du papier (le fond du scanneur est noir).
    private func paperBox(_ rgb: [UInt8], _ lines: Int) -> (Int, Int, Int, Int) {
        let P = Avision.pixels, bpl = P * 3, threshold = 20
        return rgb.withUnsafeBufferPointer { px -> (Int, Int, Int, Int) in
            var rows: [Int] = []
            for yy in 0..<lines {
                var sum = 0, cnt = 0
                var x = 0
                while x < P { sum += Int(px[yy * bpl + 3 * x + 1]); cnt += 1; x += 8 }
                if sum / cnt > threshold { rows.append(yy) }
            }
            guard let top = rows.first, let last = rows.last else { return (0, 0, P, lines) }
            let bottom = last + 1
            let step = max(1, (bottom - top) / 64)
            var col = [Int](repeating: 0, count: P)
            var cnt = 0
            var yy = top
            while yy < bottom {
                for x in 0..<P { col[x] += Int(px[yy * bpl + 3 * x + 1]) }
                cnt += 1
                yy += step
            }
            let cols = (0..<P).filter { col[$0] / cnt > threshold }
            guard let l = cols.first, let r = cols.last else { return (0, top, P, bottom) }
            return (l, top, r + 1, bottom)
        }
    }

    // MARK: rendu

    /// Convertit une page brute (linéaire, 300 dpi horizontaux) en document au format demandé.
    func render(_ page: RawPage, _ s: ScanSettings) throws -> Data {
        var pixels = page.rgb
        let srcSpace: CGColorSpace
        if let icc = iccSpace {
            srcSpace = icc
        } else {
            pixels.withUnsafeMutableBufferPointer { p in
                var i = 0
                while i < p.count {
                    p[i] = toneLUTR[Int(p[i])]; p[i + 1] = toneLUTG[Int(p[i + 1])]; p[i + 2] = toneLUTB[Int(p[i + 2])]
                    i += 3
                }
            }
            srcSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let src = CGImage(width: page.width, height: page.height, bitsPerComponent: 8, bitsPerPixel: 24,
                                bytesPerRow: page.width * 3, space: srcSpace,
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { throw DeviceError("création de l'image impossible") }

        let tw = max(1, page.width * s.xres / 300)
        let th = max(1, page.height * s.yres / page.ydpi)
        let gray = s.colorMode != "RGB24"
        let space = gray ? CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)! : CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: tw, height: th, bitsPerComponent: 8,
                                  bytesPerRow: gray ? 0 : tw * 4, space: space,
                                  bitmapInfo: gray ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw DeviceError("contexte graphique impossible") }
        ctx.interpolationQuality = .high
        ctx.draw(src, in: CGRect(x: 0, y: 0, width: tw, height: th))
        if s.colorMode == "BlackAndWhite1", let d = ctx.data {
            let p = d.assumingMemoryBound(to: UInt8.self)
            for yy in 0..<th {
                let row = p + yy * ctx.bytesPerRow
                for x in 0..<tw { row[x] = row[x] < 150 ? 0 : 255 }
            }
        }
        guard let img = ctx.makeImage() else { throw DeviceError("rendu impossible") }
        return try encode(img, format: s.format, dpi: s.xres)
    }

    private func encode(_ img: CGImage, format: String, dpi: Int) throws -> Data {
        let out = NSMutableData()
        if format == "application/pdf" {
            var box = CGRect(x: 0, y: 0, width: Double(img.width) * 72 / Double(dpi), height: Double(img.height) * 72 / Double(dpi))
            guard let consumer = CGDataConsumer(data: out as CFMutableData),
                  let pdf = CGContext(consumer: consumer, mediaBox: &box, nil) else { throw DeviceError("PDF impossible") }
            pdf.beginPDFPage(nil)
            pdf.draw(img, in: box)
            pdf.endPDFPage()
            pdf.closePDF()
            return out as Data
        }
        let type = format == "image/png" ? UTType.png : UTType.jpeg
        guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, type.identifier as CFString, 1, nil)
        else { throw DeviceError("encodeur indisponible") }
        let props: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.85,
            kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi,
        ]
        CGImageDestinationAddImage(dest, img, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw DeviceError("encodage impossible") }
        return out as Data
    }
}
