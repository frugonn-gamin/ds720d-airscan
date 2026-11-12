// Protocole du DS-720D reconstitué par rétro-ingénierie d'AvDrv (voir docs/PROTOCOLE.md).
//  * MsdcNvt : tunnel Novatek NT96226 (CDB vendeur 16 o : op 07 addr BE32 len BE32 p0..p5)
//  * Avision : commandes SCSI Avision passées via SetData(0)/GetData(0), statut GetData(1),
//              images via GetData(2) + lecture mémoire (C3).
import Foundation

final class MsdcNvt {
    let t: Transport
    init(_ t: Transport) { self.t = t }

    private func cdb(_ op: UInt8, _ addr: UInt32, _ len: Int, _ p: [UInt8]) -> [UInt8] {
        [op, 0x07] + be32Bytes(addr) + be32Bytes(UInt32(len)) + p + [UInt8](repeating: 0, count: 6 - p.count)
    }
    func rawIn(_ op: UInt8, _ addr: UInt32, _ len: Int, _ p: [UInt8]) throws -> [UInt8] {
        try t.cmd(cdb(op, addr, len, p), dir: .input, length: len)
    }
    func rawOut(_ op: UInt8, _ addr: UInt32, _ data: [UInt8], _ p: [UInt8]) throws {
        _ = try t.cmd(cdb(op, addr, data.count, p), dir: .output, data: data)
    }

    func isAvailable() throws -> Bool { try rawIn(0xC5, 0, 4, [0xFF, 0x02, 0x00]) == Array("NOVA".utf8) }

    private func flag(_ sub: UInt8) throws -> UInt32 {
        let r = try rawIn(0xC5, 0, 16, [0xFF, sub, 0x00])
        guard r.count >= 12, le32(r, 0) == 0x10 else { throw DeviceError("réponse MsdcNvt inattendue") }
        return le32(r, 8)
    }
    func isLock() throws -> Bool { try flag(0x03) != 0 }
    func isFinish() throws -> Bool { try flag(0x04) != 0 }
    func lock() throws -> Bool { try flag(0x05) != 0 }
    func unlock() throws { _ = try flag(0x06) }

    private func open() throws {
        if try isFinish() {
            var n = 0
            while try isLock(), n < 1000 { usleep(10_000); n += 1 }
            if try isLock() { try unlock() }
        }
        for _ in 0..<3000 {
            if try lock() { return }
            usleep(10_000)
        }
        throw DeviceError("verrou MsdcNvt indisponible")
    }
    private func close() throws {
        for _ in 0..<600 {
            if try isFinish() { break }
            usleep(100_000)
        }
        try unlock()
    }

    func setData(_ icmd: UInt8, _ data: [UInt8]) throws {
        try open()
        defer { try? close() }
        try rawOut(0xC5, 0, data, [0x02, 0x03, icmd])
    }

    func getData(_ icmd: UInt8, _ n: Int) throws -> [UInt8] {
        try open()
        defer { try? close() }
        _ = try rawIn(0xC5, 0, n, [0x02, 0x01, icmd])
        for _ in 0..<30000 {
            if try isFinish() { break }
            usleep(10_000)
        }
        return try rawIn(0xC5, 0, n, [0x02, 0x02, icmd])
    }

    func memRead(_ addr: UInt32, _ n: Int, into out: inout [UInt8]) throws {
        var done = 0
        while done < n {
            let k = min(0x10000, n - done)
            out += try rawIn(0xC3, addr + UInt32(done), k, [0, 0, 0])
            done += k
        }
    }
}

final class Avision {
    static let pixels = 2592     // largeur capteur à 300 dpi
    static let bgLines = 11
    static let leftSkip = 4
    let nvt: MsdcNvt
    var trace = false
    private(set) var inquiryData: [UInt8] = []

    init(_ nvt: MsdcNvt) { self.nvt = nvt }

    private static let senseText: [UInt16: String] = [
        0x8001: "bourrage papier", 0x8002: "capot ouvert", 0x8003: "pas de papier", 0x8004: "fin de page",
        0x8005: "double alimentation", 0x8009: "bourrage papier", 0x8015: "fin de page + double alimentation",
    ]

    static func read10(_ dtc: UInt8, _ qual: UInt16, _ len: Int) -> [UInt8] {
        [0x28, 0, dtc, 0, UInt8(qual >> 8), UInt8(qual & 0xff), UInt8(len >> 16 & 0xff), UInt8(len >> 8 & 0xff), UInt8(len & 0xff), 0]
    }
    static func send10(_ dtc: UInt8, _ qual: UInt16, _ len: Int) -> [UInt8] {
        [0x2A, 0, dtc, 0, UInt8(qual >> 8), UInt8(qual & 0xff), UInt8(len >> 16 & 0xff), UInt8(len >> 8 & 0xff), UInt8(len & 0xff), 0]
    }

    private func pad10(_ c: [UInt8]) -> [UInt8] { c + [UInt8](repeating: 0, count: max(0, 10 - c.count)) }

    @discardableResult
    func doIo(_ cdb: [UInt8], out: [UInt8] = [], inLen: Int = 0) throws -> [UInt8] {
        let c = pad10(cdb)
        try nvt.setData(0, c + out)
        let data = inLen > 0 ? try nvt.getData(0, inLen) : []
        let status = le32(try nvt.getData(1, 4), 0)
        if trace { log("av CDB \(c.prefix(6).map { String(format: "%02x", $0) }.joined(separator: " ")) -> \(status)") }
        if status != 0 && c[0] != 0x03 {
            throw senseError(try requestSense(), cdb: c)
        }
        return data
    }

