// Annonce Bonjour _uscan._tcp (eSCL / AirScan) via dns_sd.
import dnssd
import Foundation

final class BonjourService {
    private var ref: DNSServiceRef?
    var isRegistered: Bool { ref != nil }

    func register(name: String, type: String, port: UInt16, txt: [(String, String)], localOnly: Bool) -> Bool {
        if ref != nil { return true }
        var record: [UInt8] = []
        for (k, v) in txt {
            let e = Array("\(k)=\(v)".utf8.prefix(255))
            record.append(UInt8(e.count))
            record += e
        }
        // Local uniquement : visible sur ce Mac, cible « localhost » (le serveur n'écoute que sur 127.0.0.1).
        let iface: UInt32 = localOnly ? UInt32.max : 0
        var r: DNSServiceRef?
        let err: DNSServiceErrorType = record.withUnsafeBytes { rec in
            if localOnly {
                return DNSServiceRegister(&r, 0, iface, name, type, nil, "localhost.", port.bigEndian,
                                          UInt16(record.count), rec.baseAddress, nil, nil)
            }
            return DNSServiceRegister(&r, 0, iface, name, type, nil, nil, port.bigEndian,
                                      UInt16(record.count), rec.baseAddress, nil, nil)
        }
        guard err == kDNSServiceErr_NoError, let r else {
            log("Bonjour : échec de l'annonce (\(err))")
            return false
        }
        DNSServiceSetDispatchQueue(r, DispatchQueue.global())
        ref = r
        return true
    }

    func unregister() {
        if let r = ref { DNSServiceRefDeallocate(r); ref = nil }
    }
}
