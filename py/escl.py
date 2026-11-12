"""Serveur eSCL (AirScan) : expose un scanneur local à Transfert d'images, Aperçu, etc.

Usage : python3 escl.py [--backend demo|ds720d] [--port 8090] [--lan]
"""
import argparse
import os
import queue
import socket
import subprocess
import sys
import threading
import time
import traceback
import uuid
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from xml.sax.saxutils import escape

import bonjour
import imageenc

NS_SCAN = "http://schemas.hp.com/imaging/escl/2011/05/03"
NS_PWG = "http://www.pwg.org/schemas/2010/12/sm"
XMLNS = f'xmlns:scan="{NS_SCAN}" xmlns:pwg="{NS_PWG}"'
FORMATS = ["image/jpeg", "application/pdf", "image/png"]


def log(*a):
    print(time.strftime("%H:%M:%S"), *a, file=sys.stderr, flush=True)


@dataclass
class ScanSettings:
    color_mode: str = "RGB24"
    xres: int = 300
    yres: int = 300
    x: int = 0  # unités : 1/300 de pouce
    y: int = 0
    width: int = 2550
    height: int = 3300
    duplex: bool = False
    fmt: str = "image/jpeg"
    intent: str = "Document"
    source: str = "Feeder"


def parse_settings(body: bytes, backend) -> ScanSettings:
    root = ET.fromstring(body)

    def find(name):
        for el in root.iter():
            if el.tag.split("}")[-1] == name and el.text:
                return el.text.strip()
        return None

    s = ScanSettings()
    s.color_mode = find("ColorMode") or s.color_mode
    if s.color_mode not in backend.color_modes:
        s.color_mode = "RGB24"
    s.xres = int(find("XResolution") or s.xres)
    s.yres = int(find("YResolution") or s.xres)
    if s.xres not in backend.resolutions:
        s.xres = min(backend.resolutions, key=lambda r: abs(r - s.xres))
    s.yres = s.xres
    s.width = int(find("Width") or backend.max_width)
    s.height = int(find("Height") or backend.default_height)
    s.x = int(find("XOffset") or 0)
    s.y = int(find("YOffset") or 0)
    s.duplex = (find("Duplex") or "false").lower() == "true"
    fmt = find("DocumentFormatExt") or find("DocumentFormat") or "image/jpeg"
    s.fmt = fmt if fmt in FORMATS else "image/jpeg"
    s.intent = find("Intent") or s.intent
    s.source = find("InputSource") or s.source
    s.width = max(backend.min_width, min(s.width, backend.max_width))
    s.height = max(backend.min_height, min(s.height, backend.max_height))
    return s


class Job:
    def __init__(self, settings: ScanSettings):
        self.id = str(uuid.uuid4())
        self.settings = settings
        self.docs = queue.Queue()
        self.cancelled = threading.Event()
        self.state = "Processing"
        self.reason = "JobScanning"
        self.created = time.time()
        self.completed = 0
        self.transferred = 0
        self.error = None


class Scanner:
    def __init__(self, backend):
        self.backend = backend
        self.jobs = {}
        self.lock = threading.Lock()
        self.active = None

    def start_job(self, settings):
        with self.lock:
            if self.active and self.active.state == "Processing":
                return None, 503
            job = Job(settings)
            self.jobs[job.id] = job
            self.active = job
        threading.Thread(target=self._run, args=(job,), daemon=True).start()
        return job, 201

    def _run(self, job):
        s = job.settings

        def emit(page):
            if job.cancelled.is_set():
                return
            t0 = time.time()
            doc = imageenc.encode(page, s.fmt)
            job.completed += 1
            log(f"page {job.completed}: {page.width}x{page.height} {page.mode} -> {s.fmt} {len(doc)} o ({time.time()-t0:.1f}s)")
            job.docs.put(doc)

        try:
            self.backend.scan(s, emit, job.cancelled)
            job.state = "Canceled" if job.cancelled.is_set() else "Completed"
            job.reason = "JobCanceledByUser" if job.cancelled.is_set() else "JobCompletedSuccessfully"
        except Exception as e:  # noqa: BLE001
            log("erreur de numérisation:", e)
            traceback.print_exc()
            job.error = str(e)
            job.state = "Aborted"
            job.reason = "AbortedBySystem"
        finally:
            job.docs.put(None)

    def status_xml(self):
        jobs = ""
        for j in list(self.jobs.values())[-10:]:
            jobs += (f"<scan:JobInfo><pwg:JobUri>/eSCL/ScanJobs/{j.id}</pwg:JobUri>"
                     f"<pwg:JobUuid>{j.id}</pwg:JobUuid><scan:Age>{int(time.time()-j.created)}</scan:Age>"
                     f"<pwg:ImagesCompleted>{j.completed}</pwg:ImagesCompleted>"
                     f"<pwg:ImagesToTransfer>{max(0, j.completed - j.transferred)}</pwg:ImagesToTransfer>"
                     f"<pwg:JobState>{j.state}</pwg:JobState><pwg:JobStateReasons>"
                     f"<pwg:JobStateReason>{j.reason}</pwg:JobStateReason></pwg:JobStateReasons></scan:JobInfo>")
        busy = self.active and self.active.state == "Processing"
        return (f'<?xml version="1.0" encoding="UTF-8"?><scan:ScannerStatus {XMLNS}>'
                f"<pwg:Version>2.63</pwg:Version><pwg:State>{'Processing' if busy else 'Idle'}</pwg:State>"
                f"<scan:AdfState>{self.backend.adf_state()}</scan:AdfState>"
                f"<scan:Jobs>{jobs}</scan:Jobs></scan:ScannerStatus>")


