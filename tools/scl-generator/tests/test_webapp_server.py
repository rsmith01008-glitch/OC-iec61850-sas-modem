import json
import sys
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from generator.webapp import server


def _vl(cid, vl_name, kv, layout_kind, taps):
    return {"_cid": cid, "vl_name": vl_name, "kv": kv, "layout_kind": layout_kind, "taps": taps}


def _tap(cid, name, kind):
    return {"_cid": cid, "name": name, "kind": kind}


VALID_STATION = {
    "name": "ServerTestStation",
    "voltage_levels": [_vl("vl1", "V1", 100, "single_bus", [_tap("t1", "Feed1", "feeder")])],
}

INVALID_STATION = {
    "name": "ServerTestStation",
    "voltage_levels": [_vl("bad", "VBad", 100, "breaker_and_half", [_tap("t1", "Line1", "line")])],  # odd tap count
}


class TestWebappServer(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.out_dir = Path(self._tmp.name)
        self.srv = server.build_server(self.out_dir, port=0)
        self.port = self.srv.server_address[1]
        self.thread = threading.Thread(target=self.srv.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.srv.shutdown()
        self.srv.server_close()
        self.thread.join(timeout=5)
        self._tmp.cleanup()

    def _url(self, path):
        return "http://127.0.0.1:%d%s" % (self.port, path)

    def _get(self, path):
        resp = urllib.request.urlopen(self._url(path))
        return resp.status, resp.read()

    def _post(self, path, payload):
        req = urllib.request.Request(
            self._url(path), data=json.dumps(payload).encode("utf-8"),
            headers={"Content-Type": "application/json"}, method="POST",
        )
        try:
            resp = urllib.request.urlopen(req)
            return resp.status, json.loads(resp.read())
        except urllib.error.HTTPError as e:
            return e.code, json.loads(e.read())

    def test_get_index_serves_the_form(self):
        status, body = self._get("/")
        self.assertEqual(status, 200)
        self.assertIn(b"station-form", body)

    def test_get_static_assets(self):
        status, body = self._get("/static/app.js")
        self.assertEqual(status, 200)
        self.assertIn(b"collectFormState", body)

        status, body = self._get("/static/style.css")
        self.assertEqual(status, 200)

    def test_preview_valid_station_returns_svg_and_no_errors(self):
        status, body = self._post("/api/preview", VALID_STATION)
        self.assertEqual(status, 200)
        self.assertIn("<svg", body["svg"])
        self.assertIn("ServerTestStation", body["svg"])
        self.assertEqual(body["errors"], {"voltage_levels": {}, "transformers": {}})

    def test_preview_invalid_station_never_errors_out(self):
        status, body = self._post("/api/preview", INVALID_STATION)
        self.assertEqual(status, 200)  # preview never fails the HTTP request itself
        self.assertIn("bad", body["errors"]["voltage_levels"])
        self.assertIsNone(body["svg"])  # nothing valid was built, so nothing to draw

    def test_generate_then_conflict_then_overwrite(self):
        status, body = self._post("/api/generate", dict(VALID_STATION, out_dir=str(self.out_dir)))
        self.assertEqual(status, 200)
        self.assertTrue(body["ok"])
        self.assertTrue(body["xsdOk"])
        scd_path = Path(body["scdPath"])
        self.assertTrue(scd_path.exists())
        self.assertTrue(Path(body["svgPath"]).exists())

        status, body = self._post("/api/generate", dict(VALID_STATION, out_dir=str(self.out_dir)))
        self.assertEqual(status, 409)
        self.assertTrue(body["exists"])

        status, body = self._post(
            "/api/generate", dict(VALID_STATION, out_dir=str(self.out_dir), overwrite=True),
        )
        self.assertEqual(status, 200)
        self.assertTrue(body["ok"])

    def test_generate_refuses_when_station_has_errors(self):
        status, body = self._post("/api/generate", dict(INVALID_STATION, out_dir=str(self.out_dir)))
        self.assertEqual(status, 400)
        self.assertIn("bad", body["errors"]["voltage_levels"])

    def test_generate_refuses_empty_station(self):
        status, body = self._post(
            "/api/generate", {"name": "Empty", "voltage_levels": [], "out_dir": str(self.out_dir)},
        )
        self.assertEqual(status, 400)


if __name__ == "__main__":
    unittest.main()
