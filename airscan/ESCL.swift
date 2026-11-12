// Protocole eSCL (AirScan) : capacités, état, travaux de numérisation.
import Foundation

let nsScan = "http://schemas.hp.com/imaging/escl/2011/05/03"
let nsPwg = "http://www.pwg.org/schemas/2010/12/sm"
let xmlns = "xmlns:scan=\"\(nsScan)\" xmlns:pwg=\"\(nsPwg)\""
let documentFormats = ["image/jpeg", "application/pdf", "image/png"]

func xmlEscape(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
}

/// Extrait le texte des éléments d'un document XML, indexé par nom local (première occurrence).
final class LocalNameCollector: NSObject, XMLParserDelegate {
    var values: [String: String] = [:]
    private var text = ""
    func parser(_ p: XMLParser, didStartElement e: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) { text = "" }
    func parser(_ p: XMLParser, foundCharacters s: String) { text += s }
    func parser(_ p: XMLParser, didEndElement e: String, namespaceURI: String?, qualifiedName: String?) {
        let local = e.split(separator: ":").last.map(String.init) ?? e
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty && values[local] == nil { values[local] = t }
        text = ""
    }
}

func parseSettings(_ body: Data) -> ScanSettings? {
    let p = XMLParser(data: body)
    p.shouldProcessNamespaces = true
    let c = LocalNameCollector()
    p.delegate = c
    guard p.parse() else { return nil }
    let v = c.values
    var s = ScanSettings()
    if let m = v["ColorMode"], DS720D.colorModes.contains(m) { s.colorMode = m }
    let req = Int(v["XResolution"] ?? "") ?? 300
    s.xres = DS720D.resolutions.min { abs($0 - req) < abs($1 - req) }!
    s.yres = s.xres
    s.width = min(max(Int(v["Width"] ?? "") ?? DS720D.maxWidth, DS720D.minWidth), DS720D.maxWidth)
    s.height = min(max(Int(v["Height"] ?? "") ?? DS720D.defaultHeight, DS720D.minHeight), DS720D.maxHeight)
    s.x = Int(v["XOffset"] ?? "") ?? 0
    s.y = Int(v["YOffset"] ?? "") ?? 0
    s.duplex = (v["Duplex"] ?? "false").lowercased() == "true"
    let fmt = v["DocumentFormatExt"] ?? v["DocumentFormat"] ?? "image/jpeg"
    s.format = documentFormats.contains(fmt) ? fmt : "image/jpeg"
    s.intent = v["Intent"] ?? s.intent
    return s
}

final class ScanJob {
    let id = UUID().uuidString.lowercased()
    let settings: ScanSettings
    let created = Date()
    var state = "Processing", reason = "JobScanning"
    var completed = 0, transferred = 0
    private(set) var cancelled = false
    private var docs: [Data] = []
    private var finished = false
    private let cond = NSCondition()

    init(_ s: ScanSettings) { settings = s }

    func push(_ d: Data) { cond.lock(); docs.append(d); completed += 1; cond.broadcast(); cond.unlock() }
    func finish() { cond.lock(); finished = true; cond.broadcast(); cond.unlock() }
    func cancel() { cond.lock(); cancelled = true; cond.unlock() }

    enum Next { case document(Data), done, timeout }
    func next(timeout: TimeInterval) -> Next {
        cond.lock(); defer { cond.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while docs.isEmpty && !finished {
            if !cond.wait(until: deadline) { return .timeout }
        }
        if docs.isEmpty { return .done }
        transferred += 1
        return .document(docs.removeFirst())
    }
}

final class ESCLService {
    let device: DS720D
    let uuid: String
    var icon: Data?
    private var jobs: [String: ScanJob] = [:]
    private var order: [String] = []
    private let lock = NSLock()

    init(device: DS720D, uuid: String) { self.device = device; self.uuid = uuid }

