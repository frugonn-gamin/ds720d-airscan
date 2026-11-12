"""Backend de démonstration : génère une mire, pour valider l'intégration AirScan sans le scanneur."""
from imageenc import Page


class DemoBackend:
    make_model = "Brother DS-720D (démo)"
    serial = "DEMO0001"
    resolutions = [150, 200, 300, 600]
    color_modes = ["RGB24", "Grayscale8", "BlackAndWhite1"]
    duplex = True
    feeder_capacity = 1
    min_width, max_width = 650, 2550      # 55 mm .. 215,9 mm en 1/300"
    min_height, max_height = 1063, 9600   # 90 mm .. 812,8 mm
    default_height = 3508

    def adf_state(self):
        return "ScannerAdfLoaded"

    def scan(self, s, emit, cancelled):
        w = s.width * s.xres // 300
        h = s.height * s.yres // 300
        for side in range(2 if s.duplex else 1):
            if cancelled.is_set():
                return
            emit(self._page(w, h, s.color_mode, s.xres, side))

    @staticmethod
    def _page(w, h, mode, dpi, side):
        bands = 8
        rows = []
        for b in range(bands):
            if mode == "RGB24":
                c = [(255, 0, 0), (0, 160, 0), (0, 0, 255), (255, 200, 0),
                     (0, 200, 200), (200, 0, 200), (40, 40, 40), (230, 230, 230)][(b + side) % bands]
                grad = bytes(v for x in range(w) for v in (c[0] * x // w, c[1], c[2] * (w - x) // w))
            elif mode == "Grayscale8":
                grad = bytes((x * 255 // w + b * 32) % 256 for x in range(w))
            else:
                bpl = (w + 7) // 8
                grad = bytes(0xF0 if (b + side) % 2 else 0x0F for _ in range(bpl))
            rows.append(grad)
        data = b"".join(rows[min(y * bands // h, bands - 1)] for y in range(h))
        return Page(w, h, mode, dpi, data)
