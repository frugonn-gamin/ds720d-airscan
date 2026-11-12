// Client du socket Unix de ds720d-usbd : exécute des CDB SCSI sur le DS-720D.
import Darwin
import Foundation

enum Dir: UInt8 { case none = 0, input = 1, output = 2 }

struct DeviceError: Error, CustomStringConvertible {
    let description: String
    var asc: (UInt8, UInt8)? = nil
    init(_ d: String, asc: (UInt8, UInt8)? = nil) { description = d; self.asc = asc }
}

@inline(__always) func le32(_ b: [UInt8], _ o: Int) -> UInt32 {
    UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
}
@inline(__always) func le32Bytes(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xff), UInt8(v >> 8 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 24)] }
@inline(__always) func be32Bytes(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)] }

final class Transport {
    let path: String
    private var fd: Int32 = -1

    init(path: String) { self.path = path }
    deinit { close() }

    func close() {
        if fd >= 0 { Darwin.close(fd); fd = -1 }
    }

    private func connect() throws {
        if fd >= 0 { return }
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { throw DeviceError("socket() a échoué") }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { p in
            for (i, b) in bytes.prefix(p.count - 1).enumerated() { p[i] = b }
        }
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if r != 0 {
            Darwin.close(s)
            throw DeviceError("ds720d-usbd injoignable (\(path))")
        }
        var on: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        fd = s
    }

    private func writeAll(_ d: [UInt8]) throws {
        var off = 0
        try d.withUnsafeBytes { p in
            while off < d.count {
                let k = write(fd, p.baseAddress! + off, d.count - off)
                if k <= 0 {
                    if k < 0 && errno == EINTR { continue }
                    throw DeviceError("écriture vers ds720d-usbd interrompue")
                }
                off += k
            }
        }
    }

    private func readAll(_ n: Int) throws -> [UInt8] {
        var out = [UInt8](repeating: 0, count: n)
        var off = 0
        try out.withUnsafeMutableBytes { p in
            while off < n {
                let k = read(fd, p.baseAddress! + off, n - off)
                if k <= 0 {
                    if k < 0 && errno == EINTR { continue }
                    throw DeviceError("ds720d-usbd a fermé la connexion")
                }
                off += k
            }
        }
        return out
    }

    struct Reply { let result: Int32; let csw: UInt8; let data: [UInt8] }

    func call(op: UInt8, cdb: [UInt8] = [], dir: Dir = .none, length: Int = 0, data: [UInt8] = [],
              timeoutMs: UInt32 = 30000) throws -> Reply {
        try connect()
        do {
            var hdr = Array("DSQ1".utf8)
            let len = dir == .output ? data.count : length
            hdr += [op, UInt8(cdb.count), dir.rawValue, 0]
            hdr += le32Bytes(UInt32(len)) + le32Bytes(timeoutMs)
            hdr += cdb + [UInt8](repeating: 0, count: 16 - cdb.count)
            try writeAll(dir == .output ? hdr + data : hdr)
            let rh = try readAll(20)
            guard Array(rh[0..<4]) == Array("DSR1".utf8) else { throw DeviceError("réponse ds720d-usbd invalide") }
            let result = Int32(bitPattern: le32(rh, 4))
            let payload = Int(le32(rh, 12))
            let body = payload > 0 ? try readAll(payload) : []
            return Reply(result: result, csw: rh[8], data: body)
        } catch {
            close()
            throw error
        }
    }

    func info() throws -> String {
        String(decoding: try call(op: 3).data, as: UTF8.self)
    }

    func cmd(_ cdb: [UInt8], dir: Dir = .none, length: Int = 0, data: [UInt8] = [], timeoutMs: UInt32 = 30000) throws -> [UInt8] {
        let r = try call(op: 1, cdb: cdb, dir: dir, length: length, data: data, timeoutMs: timeoutMs)
        if r.result == -4 { throw DeviceError("scanneur non connecté") }
        if r.result != 0 { throw DeviceError("erreur de transport USB (\(r.result))") }
        if r.csw != 0 { throw DeviceError("le scanneur a refusé la commande \(String(format: "%02x", cdb.first ?? 0))") }
        return r.data
    }
}
