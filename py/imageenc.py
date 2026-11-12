"""Encodage d'images sans dépendance : TIFF brut écrit en Python, conversion JPEG/PDF/PNG par sips (ImageIO)."""
import os
import struct
import subprocess
import tempfile
from dataclasses import dataclass

MODES = {"RGB24": (3, 8), "Grayscale8": (1, 8), "BlackAndWhite1": (1, 1)}


@dataclass
class Page:
    width: int
    height: int
    mode: str  # RGB24 | Grayscale8 | BlackAndWhite1 (1 = blanc, convention eSCL/TIFF WhiteIsZero non utilisée)
    dpi: int
    data: bytes  # lignes contiguës ; pour 1 bit : MSB en premier, 1 = noir
    ydpi: int = 0                      # résolution verticale si différente de dpi
    target: tuple = None               # (largeur, hauteur, dpi) après rééchantillonnage par sips
    profile: str = None                # profil ICC du périphérique à appliquer (conversion vers sRGB)

    @property
    def bytes_per_line(self):
        spp, bps = MODES[self.mode]
        return (self.width * spp * bps + 7) // 8


def to_tiff(page: Page) -> bytes:
    spp, bps = MODES[page.mode]
    photometric = 2 if spp == 3 else (0 if bps == 1 else 1)  # 0 = WhiteIsZero pour le N&B
    entries = []

    def tag(code, typ, count, value):
        entries.append((code, typ, count, value))

    data_off = 8
    data_len = len(page.data)
    extra_off = data_off + data_len + (data_len & 1)
    extra = b""
    bps_off = extra_off + len(extra)
    if spp == 3:
        extra += struct.pack("<3H", 8, 8, 8)
    res_off = extra_off + len(extra)
    extra += struct.pack("<II", page.dpi, 1)
    yres_off = extra_off + len(extra)
    extra += struct.pack("<II", page.ydpi or page.dpi, 1)
    ifd_off = extra_off + len(extra)

    tag(256, 4, 1, page.width)
    tag(257, 4, 1, page.height)
    tag(258, 3, spp, bps_off if spp == 3 else bps)
    tag(259, 3, 1, 1)
    tag(262, 3, 1, photometric)
    tag(273, 4, 1, data_off)
    tag(277, 3, 1, spp)
    tag(278, 4, 1, page.height)
    tag(279, 4, 1, data_len)
    tag(282, 5, 1, res_off)
    tag(283, 5, 1, yres_off)
    tag(296, 3, 1, 2)

    ifd = struct.pack("<H", len(entries))
    for code, typ, count, value in entries:
        if typ == 3 and count == 1:
            ifd += struct.pack("<HHIHH", code, typ, count, value, 0)
        else:
            ifd += struct.pack("<HHII", code, typ, count, value)
    ifd += struct.pack("<I", 0)
    return b"II*\0" + struct.pack("<I", ifd_off) + page.data + (b"\0" if data_len & 1 else b"") + extra + ifd


SIPS_FORMAT = {"image/jpeg": "jpeg", "application/pdf": "pdf", "image/png": "png", "image/tiff": "tiff"}


def encode(page: Page, mime: str, quality: int = 85) -> bytes:
    if mime == "image/tiff" and not page.target and not page.profile:
        return to_tiff(page)
    fmt = SIPS_FORMAT[mime]
    with tempfile.TemporaryDirectory(prefix="ds720d-") as d:
        src, dst = os.path.join(d, "p.tif"), os.path.join(d, "p." + fmt)
        with open(src, "wb") as f:
            f.write(to_tiff(page))
        if page.profile or page.target:
            prep = ["sips"]
            if page.profile:
                prep += ["--embedProfile", page.profile, "--matchTo", "/System/Library/ColorSync/Profiles/sRGB Profile.icc"]
            if page.target:
                w, h, dpi = page.target
                prep += ["-z", str(h), str(w), "-s", "dpiWidth", str(dpi), "-s", "dpiHeight", str(dpi)]
            subprocess.run(prep + [src], check=True, capture_output=True)
        cmd = ["sips", "-s", "format", fmt]
        if fmt == "jpeg":
            cmd += ["-s", "formatOptions", str(quality)]
        subprocess.run(cmd + [src, "--out", dst], check=True, capture_output=True)
        with open(dst, "rb") as f:
            return f.read()
