"""Unit tests for scl/topology.py, run with plain unittest.

Run: python3 -m unittest discover -s tools/scl-compiler/tests -v
"""

import sys
import unittest
from pathlib import Path

from lxml import etree

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from scl.parse import parse_file, root
from scl import topology
from scl.private_ext import connectivity_node_private

FIXTURE = Path(__file__).resolve().parent.parent.parent.parent / "scl" / "switchyard.scd"

# A small, self-contained VoltageLevel exercising what switchyard.scd
# doesn't: a DIS ConductingEquipment (its own spoke off the shared bus,
# not chained to the breaker) and an oc:tap Private extension resolving
# a non-transformer tap's line/feeder kind.
_STAR_WITH_DIS_AND_TAP_KIND = """
<SCL xmlns="http://www.iec.ch/61850/2003/SCL" xmlns:oc="urn:oc-iec61850-sas:v1">
  <Substation name="S">
    <VoltageLevel name="V1">
      <Voltage unit="V" multiplier="k">34.5</Voltage>
      <Bay name="Bus1">
        <ConnectivityNode name="Bus" pathName="S/V1/Bus1/Bus" desc="34.5kV Bus"/>
      </Bay>
      <Bay name="Bay1">
        <ConductingEquipment name="CB1" type="CBR">
          <Terminal connectivityNode="S/V1/Bus1/Bus" cNodeName="Bus"/>
          <Terminal connectivityNode="S/V1/Bay1/N1" cNodeName="N1"/>
        </ConductingEquipment>
        <ConductingEquipment name="CB1DA" type="DIS">
          <Terminal connectivityNode="S/V1/Bus1/Bus" cNodeName="Bus"/>
          <Terminal connectivityNode="S/V1/Bay1/N2" cNodeName="N2"/>
        </ConductingEquipment>
        <ConnectivityNode name="N1" pathName="S/V1/Bay1/N1" desc="Feed1 tap">
          <Private type="oc-iec61850-sas">
            <oc:tap kind="feeder"/>
          </Private>
        </ConnectivityNode>
        <ConnectivityNode name="N2" pathName="S/V1/Bay1/N2" desc="disc tap"/>
      </Bay>
    </VoltageLevel>
  </Substation>
</SCL>
"""


class TestParseVoltageLevelsRealFixture(unittest.TestCase):
    """Against the real, hand-authored scl/switchyard.scd."""

    def setUp(self):
        self.root = root(parse_file(FIXTURE))
        self.vls = topology.parse_voltage_levels(self.root)

    def test_finds_both_voltage_levels_with_kv(self):
        by_name = {vl["name"]: vl["kv"] for vl in self.vls}
        self.assertEqual(by_name, {"V800": 800.0, "V230": 230.0})

    def test_bus_bay_detected_with_no_equipment(self):
        v800 = next(vl for vl in self.vls if vl["name"] == "V800")
        bus_bays = [b for b in v800["bays"] if b["isBusBay"]]
        self.assertEqual({b["name"] for b in bus_bays}, {"BusA800", "BusB800"})
        for b in bus_bays:
            self.assertEqual(b["equipment"], [])
            self.assertEqual(len(b["nodes"]), 1)

    def test_equipment_bay_has_three_breakers_in_document_order(self):
        v800 = next(vl for vl in self.vls if vl["name"] == "V800")
        diameter = next(b for b in v800["bays"] if b["name"] == "Diameter1")
        self.assertFalse(diameter["isBusBay"])
        self.assertEqual([e["name"] for e in diameter["equipment"]], ["CB1", "CB2", "CB3"])
        self.assertTrue(all(e["type"] == "CBR" for e in diameter["equipment"]))
        self.assertEqual(diameter["equipment"][0]["terminals"],
                          ["Switchyard1/V800/BusA800/Bus", "Switchyard1/V800/Diameter1/N1"])

    def test_no_disconnects_in_switchyard_scd(self):
        # Ground truth confirmed during planning: switchyard.scd has zero
        # type="DIS" ConductingEquipment anywhere.
        all_types = set()
        for vl in self.vls:
            for bay in vl["bays"]:
                for eq in bay["equipment"]:
                    all_types.add(eq["type"])
        self.assertEqual(all_types, {"CBR"})

    def test_parse_transformers_resolves_hv_lv_node_paths(self):
        xfmrs = topology.parse_transformers(self.root)
        self.assertEqual(len(xfmrs), 1)
        self.assertEqual(xfmrs[0]["name"], "XFMR1")
        self.assertEqual(xfmrs[0]["hvNodePath"], "Switchyard1/V800/Diameter1/N2")
        self.assertEqual(xfmrs[0]["lvNodePath"], "Switchyard1/V230/Diameter2/N3")


class TestParseVoltageLevelsStarWithDis(unittest.TestCase):
    """A synthetic star-shaped (single-bus-style) bay with a DIS spoke and
    an oc:tap Private extension -- neither exercised by switchyard.scd.
    """

    def setUp(self):
        self.root = etree.fromstring(_STAR_WITH_DIS_AND_TAP_KIND.encode())
        self.vls = topology.parse_voltage_levels(self.root)

    def test_dis_equipment_parsed_alongside_cbr(self):
        bay1 = next(b for vl in self.vls for b in vl["bays"] if b["name"] == "Bay1")
        types = {e["name"]: e["type"] for e in bay1["equipment"]}
        self.assertEqual(types, {"CB1": "CBR", "CB1DA": "DIS"})

    def test_connectivity_node_private_resolves_tap_kind(self):
        cn_n1 = self.root.find(".//{http://www.iec.ch/61850/2003/SCL}ConnectivityNode[@name='N1']")
        cn_n2 = self.root.find(".//{http://www.iec.ch/61850/2003/SCL}ConnectivityNode[@name='N2']")
        self.assertEqual(connectivity_node_private(cn_n1), {"kind": "feeder"})
        self.assertEqual(connectivity_node_private(cn_n2), {})


if __name__ == "__main__":
    unittest.main()