    func handle(_ r: HTTPRequest) -> HTTPResponse {
        let path = String(r.path.split(separator: "?", maxSplits: 1).first ?? "")
        let parts = path.split(separator: "/").map(String.init)
        let base = "http://\(r.headers["host"] ?? "localhost")"
        switch (r.method, parts.count) {
        case ("GET", 2) where path == "/eSCL/ScannerCapabilities", ("HEAD", 2) where path == "/eSCL/ScannerCapabilities":
            return HTTPResponse(200, xml: capabilities(base))
        case ("GET", 2) where path == "/eSCL/ScannerStatus":
            return HTTPResponse(200, xml: status())
        case ("GET", _) where path == "/icon.png":
            return icon.map { HTTPResponse(200, $0, type: "image/png") } ?? HTTPResponse(404)
        case ("GET", 0):
            let html = "<html><body><h1>\(DS720D.makeModel)</h1><p>Pont AirScan actif. Chargeur : \(device.adfState())</p></body></html>"
            return HTTPResponse(200, Data(html.utf8), type: "text/html; charset=utf-8")
        case ("POST", 2) where path == "/eSCL/ScanJobs":
            return createJob(r.body, base: base)
        case ("GET", 4) where parts[0] == "eSCL" && parts[1] == "ScanJobs" && parts[3] == "NextDocument":
            guard let job = job(parts[2]) else { return HTTPResponse(404) }
            switch job.next(timeout: 180) {
            case .document(let d): return HTTPResponse(200, d, type: job.settings.format)
            case .done: return HTTPResponse(404)
            case .timeout: return HTTPResponse(503, headers: ["Retry-After": "2"])
            }
        case ("GET", 4) where parts[0] == "eSCL" && parts[1] == "ScanJobs" && parts[3] == "ScanImageInfo":
            guard let job = job(parts[2]) else { return HTTPResponse(404) }
            return HTTPResponse(200, xml: "<?xml version=\"1.0\" encoding=\"UTF-8\"?><scan:ScanImageInfo \(xmlns)><pwg:JobUri>/eSCL/ScanJobs/\(job.id)</pwg:JobUri><pwg:JobUuid>\(job.id)</pwg:JobUuid></scan:ScanImageInfo>")
        case ("DELETE", 3) where parts[0] == "eSCL" && parts[1] == "ScanJobs":
            guard let job = job(parts[2]) else { return HTTPResponse(404) }
            job.cancel()
            return HTTPResponse(200)
        default:
            return HTTPResponse(404)
        }
    }

    private func job(_ id: String) -> ScanJob? { lock.lock(); defer { lock.unlock() }; return jobs[id] }

    private func createJob(_ body: Data, base: String) -> HTTPResponse {
        log("ScanSettings : \(String(decoding: body, as: UTF8.self).replacingOccurrences(of: "\n", with: " ").prefix(400))")
        guard let s = parseSettings(body) else { return HTTPResponse(400) }
        if device.busy { return HTTPResponse(503, headers: ["Retry-After": "5"]) }
        if device.adfState() == "ScannerAdfEmpty" { return HTTPResponse(409) }
        let job = ScanJob(s)
        lock.lock()
        jobs[job.id] = job
        order.append(job.id)
        if order.count > 20 { jobs[order.removeFirst()] = nil }
        lock.unlock()
        log("travail \(job.id) : \(s.colorMode) \(s.xres) dpi, \(s.duplex ? "recto-verso" : "recto"), \(s.format)")
        Thread.detachNewThread { [self] in run(job) }
        return HTTPResponse(201, headers: ["Location": "\(base)/eSCL/ScanJobs/\(job.id)"])
    }

    private func run(_ job: ScanJob) {
        let s = job.settings
        do {
            try device.scan(s, emit: { page, rear in
                let t0 = Date()
                do {
                    let doc = try device.render(page, s)
                    job.push(doc)
                    log(String(format: "page %d (%@) : %dx%d -> %d Kio en %.1fs", job.completed, rear ? "verso" : "recto",
                               page.width, page.height, doc.count / 1024, Date().timeIntervalSince(t0)))
                } catch {
                    log("rendu impossible : \(error)")
                }
            }, cancelled: { job.cancelled })
            job.state = job.cancelled ? "Canceled" : "Completed"
            job.reason = job.cancelled ? "JobCanceledByUser" : "JobCompletedSuccessfully"
        } catch {
            log("numérisation interrompue : \(error)")
            job.state = "Aborted"
            job.reason = "AbortedBySystem"
        }
        job.finish()
    }

