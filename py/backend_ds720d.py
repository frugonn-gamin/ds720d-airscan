"""Backend eSCL pour le vrai Brother DS-720D (via ds720d-usbd + protocole MsdcNvt/Avision).

Constats sur l'appareil (scan réel du 2026-11-09) :
  * données en plans par ligne (R 2592 o, G 2592 o, B 2592 o) — bit 6 de l'octet 0x5e de l'INQUIRY ;
  * sortie linéaire : le profil ICC Brother DS-720D.icc la ramène en sRGB (blanc papier 175 -> 246) ;
  * le fond hors papier est quasi noir (~4), ce qui permet un recadrage automatique fiable.
"""
import os
import struct
import subprocess
import tempfile
import threading

from avision import Avision, AvisionError, MsdcNvt, NoPaper
from avtransport import Transport
from imageenc import Page, to_tiff

P = Avision.PIXELS
BPL = P * 3
ICC_CANDIDATES = [
    "/Library/Image Capture/TWAIN Data Sources/DS-720D.ds/Resources/icc/DS-720D.icc",
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "DS-720D.icc"),
]
AUTOCROP = os.environ.get("DS720D_AUTOCROP", "1") == "1"
BG_THRESHOLD = 20   # luminance brute au-dessus de laquelle on considère qu'il y a du papier


def _mirror(line):
    rev = line[::-1]
    out = bytearray(rev)
    out[0::3] = rev[2::3]
    out[2::3] = rev[0::3]
    return bytes(out)


