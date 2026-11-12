"""Annonce Bonjour via DNSServiceRegister (libSystem), sans dépendance externe."""
import ctypes
import socket
import threading

_lib = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
_CB = ctypes.CFUNCTYPE(None, ctypes.c_void_p, ctypes.c_uint32, ctypes.c_int32,
                       ctypes.c_char_p, ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p)
_lib.DNSServiceRegister.argtypes = [ctypes.POINTER(ctypes.c_void_p), ctypes.c_uint32, ctypes.c_uint32,
                                    ctypes.c_char_p, ctypes.c_char_p, ctypes.c_char_p, ctypes.c_char_p,
                                    ctypes.c_uint16, ctypes.c_uint16, ctypes.c_char_p, _CB, ctypes.c_void_p]
_lib.DNSServiceRegister.restype = ctypes.c_int32
_lib.DNSServiceProcessResult.argtypes = [ctypes.c_void_p]
_lib.DNSServiceProcessResult.restype = ctypes.c_int32
_lib.DNSServiceRefDeallocate.argtypes = [ctypes.c_void_p]

IFACE_ANY = 0
IFACE_LOCAL_ONLY = 0xFFFFFFFF


def txt_record(items):
    out = b""
    for k, v in items.items():
        entry = f"{k}={v}".encode()
        if len(entry) > 255:
            raise ValueError(f"entrée TXT trop longue: {k}")
        out += bytes([len(entry)]) + entry
    return out


class Registration:
    def __init__(self, name, regtype, port, txt, local_only=True, host=None, on_registered=None):
        self.ref = ctypes.c_void_p()
        self._cb = _CB(self._callback)
        self.on_registered = on_registered
        rec = txt_record(txt)
        err = _lib.DNSServiceRegister(ctypes.byref(self.ref), 0,
                                      IFACE_LOCAL_ONLY if local_only else IFACE_ANY,
                                      name.encode(), regtype.encode(), None,
                                      host.encode() if host else None,
                                      socket.htons(port), len(rec), rec, self._cb, None)
        if err:
            raise OSError(f"DNSServiceRegister a échoué ({err})")
        self._thread = threading.Thread(target=self._loop, daemon=True)
        self._thread.start()

    def _callback(self, ref, flags, err, name, regtype, domain, ctx):
        if self.on_registered:
            self.on_registered(err, name.decode() if name else "", domain.decode() if domain else "")

    def _loop(self):
        while self.ref and _lib.DNSServiceProcessResult(self.ref) == 0:
            pass

    def close(self):
        if self.ref:
            _lib.DNSServiceRefDeallocate(self.ref)
            self.ref = None
