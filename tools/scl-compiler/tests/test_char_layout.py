"""Unit tests for scl/char_layout.py, run with plain unittest -- pure
arithmetic/graph-walk assertions, no XML/SCL involved (topology.py's own
output shape is hand-built here directly), mirroring
tools/scl-generator/tests/test_diagram_geometry.py's style.

Run: python3 -m unittest discover -s tools/scl-compiler/tests -v
"""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from scl import char_layout


def _bus_bay(name, node_name, path, desc=None):
    return {"name": name, "desc": None, "isBusBay": True,
            "nodes": [{"name": node_name, "pathName": path, "desc": desc}], "equipment": []}


def _diameter_vl(kv, breaker_names):
    """A single breaker-and-half-style VL: 2 bus bays + one diameter bay
    chaining `breaker_names` (>=1) between them, exactly switchyard.scd's
    own shape (generalized to any breaker count).
    """
    bus_a_path, bus_b_path = "S/V/BusA/Bus", "S/V/BusB/Bus"
    equipment = []
    nodes = []
    prev = bus_a_path
    for i, name in enumerate(breaker_names):
        is_last = i == len(breaker_names) - 1
        nxt = bus_b_path if is_last else "S/V/Diameter/N%d" % (i + 1)
        equipment.append({"name": name, "type": "CBR", "terminals": [prev, nxt]})
        if not is_last:
            nodes.append({"name": "N%d" % (i + 1), "pathName": nxt, "desc": "tap %d" % (i + 1)})
        prev = nxt
    return {
        "name": "V", "kv": kv,
        "bays": [
            _bus_bay("BusA", "Bus", bus_a_path, "Bus A"),
            _bus_bay("BusB", "Bus", bus_b_path, "Bus B"),
            {"name": "Diameter", "desc": None, "isBusBay": False, "nodes": nodes, "equipment": equipment},
        ],
    }


class TestBuildDiagramChain(unittest.TestCase):
    def setUp(self):
        self.vl = _diameter_vl(800.0, ["CB1", "CB2", "CB3"])
        self.d = char_layout.build_diagram([self.vl], [], {})

    def test_all_breakers_present_with_point_refs(self):
        ids = {b["id"] for b in self.d["breakers"]}
        self.assertEqual(ids, {"CB1", "CB2", "CB3"})
        cb1 = next(b for b in self.d["breakers"] if b["id"] == "CB1")
        self.assertEqual(cb1["statusFullRef"], "CB1/LD0/XCBR1.Pos")
        self.assertEqual(cb1["controlFullRef"], "CB1/LD0/XCBR1.PosCtl")
        self.assertEqual(cb1["measFullRefBase"], "CB1/LD0/MMXU1")

    def test_breakers_stack_vertically_in_one_column(self):
        xs = {b["x"] for b in self.d["breakers"]}
        self.assertEqual(len(xs), 1, "a single diameter's breakers share one column")
        ys = sorted(b["y"] for b in self.d["breakers"])
        self.assertEqual(ys, sorted(set(ys)), "no two breakers share a row")
        self.assertEqual(ys[1] - ys[0], ys[2] - ys[1], "evenly spaced")

    def test_two_bus_bars_span_the_diameter_column(self):
        self.assertEqual(len(self.d["buses"]), 2)
        breaker_x = self.d["breakers"][0]["x"]
        for bus in self.d["buses"]:
            self.assertLessEqual(bus["x1"], breaker_x)
            self.assertGreaterEqual(bus["x2"], breaker_x)
        ys = sorted(b["y1"] for b in self.d["buses"])
        self.assertLess(ys[0], ys[1], "one bus above the other")

    def test_taps_are_unknown_kind_with_no_extension(self):
        self.assertEqual(len(self.d["taps"]), 2)
        self.assertTrue(all(t["kind"] == "unknown" for t in self.d["taps"]))


class TestBuildDiagramMultipleStrips(unittest.TestCase):
    def test_higher_kv_strip_stacks_above_lower(self):
        hv = _diameter_vl(800.0, ["CB1", "CB2", "CB3"])
        lv = _diameter_vl(230.0, ["CB4", "CB5", "CB6"])
        # Declared LV-first, HV-second -- ordering must still come out by
        # kv, not document order.
        d = char_layout.build_diagram([lv, hv], [], {})
        hv_y = min(b["y"] for b in d["breakers"] if b["id"] in ("CB1", "CB2", "CB3"))
        lv_y = min(b["y"] for b in d["breakers"] if b["id"] in ("CB4", "CB5", "CB6"))
        self.assertLess(hv_y, lv_y, "higher kV strip must be drawn above (smaller y)")