def _tone_lut(profile):
    """Courbe de ton brute -> sRGB du profil ICC, mesurée sur une rampe de gris via sips/ColorSync."""
    if not profile:
        return bytes(range(256))
    ramp = Page(256, 1, "RGB24", 300, bytes(v for i in range(256) for v in (i, i, i)))
    with tempfile.TemporaryDirectory(prefix="ds720d-lut-") as d:
        src, dst = os.path.join(d, "r.tif"), os.path.join(d, "r.bmp")
        open(src, "wb").write(to_tiff(ramp))
        subprocess.run(["sips", "--embedProfile", profile, "--matchTo",
                        "/System/Library/ColorSync/Profiles/sRGB Profile.icc", src], check=True, capture_output=True)
        subprocess.run(["sips", "-s", "format", "bmp", src, "--out", dst], check=True, capture_output=True)
        bmp = open(dst, "rb").read()
    off = struct.unpack_from("<I", bmp, 10)[0]
    bpp = struct.unpack_from("<H", bmp, 28)[0] // 8
    px = bmp[off:off + 256 * bpp]
    return bytes(min(255, (px[i * bpp] + px[i * bpp + 1] + px[i * bpp + 2]) // 3) for i in range(256))


class DS720DBackend:
    make_model = "Brother DS-720D"
    resolutions = [150, 200, 300, 600]
    color_modes = ["RGB24", "Grayscale8", "BlackAndWhite1"]
    duplex = True
    feeder_capacity = 1
    min_width, max_width = 650, 2550
    min_height, max_height = 1063, 9600
    default_height = 3508

    def __init__(self, trace=False):
        self.lock = threading.Lock()
        self.busy = False
        self.trace = trace
        self.serial = "inconnu"
        self.profile = next((p for p in ICC_CANDIDATES if os.path.exists(p)), None)
        self.tone = _tone_lut(self.profile)
        self._connect()

    def _connect(self):
        self.t = Transport()
        self.av = Avision(MsdcNvt(self.t), trace=self.trace)
        if not self.av.nvt.is_available():
            raise AvisionError("le DS-720D ne répond pas au protocole Novatek")
        inq = self.av.inquiry()
        self.planar = len(inq) > 0x5E and bool(inq[0x5E] & 0x40)
        nvm = self.av.read_nvm()
        self.serial = nvm[0x2E:0x2E + 20].split(b"\0")[0].decode(errors="replace").strip() or self.serial

    def _call(self, fn):
        try:
            return fn()
        except (ConnectionError, OSError):
            self._connect()
            return fn()

    def adf_state(self):
        if self.busy:
            return "ScannerAdfProcessing"
        with self.lock:
            try:
                return "ScannerAdfLoaded" if self._call(self.av.paper_loaded) else "ScannerAdfEmpty"
            except Exception:  # noqa: BLE001
                return "ScannerAdfEmpty"

    # --- numérisation ---
    def scan(self, s, emit, cancelled):
        self.busy = True
        try:
            with self.lock:
                av = self.av
                if not self._call(av.paper_loaded):
                    raise NoPaper("pas de papier dans le chargeur")
                av.ensure_lamp()
                av.send_color_matrix()
                yres = 600 if s.yres > 300 else 300
                while not cancelled.is_set():
                    sides = self._scan_sheet(s, yres)
                    for i, raw in enumerate(sides):
                        if len(raw) >= BPL:
                            emit(self._process(raw, s, yres, rear=(i == 1)))
                    if not av.paper_loaded():
                        break
        finally:
            self.busy = False

    def _scan_sheet(self, s, yres):
        av = self.av
        av.set_window(yres=yres, length_300=s.y + s.height, duplex=s.duplex, pages=1)
        av.reserve()
        av.start_scan()
        bufs = [bytearray(), bytearray()]
        eop = [False, not s.duplex]
        chunk = (2 * 1024 * 1024 // BPL) * BPL
        n = 0
        try:
            while not all(eop):
                side = n % 2 if s.duplex else 0
                if eop[side]:
                    side = 1 - side
                data, end = av.read_image(chunk)
                bufs[side] += data
                if end:
                    # Constaté sur l'appareil : en recto-verso les blocs alternent recto/verso
                    # et une seule fin de page clôt la feuille entière (les deux faces).
                    eop = [True, True]
                if self.trace:
                    print(f"   READ #{n} côté {side}: {len(data)} o fin={end}")
                n += 1
                if n > 2000:
                    raise AvisionError("flux image interminable")
        finally:
            av.release()
        dump = os.environ.get("DS720D_DUMP")
        if dump:
            for i, b in enumerate(bufs[: 2 if s.duplex else 1]):
                open(os.path.join(dump, f"face{i}.raw"), "wb").write(b)
        return bufs[: 2 if s.duplex else 1]

    @staticmethod
    def _interleave(raw, lines):
        out = bytearray(lines * BPL)
        for i in range(lines):
            o = i * BPL
            out[o:o + BPL:3] = raw[o:o + P]
            out[o + 1:o + BPL:3] = raw[o + P:o + 2 * P]
            out[o + 2:o + BPL:3] = raw[o + 2 * P:o + BPL]
        return out

    @staticmethod
    def _paper_box(rgb, lines):
        """Boîte englobante du papier (le fond du scanneur est noir)."""
        row_ok = []
        for y in range(lines):
            g = rgb[y * BPL + 1:(y + 1) * BPL:3 * 8]
            row_ok.append(sum(g) / len(g) > BG_THRESHOLD)
        rows = [y for y, ok in enumerate(row_ok) if ok]
        if not rows:
            return 0, 0, P, lines
        top, bottom = rows[0], rows[-1] + 1
        sample = range(top, bottom, max(1, (bottom - top) // 64))
        col = [0] * P
        for y in sample:
            g = rgb[y * BPL + 1:(y + 1) * BPL:3]
            for x in range(0, P, 2):
                col[x] += g[x]
        cnt = len(sample)
        cols = [x for x in range(0, P, 2) if col[x] / cnt > BG_THRESHOLD]
        left, right = (cols[0], cols[-1] + 2) if cols else (0, P)
        return left, top, min(right, P), bottom

    def _process(self, raw, s, yres, rear):
        lines = len(raw) // BPL
        rgb = self._interleave(raw, lines) if self.planar else bytearray(raw[: lines * BPL])
        if rear:
            for i in range(lines):
                rgb[i * BPL:(i + 1) * BPL] = _mirror(bytes(rgb[i * BPL:(i + 1) * BPL]))
        if AUTOCROP:
            left, top, right, bottom = self._paper_box(rgb, lines)
        else:
            left = Avision.LEFT_SKIP + s.x
            right = min(P, left + s.width)
            top = Avision.BG_LINES + s.y * yres // 300
            bottom = min(lines, top + s.height * yres // 300)
        a, b = left * 3, right * 3
        data = b"".join(bytes(rgb[i * BPL + a:i * BPL + b]) for i in range(top, bottom))
        width, h = right - left, bottom - top
        tw = max(1, width * s.xres // 300)
        th = max(1, h * s.yres // yres)
        target = None if (tw, th) == (width, h) else (tw, th, s.xres)
        if s.color_mode == "RGB24":
            return Page(width, h, "RGB24", 300, data, ydpi=yres, target=target, profile=self.profile)
        gray = data[1::3].translate(self.tone)
        if s.color_mode == "BlackAndWhite1":
            gray = gray.translate(bytes(0 if i < 160 else 255 for i in range(256)))
        return Page(width, h, "Grayscale8", 300, gray, ydpi=yres, target=target)
