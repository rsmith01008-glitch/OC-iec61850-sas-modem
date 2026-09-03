import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from generator.webapp.formdata import station_from_json, summary


def _tap(cid, name, kind, transformer=None):
    d = {"_cid": cid, "name": name, "kind": kind}
    if transformer is not None:
        d["transformer"] = transformer
    return d


def _vl(cid, vl_name, kv, layout_kind, taps):
    return {"_cid": cid, "vl_name": vl_name, "kv": kv, "layout_kind": layout_kind, "taps": taps}


class TestValidStation(unittest.TestCase):
    def test_multi_vl_with_transformer(self):
        data = {
            "name": "TestStation",
            "voltage_levels": [
                _vl("vl1", "V800", 800, "breaker_and_half", [
                    _tap("t1", "Line1", "line"),
                    _tap("t2", "XFMR1", "transformer", {
                        "name": "XFMR1", "lv_kv": 230,
                        "lv_outputs": [{"name": "Feed1", "kind": "feeder"}],
                    }),
                ]),
                _vl("vl2", "V69", 69, "single_bus", [
                    _tap("t3", "Feed2", "feeder"),
                ]),
            ],
        }
        station, errors = station_from_json(data)

        self.assertEqual(errors, {"voltage_levels": {}, "transformers": {}})
        self.assertEqual(station.name, "TestStation")
        self.assertEqual([vl.vl_name for vl in station.voltage_levels], ["V800", "V69"])
        self.assertEqual([x.name for x in station.transformers], ["XFMR1"])

        # Breaker numbering must accumulate across voltage levels in
        # submission order, exactly like wizard._collect_voltage_levels's
        # `breaker_index += len(vl.breakers)` -- that counts EVERY
        # breaker-ish entity (CBR breakers AND isolating/exit DIS
        # disconnects together, not just CBR), so V800's 3 real breakers
        # (CB1-CB3) plus its 7 disconnects push V69's first breaker to
        # CB11, not CB4.
        v800, v69 = station.voltage_levels
        self.assertEqual(sorted(b.name for b in v800.breakers if b.equip_type == "CBR"), ["CB1", "CB2", "CB3"])
        self.assertEqual(len(v800.breakers), 10)
        self.assertEqual([b.name for b in v69.breakers if b.equip_type == "CBR"], ["CB11"])

    def test_summary_counts(self):
        data = {
            "name": "S1",
            "voltage_levels": [_vl("vl1", "V1", 100, "single_bus", [_tap("t1", "F1", "feeder")])],
        }
        station, _ = station_from_json(data)
        s = summary(station)
        self.assertEqual(s["total_breakers"], 1)
        self.assertEqual(s["voltage_levels"][0]["taps"], 1)
        self.assertEqual(s["scada_ied_name"], "SCADA1")


class TestPerItemErrorIsolation(unittest.TestCase):
    def test_invalid_breaker_and_half_tap_count_skips_only_that_vl(self):
        data = {
            "name": "S1",
            "voltage_levels": [
                _vl("bad", "VBad", 100, "breaker_and_half", [_tap("t1", "Line1", "line")]),  # odd count
                _vl("good", "VGood", 200, "single_bus", [_tap("t2", "Feed1", "feeder")]),
            ],
        }
        station, errors = station_from_json(data)

        self.assertIn("bad", errors["voltage_levels"])
        self.assertNotIn("good", errors["voltage_levels"])
        self.assertEqual([vl.vl_name for vl in station.voltage_levels], ["VGood"])

    def test_ring_bus_needs_at_least_3_taps(self):
        data = {
            "name": "S1",
            "voltage_levels": [
                _vl("vl1", "VRing", 100, "ring_bus", [
                    _tap("t1", "Line1", "line"), _tap("t2", "Line2", "line"),
                ]),
            ],
        }
        station, errors = station_from_json(data)
        self.assertIn("vl1", errors["voltage_levels"])
        self.assertEqual(station.voltage_levels, [])

    def test_transformer_lv_kv_not_below_hv_kv_is_isolated(self):
        data = {
            "name": "S1",
            "voltage_levels": [
                _vl("vl1", "V800", 800, "breaker_and_half", [
                    _tap("t1", "Line1", "line"),
                    _tap("t2", "XFMR1", "transformer", {
                        "name": "XFMR1", "lv_kv": 800,  # not strictly lower than HV
                        "lv_outputs": [{"name": "Feed1", "kind": "feeder"}],
                    }),
                ]),
            ],
        }
        station, errors = station_from_json(data)

        self.assertIn("t2", errors["transformers"])
        self.assertEqual([vl.vl_name for vl in station.voltage_levels], ["V800"])
        self.assertEqual(station.transformers, [])

    def test_transformer_with_no_lv_outputs_is_isolated(self):
        data = {
            "name": "S1",
            "voltage_levels": [
                _vl("vl1", "V800", 800, "breaker_and_half", [
                    _tap("t1", "Line1", "line"),
                    _tap("t2", "XFMR1", "transformer", {"name": "XFMR1", "lv_kv": 230, "lv_outputs": []}),
                ]),
            ],
        }
        station, errors = station_from_json(data)
        self.assertIn("t2", errors["transformers"])
        self.assertEqual(station.transformers, [])


