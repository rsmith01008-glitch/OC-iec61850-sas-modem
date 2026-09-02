"""Unit tests for scl/mapping.py + scl/codegen.py, run with plain unittest
(no pytest dependency -- this environment only has lxml installed).

Run: python3 -m unittest discover -s tools/scl-compiler/tests -v
"""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from scl.parse import parse_file, root
from scl.mapping import map_document, map_ied, map_scada, MappingError
from scl.codegen import encode

FIXTURE = Path(__file__).resolve().parent / "fixtures" / "single_breaker.scd"


def _load():
    tree = parse_file(FIXTURE)
    return root(tree)


class TestMapDocument(unittest.TestCase):
    def setUp(self):
        self.root = _load()
        self.mapped = map_document(self.root)

    def test_finds_both_ieds(self):
        self.assertEqual(set(self.mapped.keys()), {"BRK1", "SCADA1"})

    def test_roles(self):
        self.assertEqual(self.mapped["BRK1"]["role"], "ied")
        self.assertEqual(self.mapped["SCADA1"]["role"], "scada")


class TestMapIed(unittest.TestCase):
    def setUp(self):
        self.root = _load()
        ied_elem = None
        for candidate in self.root.iter():
            if candidate.tag.endswith("IED") and candidate.get("name") == "BRK1":
                ied_elem = candidate
                break
        self.cfg = map_ied(self.root, ied_elem)

    def test_identity(self):
        self.assertEqual(self.cfg["iedName"], "BRK1")
        self.assertEqual(self.cfg["logicalDevice"], "LD0")
        self.assertEqual(self.cfg["mms"], {"port": 8102})

    def test_goose_transport(self):
        self.assertEqual(self.cfg["goose"]["port"], 8104)
        self.assertEqual(self.cfg["goose"]["heartbeatSec"], 5.0)
        # MinTime=100ms -> 0.1s ladder start, no Private override in fixture
        self.assertAlmostEqual(self.cfg["goose"]["burstIntervalsSec"][0], 0.1)

    def test_ied_settings(self):
        self.assertEqual(self.cfg["tickIntervalSec"], 0.2)
        self.assertEqual(self.cfg["integritySec"], 30)
        self.assertEqual(self.cfg["gooseStaleAfterSec"], 15)

    def test_points_resolved_via_cdc_chain(self):
        by_ref = {(p["ln"], p["doName"]): p for p in self.cfg["points"]}
        pos = by_ref[("XCBR1", "Pos")]
        self.assertEqual(pos["type"], "DPS")
        self.assertEqual(pos["io"]["kind"], "redstone")
        self.assertEqual(pos["io"]["openSide"], 0)
        # Pos IS in the GOOSE dataset (FCDA lnClass=XCBR lnInst=1 doName=Pos)
        self.assertTrue(pos["goose"])

        posctl = by_ref[("XCBR1", "PosCtl")]
        self.assertEqual(posctl["type"], "DPC")
        self.assertEqual(posctl["sbo"], {"timeoutSec": 30})
        # PosCtl is NOT in the dataset -> not GOOSE-published
        self.assertFalse(posctl["goose"])

        amp = by_ref[("MMXU1", "Amp")]
        self.assertEqual(amp["type"], "MV")
        self.assertEqual(amp["deadband"], 0.5)
        self.assertEqual(amp["io"]["kind"], "meter")

    def test_interlocks(self):
        self.assertEqual(len(self.cfg["interlocks"]), 1)
        il = self.cfg["interlocks"][0]
        self.assertEqual(il["localRef"], "XCBR1.PosCtl")
        self.assertEqual(il["peerIed"], "BRK2")
        self.assertEqual(il["peerValue"], "closed")

    def test_protection(self):
        ptoc = self.cfg["protection"]["ptoc"]
        self.assertEqual(len(ptoc), 1)
        self.assertEqual(ptoc[0]["name"], "PTOC1")
        self.assertEqual(ptoc[0]["pickup"], 1.2)
        self.assertEqual(ptoc[0]["curve"], "IEC_VERY_INVERSE")
        self.assertEqual(ptoc[0]["respectInterlocks"], False)

    def test_reports(self):
        self.assertEqual(len(self.cfg["reports"]), 1)
        rc = self.cfg["reports"][0]
        self.assertEqual(rc["name"], "rcbStatus1")
        self.assertEqual(rc["dataset"], ["XCBR1.Pos"])
        self.assertEqual(rc["trgOps"], {"dchg": True, "qchg": True, "dupd": False, "period": False, "gi": True})
        self.assertEqual(rc["confRev"], 1)
        self.assertEqual(rc["bufTime"], 0.0)


class TestMapScada(unittest.TestCase):
    def setUp(self):
        self.root = _load()
        ied_elem = None
        for candidate in self.root.iter():
            if candidate.tag.endswith("IED") and candidate.get("name") == "SCADA1":
                ied_elem = candidate
                break
        self.cfg = map_scada(self.root, ied_elem)

    def test_identity(self):
        self.assertEqual(self.cfg["scadaName"], "SCADA1")
        self.assertEqual(self.cfg["hms"], {"port": 8103})
        self.assertEqual(self.cfg["goose"], {"port": 8104})
        self.assertEqual(self.cfg["resyncSec"], 60)

    def test_ieds_derived_from_subnetwork(self):
        self.assertEqual(self.cfg["ieds"], [{"name": "BRK1"}])

    def test_historian_and_alarms(self):
        self.assertEqual(self.cfg["historian"]["dir"], "/var/log/sas-scada")
        self.assertEqual(len(self.cfg["alarms"]), 1)
        self.assertEqual(self.cfg["alarms"][0]["id"], "V1_LOW")
        self.assertEqual(self.cfg["alarms"][0]["value"], 200)


class TestCodegen(unittest.TestCase):
    def test_bare_vs_bracket_keys(self):
        text = encode({"iedName": "X", "ip.weird": "Y"})
        self.assertIn('iedName = "X"', text)
        self.assertIn('["ip.weird"] = "Y"', text)

    def test_bool_before_number(self):
        # bool is a subclass of int in Python -- must not render True as 1.
        text = encode({"a": True, "b": 1})
        self.assertIn("a = true", text)
        self.assertIn("b = 1", text)

    def test_list_is_sequence_style(self):
        text = encode(["x", "y"])
        self.assertNotIn("=", text)
        self.assertIn('"x"', text)
        self.assertIn('"y"', text)


class TestErrors(unittest.TestCase):
    def test_unresolvable_cdc_raises(self):
        # Sanity check the error path exists and names the problem clearly.
        with self.assertRaises(MappingError):
            from scl.mapping import _resolve_cdc
            root_elem = _load()
            _resolve_cdc(root_elem, "XCBR_Basic", "NoSuchDO", "XCBR1")


if __name__ == "__main__":
    unittest.main()