    func requestSense() throws -> [UInt8] {
        try nvt.setData(0, pad10([0x03, 0, 0, 0, 0x16, 0]))
        let s = try nvt.getData(0, 0x16)
        _ = try nvt.getData(1, 4)
        return s
    }

    private func senseError(_ s: [UInt8], cdb: [UInt8]) -> DeviceError {
        guard s.count >= 14 else { return DeviceError("erreur scanneur (commande \(String(format: "%02x", cdb[0])))") }
        let code = UInt16(s[12]) << 8 | UInt16(s[13])
        let txt = Avision.senseText[code] ?? String(format: "erreur scanneur (sense %02x/%02x/%02x)", s[2] & 0xf, s[12], s[13])
        return DeviceError(txt, asc: (s[12], s[13]))
    }

    func inquiry() throws -> [UInt8] {
        let head = try doIo([0x12, 0, 0, 0, 5, 0], inLen: 5)
        let n = min(Int(head[4]) + 5, 0xA5)
        inquiryData = try doIo([0x12, 0, 0, 0, UInt8(n), 0], inLen: n)
        return inquiryData
    }
    func readNVM() throws -> [UInt8] { try doIo(Avision.read10(0x69, 0x0A0D, 0x80), inLen: 0x80) }
    func paperLoaded() throws -> Bool { try doIo([0x08, 0, 0, 0, 2, 0], inLen: 2)[0] & 1 == 1 }
    func ensureLamp() throws {
        if try doIo(Avision.read10(0xA0, 0x0A0D, 2), inLen: 2)[0] == 0 {
            try doIo(Avision.send10(0xA0, 0, 1), out: [1])
        }
    }
    func sendColorMatrix() throws {
        let ident: [UInt8] = [4, 0, 0, 0, 0, 0, 0, 0, 4, 0, 0, 0, 0, 0, 0, 0, 4, 0]
        try doIo(Avision.send10(0x83, 0, 18), out: ident)
    }

    func setWindow(yres: Int, length300: Int, duplex: Bool, pages: Int = 1) throws {
        var w = [UInt8](repeating: 0, count: 0x4F)
        func be16(_ o: Int, _ v: Int) { w[o] = UInt8(v >> 8 & 0xff); w[o + 1] = UInt8(v & 0xff) }
        func be32(_ o: Int, _ v: Int) { be16(o, v >> 16); be16(o + 2, v & 0xffff) }
        let length = length300 + (duplex ? 125 : 0)
        w[7] = 0x47
        be16(0x0A, 300); be16(0x0C, yres)
        be32(0x0E, 0); be32(0x12, 0); be32(0x16, Avision.pixels * 4); be32(0x1A, length * 4)
        w[0x1E] = 0x80; w[0x1F] = 0x80; w[0x20] = 0x80
        w[0x21] = 5; w[0x22] = 8; w[0x25] = 0x03
        w[0x30] = 0xFF; w[0x31] = 0x1D
        w[0x32] = 0x80 | 0x40 | 0x20
        w[0x33] = 0xFF
        let bpl = Avision.pixels * 3
        var lines = length * yres / 300
        if duplex { lines *= 2 }
        be16(0x35, bpl & 0xffff); be16(0x37, lines & 0xffff)
        w[0x39] = 0x10
        be16(0x3B, 100); be16(0x3D, 100); be16(0x3F, 100)
        w[0x41] = duplex ? 0x10 : 0
        w[0x43] = UInt8(bpl >> 16 & 0xff); w[0x44] = UInt8(lines >> 16 & 0xff)
        w[0x45] = UInt8(Avision.bgLines)
        w[0x46] = UInt8(pages)
        try doIo([0x24, 0, 0, 0, 0, 0, 0, 0, 0x4F, 0], out: w)
    }

    func reserve() throws { try doIo([0x16, 0, 0, 0, 0, 0]) }
    func release(cancel: Bool = false) throws { try doIo([0x17, 0, 0, 0, 0, cancel ? 1 : 0]) }
    func startScan() throws { try doIo([0x1B, 0, 0, 0, 0, 0x80]) }

    /// Lit un bloc d'image (CAsicIO::DoImage) et l'ajoute à `into`. Retourne vrai en fin de page.
    func readImage(_ length: Int, into buf: inout [UInt8], timeout: TimeInterval = 30) throws -> Bool {
        try nvt.setData(0, Avision.read10(0x00, 0x0A0D, length))
        let t0 = Date()
        var eop = false
        while true {
            let info = try nvt.getData(2, 24)
            let st = le32(info, 0), w = le32(info, 12), h = le32(info, 16), addr = le32(info, 20)
            if st == 0 {
                if Date().timeIntervalSince(t0) > timeout { throw DeviceError("délai dépassé en attente des données image") }
                usleep(5_000)
                continue
            }
            if st == 1 { try nvt.memRead(addr, Int(w) * Int(h), into: &buf) }
            else if st == 2 { throw DeviceError("lecture interrompue par le scanneur") }
            else if st == 3 { eop = true }
            else { throw DeviceError("statut image inconnu \(st)") }
            break
        }
        if le32(try nvt.getData(1, 4), 0) != 0 {
            let s = try requestSense()
            if s.count >= 14, s[12] == 0x80, s[13] == 0x04 || s[13] == 0x15 { eop = true }
            else { throw senseError(s, cdb: Avision.read10(0, 0x0A0D, length)) }
        }
        return eop
    }
}
