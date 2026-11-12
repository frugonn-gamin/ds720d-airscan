// Serveur HTTP/1.1 minimal (sockets BSD, un fil par connexion, keep-alive).
import Darwin
import Foundation

struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]   // clés en minuscules
    let body: Data
    let client: String
}

struct HTTPResponse {
    var code: Int
    var body = Data()
    var contentType: String? = nil
    var headers: [String: String] = [:]
    init(_ code: Int, _ body: Data = Data(), type: String? = nil, headers: [String: String] = [:]) {
        self.code = code; self.body = body; self.contentType = type; self.headers = headers
    }
    init(_ code: Int, xml: String) { self.init(code, Data(xml.utf8), type: "text/xml") }
}

final class HTTPServer {
    private let port: UInt16
    private let lan: Bool
    private let handler: (HTTPRequest) -> HTTPResponse
    private var listenFD: Int32 = -1

    init(port: UInt16, lan: Bool, handler: @escaping (HTTPRequest) -> HTTPResponse) {
        self.port = port; self.lan = lan; self.handler = handler
    }

    func start() throws {
        let s = socket(AF_INET, SOCK_STREAM, 0)
        guard s >= 0 else { throw DeviceError("socket TCP impossible") }
        var on: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = lan ? INADDR_ANY : inet_addr("127.0.0.1")
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard r == 0, listen(s, 16) == 0 else {
            close(s)
            throw DeviceError("port \(port) indisponible (\(String(cString: strerror(errno))))")
        }
        listenFD = s
        Thread.detachNewThread { [self] in
            while true {
                var ca = sockaddr_in()
                var len = socklen_t(MemoryLayout<sockaddr_in>.size)
                let fd = withUnsafeMutablePointer(to: &ca) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(listenFD, $0, &len) }
                }
                if fd < 0 { if errno == EINTR { continue }; usleep(100_000); continue }
                let client = String(cString: inet_ntoa(ca.sin_addr))
                Thread.detachNewThread { [self] in serve(fd, client) }
            }
        }
    }

    private func serve(_ fd: Int32, _ client: String) {
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 300, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var buf = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            // en-têtes
            let sep = Data("\r\n\r\n".utf8)
            var headerEnd = buf.range(of: sep)
            while headerEnd == nil {
                let n = read(fd, &chunk, chunk.count)
                if n <= 0 || buf.count > 1 << 20 { return }
                buf.append(chunk, count: n)
                headerEnd = buf.range(of: sep)
            }
            guard let he = headerEnd else { return }
            let head = String(decoding: buf[buf.startIndex..<he.lowerBound], as: UTF8.self)
            buf.removeSubrange(buf.startIndex..<he.upperBound)
            var lines = head.components(separatedBy: "\r\n")
            let reqLine = lines.removeFirst().split(separator: " ")
            guard reqLine.count >= 2 else { return }
            var headers: [String: String] = [:]
            for l in lines {
                if let c = l.firstIndex(of: ":") {
                    headers[l[..<c].lowercased()] = l[l.index(after: c)...].trimmingCharacters(in: .whitespaces)
                }
            }
            let length = Int(headers["content-length"] ?? "0") ?? 0
            while buf.count < length {
                let n = read(fd, &chunk, chunk.count)
                if n <= 0 { return }
                buf.append(chunk, count: n)
            }
            let body = buf.prefix(length)
            buf.removeFirst(length)
            let req = HTTPRequest(method: String(reqLine[0]), path: String(reqLine[1]), headers: headers, body: Data(body), client: client)
            let resp = handler(req)
            log("\(client) \"\(req.method) \(req.path)\" \(resp.code)")
            if !send(fd, resp, head: req.method == "HEAD") { return }
            if headers["connection"]?.lowercased() == "close" { return }
        }
    }

    private func send(_ fd: Int32, _ r: HTTPResponse, head: Bool) -> Bool {
        let reasons = [200: "OK", 201: "Created", 400: "Bad Request", 404: "Not Found", 409: "Conflict",
                       500: "Internal Server Error", 503: "Service Unavailable"]
        var h = "HTTP/1.1 \(r.code) \(reasons[r.code] ?? "Status")\r\nServer: ds720d-airscan/1.0\r\n"
        if let t = r.contentType { h += "Content-Type: \(t)\r\n" }
        h += "Content-Length: \(r.body.count)\r\n"
        for (k, v) in r.headers { h += "\(k): \(v)\r\n" }
        h += "\r\n"
        var out = Data(h.utf8)
        if !head { out.append(r.body) }
        return out.withUnsafeBytes { p -> Bool in
            var off = 0
            while off < out.count {
                let k = write(fd, p.baseAddress! + off, out.count - off)
                if k <= 0 { if k < 0 && errno == EINTR { continue }; return false }
                off += k
            }
            return true
        }
    }
}
