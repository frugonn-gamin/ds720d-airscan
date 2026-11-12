"""Client du socket ds720d-usbd : exécute des commandes SCSI sur le DS-720D."""
import socket
import struct

SOCK = "/var/run/ds720d-usbd.sock"
OP_SCSI, OP_RESET, OP_INFO = 1, 2, 3
DIR_NONE, DIR_IN, DIR_OUT = 0, 1, 2


class ScsiError(Exception):
    def __init__(self, msg, csw=None, sense=None):
        super().__init__(msg)
        self.csw = csw
        self.sense = sense


class Transport:
    def __init__(self, path=SOCK, trace=False):
        self.s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.s.connect(path)
        self.trace = trace

    def close(self):
        self.s.close()

    def _recv(self, n):
        buf = bytearray()
        while len(buf) < n:
            chunk = self.s.recv(n - len(buf))
            if not chunk:
                raise ConnectionError("ds720d-usbd a fermé la connexion")
            buf += chunk
        return bytes(buf)

    def _call(self, op, cdb=b"", direction=DIR_NONE, length=0, data=b"", timeout_ms=30000, lun=0):
        if direction == DIR_OUT:
            length = len(data)
        hdr = b"DSQ1" + struct.pack("<BBBBII", op, len(cdb), direction, lun, length, timeout_ms)
        hdr += cdb.ljust(16, b"\0")
        self.s.sendall(hdr + (data if direction == DIR_OUT else b""))
        rh = self._recv(20)
        if rh[:4] != b"DSR1":
            raise ConnectionError("réponse invalide")
        result, csw, payload, residue = struct.unpack("<iB3xII", rh[4:])
        body = self._recv(payload) if payload else b""
        return result, csw, body, residue

    def info(self):
        _, _, body, _ = self._call(OP_INFO)
        return body.decode()

    def reset(self):
        return self._call(OP_RESET)[0]

    def request_sense(self):
        r, csw, body, _ = self._call(OP_SCSI, bytes([0x03, 0, 0, 0, 18, 0]), DIR_IN, 18)
        return body if r == 0 else b""

    def cmd(self, cdb, direction=DIR_NONE, length=0, data=b"", timeout_ms=30000, check=True):
        """Exécute une CDB. Retourne les données lues (IN) ; lève ScsiError si CHECK CONDITION."""
        cdb = bytes(cdb)
        r, csw, body, residue = self._call(OP_SCSI, cdb, direction, length, data, timeout_ms)
        if self.trace:
            print(f"  CDB {cdb.hex(' ')} dir={direction} len={length or len(data)} -> r={r} csw={csw} got={len(body)}")
        if r != 0:
            raise ScsiError(f"erreur transport {r} pour CDB {cdb.hex(' ')}")
        if csw != 0 and check:
            sense = self.request_sense()
            raise ScsiError(f"CHECK CONDITION CDB {cdb.hex(' ')} sense={sense.hex(' ')}", csw, sense)
        return body


def sense_text(sense):
    if len(sense) < 14:
        return "(pas de sense)"
    key, asc, ascq = sense[2] & 0x0F, sense[12], sense[13]
    return f"key=0x{key:x} asc=0x{asc:02x} ascq=0x{ascq:02x}"
