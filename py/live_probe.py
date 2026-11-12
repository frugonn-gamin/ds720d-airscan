"""Tests progressifs sur le vrai DS-720D (nécessite ds720d-usbd lancé en root).

  python3 live_probe.py            # liaison, INQUIRY, NVM, papier
  python3 live_probe.py --scan     # + numérisation brute d'une feuille (recto, couleur 300 dpi)
  python3 live_probe.py --scan --duplex
"""
import os
import sys
import time

import imageenc
from avision import Avision, AvisionError, MsdcNvt, u32
from avtransport import Transport

OUT = os.environ.get("PROBE_OUT", "probe-out")
os.makedirs(OUT, exist_ok=True)
trace = "-v" in sys.argv

t = Transport(trace=trace)
print("1. démon     :", t.info())
nvt = MsdcNvt(t)
print("2. Novatek   :", "NOVA OK" if nvt.is_available() else "pas de réponse NOVA")
vid = nvt.get_data(3, 2)
pid = nvt.get_data(4, 2)
print(f"3. VID/PID   : {vid.hex()} / {pid.hex()}")

av = Avision(nvt, trace=trace)
inq = av.inquiry()
open(f"{OUT}/inquiry.bin", "wb").write(inq)
print(f"4. INQUIRY   : {len(inq)} o, '{inq[8:16].decode(errors='replace')}' '{inq[16:32].decode(errors='replace')}'"
      f" rév '{inq[32:36].decode(errors='replace')}'")
for off in range(0, len(inq), 16):
    print(f"     {off:02x}: {inq[off:off+16].hex(' ')}")
nvm = av.read_nvm()
open(f"{OUT}/nvm.bin", "wb").write(nvm)
print(f"5. NVM       : série '{nvm[0x2e:0x2e+16].split(b'\\0')[0].decode(errors='replace')}'")
print("6. papier    :", "présent" if av.paper_loaded() else "absent")

if "--scan" not in sys.argv:
    sys.exit(0)

duplex = "--duplex" in sys.argv
if not av.paper_loaded():
    print("   Glisse une feuille dans le DS-720D puis relance.")
    sys.exit(1)

av.trace = True
av.ensure_lamp()
av.send_color_matrix()
av.set_window(yres=300, length_300=3508, duplex=duplex, pages=1)
av.reserve()
av.start_scan()
sides = [bytearray(), bytearray()]
eop = [False, not duplex]
chunk = (2 * 1024 * 1024 // 7776) * 7776
n = 0
t0 = time.time()
try:
    while not all(eop):
        side = n % 2 if duplex else 0
        if eop[side]:
            side = 1 - side
        data, end = av.read_image(chunk)
        sides[side] += data
        print(f"   READ #{n} côté {'recto' if side == 0 else 'verso'}: {len(data)} o, fin={end}")
        if end:
            eop[side] = True
        n += 1
        if n > 400:
            raise AvisionError("trop de lectures")
finally:
    try:
        av.release()
    except AvisionError as e:
        print("   RELEASE:", e)

print(f"7. scan brut : {time.time()-t0:.1f}s")
for i, buf in enumerate(sides[: 2 if duplex else 1]):
    name = ["recto", "verso"][i]
    open(f"{OUT}/{name}.raw", "wb").write(buf)
    lines = len(buf) // 7776
    print(f"   {name}: {len(buf)} o = {lines} lignes de 7776 o (+{len(buf) % 7776} o)")
    if lines:
        page = imageenc.Page(2592, lines, "RGB24", 300, bytes(buf[: lines * 7776]))
        open(f"{OUT}/{name}.jpg", "wb").write(imageenc.encode(page, "image/jpeg"))
print("   papier restant:", av.paper_loaded())
