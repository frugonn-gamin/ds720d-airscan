"""Sonde : vérifie la liaison avec le DS-720D (INFO, TEST UNIT READY, INQUIRY Avision)."""
import sys

from avtransport import DIR_IN, ScsiError, Transport, sense_text

t = Transport(trace="-v" in sys.argv)
print("INFO       :", t.info())

try:
    t.cmd([0x00, 0, 0, 0, 0, 0])
    print("TEST UNIT  : prêt")
except ScsiError as e:
    print("TEST UNIT  :", sense_text(e.sense or b""))

inq = t.cmd([0x12, 0, 0, 0, 0xA5, 0], DIR_IN, 0xA5)
print(f"INQUIRY    : {len(inq)} octets")
print("  vendeur  :", inq[8:16].decode(errors="replace").strip())
print("  produit  :", inq[16:32].decode(errors="replace").strip())
print("  révision :", inq[32:36].decode(errors="replace").strip())
for off in range(0, len(inq), 16):
    print(f"  {off:02x}: {inq[off:off+16].hex(' ')}")
open("inquiry.bin", "wb").write(inq)