def capabilities_xml(b, base, uid):
    res = "".join(f"<scan:DiscreteResolution><scan:XResolution>{r}</scan:XResolution>"
                  f"<scan:YResolution>{r}</scan:YResolution></scan:DiscreteResolution>" for r in b.resolutions)
    modes = "".join(f"<scan:ColorMode>{m}</scan:ColorMode>" for m in b.color_modes)
    fmts = "".join(f"<pwg:DocumentFormat>{f}</pwg:DocumentFormat>" for f in FORMATS)
    fmts += "".join(f"<scan:DocumentFormatExt>{f}</scan:DocumentFormatExt>" for f in FORMATS)
    caps = (f"<scan:MinWidth>{b.min_width}</scan:MinWidth><scan:MaxWidth>{b.max_width}</scan:MaxWidth>"
            f"<scan:MinHeight>{b.min_height}</scan:MinHeight><scan:MaxHeight>{b.max_height}</scan:MaxHeight>"
            "<scan:MaxScanRegions>1</scan:MaxScanRegions><scan:SettingProfiles><scan:SettingProfile>"
            f"<scan:ColorModes>{modes}</scan:ColorModes><scan:DocumentFormats>{fmts}</scan:DocumentFormats>"
            f"<scan:SupportedResolutions><scan:DiscreteResolutions>{res}</scan:DiscreteResolutions></scan:SupportedResolutions>"
            "<scan:ColorSpaces><scan:ColorSpace>sRGB</scan:ColorSpace></scan:ColorSpaces>"
            "</scan:SettingProfile></scan:SettingProfiles><scan:SupportedIntents>"
            "<scan:Intent>Document</scan:Intent><scan:Intent>TextAndGraphic</scan:Intent>"
            "<scan:Intent>Photo</scan:Intent><scan:Intent>Preview</scan:Intent></scan:SupportedIntents>"
            f"<scan:MaxOpticalXResolution>{max(b.resolutions)}</scan:MaxOpticalXResolution>"
            f"<scan:MaxOpticalYResolution>{max(b.resolutions)}</scan:MaxOpticalYResolution>"
            "<scan:RiskyLeftMargin>0</scan:RiskyLeftMargin><scan:RiskyRightMargin>0</scan:RiskyRightMargin>"
            "<scan:RiskyTopMargin>0</scan:RiskyTopMargin><scan:RiskyBottomMargin>0</scan:RiskyBottomMargin>")
    duplex = f"<scan:AdfDuplexInputCaps>{caps}</scan:AdfDuplexInputCaps>" if b.duplex else ""
    opts = "<scan:AdfOption>DetectPaperLoaded</scan:AdfOption>" + ("<scan:AdfOption>Duplex</scan:AdfOption>" if b.duplex else "")
    return (f'<?xml version="1.0" encoding="UTF-8"?><scan:ScannerCapabilities {XMLNS}>'
            f"<pwg:Version>2.63</pwg:Version><pwg:MakeAndModel>{escape(b.make_model)}</pwg:MakeAndModel>"
            f"<pwg:SerialNumber>{escape(b.serial)}</pwg:SerialNumber><scan:UUID>{uid}</scan:UUID>"
            f"<scan:AdminURI>{base}/</scan:AdminURI><scan:IconURI>{base}/icon.png</scan:IconURI>"
            f"<scan:Adf><scan:AdfSimplexInputCaps>{caps}</scan:AdfSimplexInputCaps>{duplex}"
            f"<scan:FeederCapacity>{b.feeder_capacity}</scan:FeederCapacity>"
            f"<scan:AdfOptions>{opts}</scan:AdfOptions></scan:Adf></scan:ScannerCapabilities>")


