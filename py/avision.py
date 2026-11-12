"""Protocole du DS-720D, reconstitué par rétro-ingénierie d'AvDrv (bibliothèque Avision du pilote Brother).

Deux couches :
  * MsdcNvt : le contrôleur USB Novatek (NT96226) n'accepte pas les CDB Avision directement ;
    on les tunnelise dans des CDB vendeur 16 octets : op 07 addr(BE32) len(BE32) p0..p5.
      C5 FF 02      -> "NOVA" (connexion disponible)
      C5 FF 03..06  -> IsLock / IsFinish / Lock / UnLock (réponse 16 o : u32 0x10, ..., u32@8 booléen)
      C5 02 03 i    -> SetData(iCmd)   (OUT)
      C5 02 01 i    -> GetData(iCmd) étape 1, puis C5 02 02 i -> étape 2 (résultat réel)
      C3            -> lecture mémoire du périphérique (≤ 64 Kio par transfert)
  * Avision : CDB SCSI Avision classiques (INQUIRY, MEDIA CHECK, SET WINDOW, SCAN, READ, ...)
    passés par SetData(0) / GetData(0) ; statut par GetData(1) ; images par GetData(2) + lecture mémoire.
"""
import struct
import time

from avtransport import DIR_IN, DIR_OUT

MAX_XFER = 0x10000


class AvisionError(Exception):
    def __init__(self, msg, status=None, sense=b""):
        super().__init__(msg)
        self.status = status
        self.sense = sense

    @property
    def asc(self):
        return (self.sense[12], self.sense[13]) if len(self.sense) >= 14 else None


class NoPaper(AvisionError):
    pass


class PaperJam(AvisionError):
    pass


SENSE_TEXT = {
    (0x80, 0x01): "bourrage papier", (0x80, 0x02): "capot ouvert", (0x80, 0x03): "pas de papier",
    (0x80, 0x04): "fin de page", (0x80, 0x05): "double alimentation", (0x80, 0x09): "bourrage papier",
    (0x80, 0x15): "fin de page + double alimentation",
}


def u32(b, off=0):
    return struct.unpack_from("<I", b, off)[0]


class MsdcNvt:
    def __init__(self, transport, trace=False):
        self.t = transport
        self.trace = trace

    @staticmethod
    def _cdb(op, addr, length, params):
        return bytes([op, 0x07]) + addr.to_bytes(4, "big") + length.to_bytes(4, "big") + bytes(params).ljust(6, b"\0")

    def raw_in(self, op, addr, length, params):
        return self.t.cmd(self._cdb(op, addr, length, params), DIR_IN, length)

    def raw_out(self, op, addr, data, params):
        return self.t.cmd(self._cdb(op, addr, len(data), params), DIR_OUT, data=data)

    def is_available(self):
        return self.raw_in(0xC5, 0, 4, [0xFF, 0x02, 0x00]) == b"NOVA"

    def _flag(self, sub):
        r = self.raw_in(0xC5, 0, 16, [0xFF, sub, 0x00])
        if len(r) < 12 or u32(r) != 0x10:
            raise AvisionError(f"réponse MsdcNvt inattendue (FF {sub:02x}): {r.hex(' ')}")
        return u32(r, 8)

    def is_lock(self):
        return self._flag(0x03)

    def is_finish(self):
        return self._flag(0x04)

    def lock(self):
        return self._flag(0x05)

    def unlock(self):
        return self._flag(0x06)

    def _open(self):
        if self.is_finish():
            for _ in range(1000):
                if not self.is_lock():
                    break
                time.sleep(0.01)
            if self.is_lock():
                self.unlock()
        for _ in range(3000):
            if self.lock():
                return
            time.sleep(0.01)
        raise AvisionError("impossible d'obtenir le verrou MsdcNvt")

    def _close(self):
        for _ in range(600):
            if self.is_finish():
                break
            time.sleep(0.1)
        self.unlock()

    def set_data(self, icmd, data):
        self._open()
        try:
            self.raw_out(0xC5, 0, data, [0x02, 0x03, icmd])
        finally:
            self._close()

    def get_data(self, icmd, n):
        self._open()
        try:
            self.raw_in(0xC5, 0, n, [0x02, 0x01, icmd])
            for _ in range(30000):
                if self.is_finish():
                    break
                time.sleep(0.01)
            return self.raw_in(0xC5, 0, n, [0x02, 0x02, icmd])
        finally:
            self._close()

    def mem_read(self, addr, n):
        out = bytearray()
        while len(out) < n:
            k = min(MAX_XFER, n - len(out))
            out += self.raw_in(0xC3, addr + len(out), k, [0, 0, 0])
        return bytes(out)


def read10(dtc, qual, length):
    return bytes([0x28, 0, dtc, 0, qual >> 8, qual & 0xFF]) + length.to_bytes(3, "big") + b"\0"


def send10(dtc, qual, length):
    return bytes([0x2A, 0, dtc, 0, qual >> 8, qual & 0xFF]) + length.to_bytes(3, "big") + b"\0"