class TestStillTypingIsNotAnError(unittest.TestCase):
    def test_blank_vl_name_skipped_silently(self):
        data = {"name": "S1", "voltage_levels": [_vl("vl1", "", 800, "breaker_and_half", [])]}
        station, errors = station_from_json(data)
        self.assertEqual(errors["voltage_levels"], {})
        self.assertEqual(station.voltage_levels, [])

    def test_blank_tap_name_skipped_but_vl_still_builds(self):
        data = {
            "name": "S1",
            "voltage_levels": [
                _vl("vl1", "V1", 100, "single_bus", [
                    _tap("t1", "Feed1", "feeder"),
                    _tap("t2", "", "feeder"),  # still being typed
                ]),
            ],
        }
        station, errors = station_from_json(data)
        self.assertEqual(errors["voltage_levels"], {})
        self.assertEqual(len(station.voltage_levels), 1)
        self.assertEqual(len(station.voltage_levels[0].taps), 1)

    def test_blank_transformer_name_skipped_silently(self):
        data = {
            "name": "S1",
            "voltage_levels": [
                _vl("vl1", "V800", 800, "breaker_and_half", [
                    _tap("t1", "Line1", "line"),
                    _tap("t2", "XFMR1", "transformer", {"name": "", "lv_kv": 230, "lv_outputs": []}),
                ]),
            ],
        }
        station, errors = station_from_json(data)
        self.assertEqual(errors["transformers"], {})
        self.assertEqual(station.transformers, [])

    def test_blank_station_name_is_not_an_error(self):
        station, errors = station_from_json({"name": "", "voltage_levels": []})
        self.assertNotIn("name", errors)
        self.assertEqual(station.name, "Station")

    def test_invalid_station_name_is_an_error(self):
        station, errors = station_from_json({"name": "not a valid name!", "voltage_levels": []})
        self.assertIn("name", errors)


class TestDefaultsFallback(unittest.TestCase):
    def test_omitted_defaults_use_dataclass_defaults(self):
        station, _ = station_from_json({"name": "S1", "voltage_levels": []})
        self.assertEqual(station.protection.ptoc_pickup, 1.2)
        self.assertEqual(station.network.goose_port, 8104)
        self.assertEqual(station.ied_settings.mms_port, 8102)
        self.assertEqual(station.scada.ied_name, "SCADA1")

    def test_partial_override_only_changes_given_fields(self):
        station, _ = station_from_json({
            "name": "S1", "voltage_levels": [],
            "protection": {"ptoc_pickup": 5.0},
        })
        self.assertEqual(station.protection.ptoc_pickup, 5.0)
        self.assertEqual(station.protection.ptoc_curve, "IEC_VERY_INVERSE")

    def test_empty_string_field_falls_back_to_default(self):
        station, _ = station_from_json({
            "name": "S1", "voltage_levels": [],
            "network": {"mac_prefix": ""},
        })
        self.assertEqual(station.network.mac_prefix, "01-0C-CD-01-00-")


if __name__ == "__main__":
    unittest.main()
