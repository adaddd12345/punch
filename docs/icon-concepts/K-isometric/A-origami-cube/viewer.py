"""Live angle viewer for the v4 icon: serves a static gallery folder plus
/render.svg?yaw=<deg>&pitch=<deg>, which renders MODEL4 through gen.py's one
camera at that angle (the real model, nothing pre-rendered).

    python3 viewer.py <static-dir> [port]
"""
import http.server
import sys
import tempfile
import threading
from pathlib import Path
from urllib.parse import parse_qs, urlparse

sys.path.insert(0, str(Path(__file__).parent))
_argv, sys.argv = sys.argv, [sys.argv[0]]   # gen.py reads flags from argv at import
import gen  # noqa: E402
sys.argv = _argv

STATIC = Path(sys.argv[1]).resolve()
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 8765
ISO = 35.2644
# The front face may turn at most 20 degrees either way from its base view, and
# the camera never goes below the ground plane.
LIMIT = 20.0
# "iso" is the icon's own angle (MODEL4["camera"]); "face" looks straight at the woofer.
BASES = {"iso": (gen.MODEL4["camera"]["yaw"], gen.MODEL4["camera"]["pitch"]), "face": (0.0, 0.0)}
lock = threading.Lock()
out = Path(tempfile.mkdtemp()) / "view.svg"


def render(base, dx, dy):
    by, bp = BASES.get(base, BASES["iso"])
    dx = max(-LIMIT, min(LIMIT, dx))
    dy = max(-LIMIT, min(LIMIT, dy))
    yaw, pitch = by + dx, max(0.0, bp + dy)
    with lock:
        gen.build_v4(out_path=out, report=False, camera=(yaw, pitch))
        return out.read_bytes(), yaw, pitch


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **k):
        super().__init__(*a, directory=str(STATIC), **k)

    def do_GET(self):
        u = urlparse(self.path)
        if u.path != "/render.svg":
            return super().do_GET()
        q = parse_qs(u.query)
        try:
            body, yaw, pitch = render(q.get("base", ["iso"])[0], float(q.get("x", ["0"])[0]),
                                      float(q.get("y", ["0"])[0]))
        except (ValueError, AssertionError) as e:
            self.send_error(400, str(e))
            return
        self.send_response(200)
        self.send_header("Content-Type", "image/svg+xml")
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Camera", "%.2f,%.2f" % (yaw, pitch))
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    print("serving %s on :%d" % (STATIC, PORT))
    http.server.ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