class Avision:
    PIXELS = 2592            # largeur du capteur à 300 dpi
    BG_LINES = 11            # lignes de fond ajoutées en tête (feature 9 : 1 + 10)
    LEFT_SKIP = 4            # pixels ignorés à gauche (à 300 dpi)

    def __init__(self, nvt: MsdcNvt, trace=False):
        self.nvt = nvt
        self.trace = trace
        self.inquiry_data = b""
        self.nvm = b""

    def log(self, *a):
        if self.trace:
            print("   av:", *a)

    # --- commande générique (CAsicIO::DoIo) ---
    def do_io(self, cdb, data_out=b"", n_in=0):
        cdb = bytes(cdb).ljust(10, b"\0")
        self.nvt.set_data(0, cdb + data_out)
        data = self.nvt.get_data(0, n_in) if n_in else b""
        status = u32(self.nvt.get_data(1, 4))
        self.log(f"CDB {cdb.hex(' ')} out={len(data_out)} in={n_in} -> status {status}")
        if status and cdb[0] != 0x03:
            sense = self.request_sense()
            raise self._sense_error(status, sense, cdb)
        return data

    def request_sense(self):
        cdb = bytes([0x03, 0, 0, 0, 0x16, 0]).ljust(10, b"\0")
        self.nvt.set_data(0, cdb)
        sense = self.nvt.get_data(0, 0x16)
        self.nvt.get_data(1, 4)
        return sense

    @staticmethod
    def _sense_error(status, sense, cdb):
        key = sense[2] & 0x0F if len(sense) > 2 else None
        asc = (sense[12], sense[13]) if len(sense) >= 14 else None
        txt = SENSE_TEXT.get(asc, f"sense key={key} asc={asc}")
        cls = NoPaper if asc == (0x80, 0x03) else PaperJam if asc in ((0x80, 0x01), (0x80, 0x09)) else AvisionError
        return cls(f"{txt} (CDB {cdb[:6].hex(' ')}, statut {status})", status, sense)

    # --- commandes ---
    def inquiry(self):
        head = self.do_io([0x12, 0, 0, 0, 5, 0], n_in=5)
        n = min(head[4] + 5, 0xA5)
        self.inquiry_data = self.do_io([0x12, 0, 0, 0, n, 0], n_in=n)
        return self.inquiry_data

    def read_nvm(self):
        self.nvm = self.do_io(read10(0x69, 0x0A0D, 0x80), n_in=0x80)
        return self.nvm

    def paper_loaded(self):
        return bool(self.do_io([0x08, 0, 0, 0, 2, 0], n_in=2)[0] & 1)

    def ensure_lamp(self):
        if self.do_io(read10(0xA0, 0x0A0D, 2), n_in=2)[0] == 0:
            self.do_io(send10(0xA0, 0, 1), b"\x01")

    def send_color_matrix(self):
        ident = bytes.fromhex("040000000000" "000004000000" "000000000400")
        self.do_io(send10(0x83, 0, 18), ident)

    def set_window(self, yres=300, length_300=3508, duplex=False, pages=1):
        """Fenêtre pleine largeur, couleur 24 bits, X = 300 dpi (le pilote d'origine fait de même)."""
        w = bytearray(0x4F)
        w[7] = 0x47
        struct.pack_into(">HH", w, 0x0A, 300, yres)
        struct.pack_into(">III", w, 0x0E, 0, 0, self.PIXELS * 4)
        if duplex:
            length_300 += 125
        struct.pack_into(">I", w, 0x1A, length_300 * 4)
        w[0x1E:0x21] = b"\x80\x80\x80"
        w[0x21] = 5          # composition : couleur
        w[0x22] = 8          # bits par canal
        w[0x25] = 0x03
        w[0x30] = 0xFF
        w[0x31] = 0x1D
        w[0x32] = 0x80 | 0x40 | 0x20   # ADF | toujours | filtre RGB
        w[0x33] = 0xFF
        bpl = self.PIXELS * 3
        lines = length_300 * yres // 300
        if duplex:
            lines *= 2
        struct.pack_into(">HH", w, 0x35, bpl & 0xFFFF, lines & 0xFFFF)
        w[0x39] = 0x10
        struct.pack_into(">HHH", w, 0x3B, 100, 100, 100)
        w[0x41] = 0x10 if duplex else 0x00
        w[0x43] = bpl >> 16
        w[0x44] = lines >> 16
        w[0x45] = self.BG_LINES
        w[0x46] = pages
        self.log("SET WINDOW", bytes(w).hex(" "))
        self.do_io(bytes([0x24, 0, 0, 0, 0, 0, 0, 0, 0x4F, 0]), bytes(w))

    def reserve(self):
        self.do_io([0x16, 0, 0, 0, 0, 0])

    def release(self, cancel=False):
        self.do_io([0x17, 0, 0, 0, 0, 1 if cancel else 0])

    def start_scan(self, quality=True):
        self.do_io([0x1B, 0, 0, 0, 0, 0x80 if quality else 0])

    def read_image(self, length, poll_s=0.005, timeout_s=30):
        """CAsicIO::DoImage. Retourne (données, fin_de_page)."""
        self.nvt.set_data(0, read10(0x00, 0x0A0D, length))
        t0 = time.time()
        data, eop = b"", False
        while True:
            info = self.nvt.get_data(2, 24)
            st, a, b, w, h, addr = struct.unpack("<6I", info[:24])
            if st == 0:
                if time.time() - t0 > timeout_s:
                    raise AvisionError("délai dépassé en attente des données image")
                time.sleep(poll_s)
                continue
            self.log(f"image info st={st} a={a} b={b} W={w} H={h} addr=0x{addr:x}")
            if st == 1:
                data = self.nvt.mem_read(addr, w * h)
            elif st == 2:
                raise AvisionError("lecture interrompue par le scanneur")
            elif st == 3:
                eop = True
            else:
                raise AvisionError(f"statut image inconnu {st}")
            break
        status = u32(self.nvt.get_data(1, 4))
        if status:
            sense = self.request_sense()
            asc = (sense[12], sense[13]) if len(sense) >= 14 else None
            if asc in ((0x80, 0x04), (0x80, 0x15)):
                eop = True
            else:
                raise self._sense_error(status, sense, read10(0, 0x0A0D, length))
        return data, eop