    func status() -> String {
        lock.lock()
        let recent = order.suffix(10).compactMap { jobs[$0] }
        lock.unlock()
        var js = ""
        for j in recent {
            js += "<scan:JobInfo><pwg:JobUri>/eSCL/ScanJobs/\(j.id)</pwg:JobUri><pwg:JobUuid>\(j.id)</pwg:JobUuid>"
            js += "<scan:Age>\(Int(Date().timeIntervalSince(j.created)))</scan:Age>"
            js += "<pwg:ImagesCompleted>\(j.completed)</pwg:ImagesCompleted>"
            js += "<pwg:ImagesToTransfer>\(max(0, j.completed - j.transferred))</pwg:ImagesToTransfer>"
            js += "<pwg:JobState>\(j.state)</pwg:JobState><pwg:JobStateReasons><pwg:JobStateReason>\(j.reason)</pwg:JobStateReason></pwg:JobStateReasons></scan:JobInfo>"
        }
        return "<?xml version=\"1.0\" encoding=\"UTF-8\"?><scan:ScannerStatus \(xmlns)><pwg:Version>2.63</pwg:Version>"
            + "<pwg:State>\(device.busy ? "Processing" : "Idle")</pwg:State><scan:AdfState>\(device.adfState())</scan:AdfState>"
            + "<scan:Jobs>\(js)</scan:Jobs></scan:ScannerStatus>"
    }

    func capabilities(_ base: String) -> String {
        let res = DS720D.resolutions.map { "<scan:DiscreteResolution><scan:XResolution>\($0)</scan:XResolution><scan:YResolution>\($0)</scan:YResolution></scan:DiscreteResolution>" }.joined()
        let modes = DS720D.colorModes.map { "<scan:ColorMode>\($0)</scan:ColorMode>" }.joined()
        let fmts = documentFormats.map { "<pwg:DocumentFormat>\($0)</pwg:DocumentFormat>" }.joined()
            + documentFormats.map { "<scan:DocumentFormatExt>\($0)</scan:DocumentFormatExt>" }.joined()
        let caps = "<scan:MinWidth>\(DS720D.minWidth)</scan:MinWidth><scan:MaxWidth>\(DS720D.maxWidth)</scan:MaxWidth>"
            + "<scan:MinHeight>\(DS720D.minHeight)</scan:MinHeight><scan:MaxHeight>\(DS720D.maxHeight)</scan:MaxHeight>"
            + "<scan:MaxScanRegions>1</scan:MaxScanRegions><scan:SettingProfiles><scan:SettingProfile>"
            + "<scan:ColorModes>\(modes)</scan:ColorModes><scan:DocumentFormats>\(fmts)</scan:DocumentFormats>"
            + "<scan:SupportedResolutions><scan:DiscreteResolutions>\(res)</scan:DiscreteResolutions></scan:SupportedResolutions>"
            + "<scan:ColorSpaces><scan:ColorSpace>sRGB</scan:ColorSpace></scan:ColorSpaces></scan:SettingProfile></scan:SettingProfiles>"
            + "<scan:SupportedIntents><scan:Intent>Document</scan:Intent><scan:Intent>TextAndGraphic</scan:Intent>"
            + "<scan:Intent>Photo</scan:Intent><scan:Intent>Preview</scan:Intent></scan:SupportedIntents>"
            + "<scan:MaxOpticalXResolution>600</scan:MaxOpticalXResolution><scan:MaxOpticalYResolution>600</scan:MaxOpticalYResolution>"
            + "<scan:RiskyLeftMargin>0</scan:RiskyLeftMargin><scan:RiskyRightMargin>0</scan:RiskyRightMargin>"
            + "<scan:RiskyTopMargin>0</scan:RiskyTopMargin><scan:RiskyBottomMargin>0</scan:RiskyBottomMargin>"
        return "<?xml version=\"1.0\" encoding=\"UTF-8\"?><scan:ScannerCapabilities \(xmlns)>"
            + "<pwg:Version>2.63</pwg:Version><pwg:MakeAndModel>\(DS720D.makeModel)</pwg:MakeAndModel>"
            + "<pwg:SerialNumber>\(xmlEscape(device.serial))</pwg:SerialNumber><scan:UUID>\(uuid)</scan:UUID>"
            + "<scan:AdminURI>\(base)/</scan:AdminURI><scan:IconURI>\(base)/icon.png</scan:IconURI>"
            + "<scan:Adf><scan:AdfSimplexInputCaps>\(caps)</scan:AdfSimplexInputCaps><scan:AdfDuplexInputCaps>\(caps)</scan:AdfDuplexInputCaps>"
            + "<scan:FeederCapacity>1</scan:FeederCapacity><scan:AdfOptions><scan:AdfOption>DetectPaperLoaded</scan:AdfOption>"
            + "<scan:AdfOption>Duplex</scan:AdfOption></scan:AdfOptions></scan:Adf></scan:ScannerCapabilities>"
    }
}
