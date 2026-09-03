"""Local-only HTTP server for the scl-generator GUI. Standard library
only (`http.server`) -- matches this repo's established preference for
hand-rolled code over pulling in a framework (see
generator/diagram/svg_primitives.py's own docstring). Stateless: every
request carries the browser's *entire* in-progress station as JSON; this
process never remembers anything between requests, so there's no
session/concurrency state to get wrong.

Binds to 127.0.0.1 only -- there's no authentication, and this is a local
design-time tool, not a service meant to be reachable from anywhere else.

Routes:
  GET  /                 index.html (the form + preview page)
  GET  /static/<name>    app.js / style.css (fixed allowlist, never a
                          filesystem join on the request path)
  POST /api/preview      {..station json..} -> {svg, errors, summary}
  POST /api/generate     {..station json.., out_dir, overwrite} ->
                          writes .scd + .svg, XSD-validates, like
                          generator/output.py's write_station() but
                          sequenced for HTTP instead of blocking prompts
  POST /api/compile      {scd_path, compiled_dir} -> runs
                          tools/scl-compiler's compile_scd(), mirroring
                          output.py's optional "compile now" step
"""

import json
import sys
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from . import formdata
from .. import naming, scl_writer
from ..diagram import onelinediagram

_STATIC_DIR = Path(__file__).resolve().parent / "static"
_STATIC_FILES = {
    "app.js": "application/javascript; charset=utf-8",
    "style.css": "text/css; charset=utf-8",
}

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent.parent / "scl-compiler"))


class _Handler(BaseHTTPRequestHandler):
    out_dir = None  # set by run() before the server starts serving

    def log_message(self, fmt, *args):
        pass  # quiet by default -- nothing here is worth the request-log noise

    def _send_json(self, status, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send_bytes(self, content_type, body):
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _read_json(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        return json.loads(raw) if raw else {}

    def do_GET(self):
        if self.path in ("/", "/index.html"):
            self._send_bytes("text/html; charset=utf-8", (_STATIC_DIR / "index.html").read_bytes())
            return
        if self.path.startswith("/static/"):
            name = self.path[len("/static/"):]
            content_type = _STATIC_FILES.get(name)
            if content_type:
                self._send_bytes(content_type, (_STATIC_DIR / name).read_bytes())
                return
        self._send_json(404, {"error": "not found"})

    def do_POST(self):
        try:
            if self.path == "/api/preview":
                self._handle_preview()
            elif self.path == "/api/generate":
                self._handle_generate()
            elif self.path == "/api/compile":
                self._handle_compile()
            else:
                self._send_json(404, {"error": "not found"})
        except Exception as e:
            # Defensive last resort -- formdata.station_from_json already
            # catches every *expected* validation failure itself, so this
            # should never normally fire. Still: never let the live-typing
            # loop take the process down.
            print("sas-scl-gui: unhandled error on %s: %r" % (self.path, e), file=sys.stderr)
            self._send_json(500, {"error": str(e)})

    def _handle_preview(self):
        data = self._read_json()
        station, errors = formdata.station_from_json(data)
        svg = onelinediagram.render(station) if station.voltage_levels else None
        self._send_json(200, {"svg": svg, "errors": errors, "summary": formdata.summary(station)})

    def _handle_generate(self):
        data = self._read_json()
        station, errors = formdata.station_from_json(data)
        if errors.get("name") or errors["voltage_levels"] or errors["transformers"]:
            self._send_json(400, {"errors": errors})
            return
        if not station.voltage_levels:
            self._send_json(400, {"errors": {"name": "add at least one voltage level first"}})
            return

        out_dir = Path(data.get("out_dir") or self.out_dir)
        out_dir.mkdir(parents=True, exist_ok=True)
        base = naming.sanitize_identifier(station.name).lower()
        scd_path = out_dir / ("%s.scd" % base)
        svg_path = out_dir / ("%s-oneline.svg" % base)

        existing = [str(p) for p in (scd_path, svg_path) if p.exists()]
        if existing and not data.get("overwrite"):
            self._send_json(409, {"exists": True, "paths": existing})
            return

        tree = scl_writer.write(station)
        scd_path.write_bytes(scl_writer.to_string(tree))
        svg_path.write_text(onelinediagram.render(station))

        from scl.validate import SclValidationError, validate_xsd
        xsd_ok, xsd_error = True, None
        try:
            validate_xsd(tree)
        except SclValidationError as e:
            xsd_ok, xsd_error = False, str(e)

        self._send_json(200, {
            "ok": True, "scdPath": str(scd_path), "svgPath": str(svg_path),
            "xsdOk": xsd_ok, "xsdError": xsd_error,
        })

    def _handle_compile(self):
        data = self._read_json()
        scd_path = data.get("scd_path")
        if not scd_path:
            self._send_json(400, {"error": "scd_path required"})
            return
        compiled_dir = Path(data.get("compiled_dir") or "etc/generated")
        compiled_dir.mkdir(parents=True, exist_ok=True)

        from scl_compile import compile_scd
        outputs = compile_scd(scd_path, validate_schema=True)
        written = []
        for filename, text in outputs.items():
            path = compiled_dir / filename
            path.write_text(text)
            written.append(str(path))

        self._send_json(200, {"ok": True, "files": written})


def build_server(out_dir: Path, port: int = 0) -> ThreadingHTTPServer:
    """Constructs (but does not start serving) the server, bound to
    127.0.0.1:`port` -- `port=0` asks the OS for an ephemeral free port,
    read back via `server.server_address[1]` (used by
    tests/test_webapp_server.py to run a real instance without a fixed
    port to collide on).
    """
    _Handler.out_dir = out_dir
    return ThreadingHTTPServer(("127.0.0.1", port), _Handler)


def run(out_dir: Path, port: int = 8787, open_browser: bool = True) -> None:
    """Builds and serves until Ctrl+C. This is scl_generate.py --gui's
    entry point; blocks for the life of the process.
    """
    server = build_server(out_dir, port)
    url = "http://127.0.0.1:%d/" % server.server_address[1]
    print("sas-scl-gui: serving %s (out-dir=%s) -- Ctrl+C to stop" % (url, out_dir))
    if open_browser:
        webbrowser.open(url)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