def make_handler(scanner, uid, icon):
    class H(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"
        server_version = "ds720d-airscan/0.1"

        def log_message(self, fmt, *args):
            log(f"{self.client_address[0]} {fmt % args}")

        def base(self):
            return f"http://{self.headers.get('Host') or 'localhost'}"

        def send(self, code, body=b"", ctype="text/xml", extra=None):
            if isinstance(body, str):
                body = body.encode()
            self.send_response(code)
            if body or code == 200:
                self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            for k, v in (extra or {}).items():
                self.send_header(k, v)
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(body)

        def do_HEAD(self):
            self.do_GET()

        def do_GET(self):
            p = self.path.split("?")[0].rstrip("/")
            b = scanner.backend
            if p == "/eSCL/ScannerCapabilities":
                return self.send(200, capabilities_xml(b, self.base(), uid))
            if p == "/eSCL/ScannerStatus":
                return self.send(200, scanner.status_xml())
            if p in ("", "/index.html"):
                return self.send(200, f"<html><body><h1>{escape(b.make_model)}</h1><p>Pont AirScan actif. "
                                      f"Chargeur : {b.adf_state()}</p></body></html>", "text/html; charset=utf-8")
            if p == "/icon.png" and icon:
                return self.send(200, icon, "image/png")
            parts = p.split("/")
            if len(parts) == 5 and parts[1:3] == ["eSCL", "ScanJobs"]:
                job = scanner.jobs.get(parts[3])
                if not job:
                    return self.send(404)
                if parts[4] == "NextDocument":
                    try:
                        doc = job.docs.get(timeout=180)
                    except queue.Empty:
                        return self.send(503, extra={"Retry-After": "2"})
                    if doc is None:
                        job.docs.put(None)  # les appels suivants renvoient aussi 404
                        return self.send(404)
                    job.transferred += 1
                    return self.send(200, doc, job.settings.fmt)
                if parts[4] == "ScanImageInfo":
                    return self.send(200, f'<?xml version="1.0" encoding="UTF-8"?><scan:ScanImageInfo {XMLNS}>'
                                          f"<pwg:JobUri>/eSCL/ScanJobs/{job.id}</pwg:JobUri>"
                                          f"<pwg:JobUuid>{job.id}</pwg:JobUuid></scan:ScanImageInfo>")
            self.send(404)

        def do_POST(self):
            p = self.path.split("?")[0].rstrip("/")
            body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
            if p != "/eSCL/ScanJobs":
                return self.send(404)
            log("ScanSettings:", body.decode(errors="replace").replace("\n", " ")[:600])
            try:
                settings = parse_settings(body, scanner.backend)
            except ET.ParseError:
                return self.send(400)
            if scanner.backend.adf_state() == "ScannerAdfEmpty":
                return self.send(409)
            job, code = scanner.start_job(settings)
            if not job:
                return self.send(code)
            log(f"job {job.id}: {settings}")
            self.send(201, extra={"Location": f"{self.base()}/eSCL/ScanJobs/{job.id}"})

        def do_DELETE(self):
            parts = self.path.rstrip("/").split("/")
            job = scanner.jobs.get(parts[-1]) if len(parts) >= 4 else None
            if not job:
                return self.send(404)
            job.cancelled.set()
            self.send(200)

    return H


def load_icon():
    src = "/Library/Image Capture/TWAIN Data Sources/DS-720D.ds/Contents/Resources/Sheetfed.icns"
    for cand in (src, src.replace("/Contents/Resources/", "/Resources/")):
        if os.path.exists(cand):
            out = f"/tmp/ds720d-icon-{os.getuid()}.png"
            r = subprocess.run(["sips", "-s", "format", "png", "-Z", "128", cand, "--out", out], capture_output=True)
            if r.returncode == 0:
                return open(out, "rb").read()
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--backend", default="demo", choices=["demo", "ds720d"])
    ap.add_argument("--port", type=int, default=8090)
    ap.add_argument("--lan", action="store_true", help="annoncer et écouter sur le réseau local (sinon : ce Mac uniquement)")
    ap.add_argument("--name", default=None)
    args = ap.parse_args()

    if args.backend == "demo":
        from backend_demo import DemoBackend
        backend = DemoBackend()
    else:
        from backend_ds720d import DS720DBackend
        backend = DS720DBackend(trace=os.environ.get("DS720D_TRACE") == "1")

    uid = str(uuid.uuid5(uuid.NAMESPACE_URL, f"ds720d:{backend.serial}"))
    bind = "0.0.0.0" if args.lan else "127.0.0.1"
    httpd = ThreadingHTTPServer((bind, args.port), make_handler(Scanner(backend), uid, load_icon()))
    name = args.name or backend.make_model
    txt = {
        "txtvers": "1", "vers": "2.63", "rs": "eSCL", "ty": backend.make_model,
        "pdl": ",".join(FORMATS), "uuid": uid, "cs": "color,grayscale,binary",
        "is": "adf", "duplex": "T" if backend.duplex else "F", "note": "",
        "adminurl": f"http://{socket.gethostname()}:{args.port}/",
        "representation": f"http://{socket.gethostname()}:{args.port}/icon.png",
    }
    reg = bonjour.Registration(name, "_uscan._tcp", args.port, txt, local_only=not args.lan,
                               host=None if args.lan else "localhost",
                               on_registered=lambda e, n, d: log(f"Bonjour: '{n}' annoncé (err={e})"))
    log(f"eSCL sur {bind}:{args.port} — {'réseau local' if args.lan else 'ce Mac uniquement'}")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        reg.close()


if __name__ == "__main__":
    main()