class TestBuildDiagramTransformerLink(unittest.TestCase):
    def test_links_hv_and_lv_taps_across_strips(self):
        hv = _diameter_vl(800.0, ["CB1", "CB2", "CB3"])  # HV tap = N2 = S/V/Diameter/N2
        lv = _diameter_vl(230.0, ["CB4", "CB5", "CB6"])  # LV tap = N1 = S/V/Diameter/N1
        # Rename LV's VL/diameter paths so they don't collide with HV's.
        for bay in lv["bays"]:
            for node in bay["nodes"]:
                node["pathName"] = node["pathName"].replace("S/V/", "S/V2/")
            for eq in bay["equipment"]:
                eq["terminals"] = [p.replace("S/V/", "S/V2/") for p in eq["terminals"]]
        lv["name"] = "V2"
        xfmr = {"name": "XFMR1", "hvNodePath": "S/V/Diameter/N2", "lvNodePath": "S/V2/Diameter/N1"}
        d = char_layout.build_diagram([hv, lv], [xfmr], {})
        self.assertEqual(d["transformerLinks"], [
            {"name": "XFMR1", "hvTapId": "S/V/Diameter/N2", "lvTapId": "S/V2/Diameter/N1"},
        ])
        hv_tap = next(t for t in d["taps"] if t["id"] == "S/V/Diameter/N2")
        lv_tap = next(t for t in d["taps"] if t["id"] == "S/V2/Diameter/N1")
        self.assertEqual(hv_tap["kind"], "transformer")
        self.assertEqual(lv_tap["kind"], "transformer")

    def test_omits_link_when_a_tap_is_never_placed(self):
        hv = _diameter_vl(800.0, ["CB1", "CB2", "CB3"])
        xfmr = {"name": "XFMR1", "hvNodePath": "S/V/Diameter/N2", "lvNodePath": "S/Nowhere/N9"}
        d = char_layout.build_diagram([hv], [xfmr], {})
        self.assertEqual(d["transformerLinks"], [])


class TestBuildDiagramStar(unittest.TestCase):
    def test_star_bay_spokes_share_one_bus_row(self):
        vl = {
            "name": "V1", "kv": 34.5,
            "bays": [
                _bus_bay("Bus1", "Bus", "S/V1/Bus1/Bus", "34.5kV Bus"),
                {"name": "Bay1", "desc": None, "isBusBay": False, "nodes": [], "equipment": [
                    {"name": "CB1", "type": "CBR", "terminals": ["S/V1/Bus1/Bus", "S/V1/Bay1/N1"]},
                    {"name": "CB1DA", "type": "DIS", "terminals": ["S/V1/Bus1/Bus", "S/V1/Bay1/N2"]},
                ]},
            ],
        }
        d = char_layout.build_diagram([vl], [], {"S/V1/Bay1/N1": "feeder"})
        self.assertEqual(len(d["breakers"]), 1)
        self.assertEqual(len(d["disconnects"]), 1)
        self.assertEqual(d["breakers"][0]["y"], d["disconnects"][0]["y"], "spokes' CBs share one row")
        self.assertNotEqual(d["breakers"][0]["x"], d["disconnects"][0]["x"], "spokes get distinct columns")
        bus = d["buses"][0]
        self.assertLessEqual(bus["x1"], min(d["breakers"][0]["x"], d["disconnects"][0]["x"]))
        self.assertGreaterEqual(bus["x2"], max(d["breakers"][0]["x"], d["disconnects"][0]["x"]))
        tap = next(t for t in d["taps"] if t["id"] == "S/V1/Bay1/N1")
        self.assertEqual(tap["kind"], "feeder")


class TestBuildDiagramEmptyInput(unittest.TestCase):
    def test_no_voltage_levels_returns_empty_dict(self):
        self.assertEqual(char_layout.build_diagram([], [], {}), {})


if __name__ == "__main__":
    unittest.main()
