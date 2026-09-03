import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from generator.naming import (
    validate_ied_name, validate_identifier, sanitize_identifier,
    mac_address, appid, NameError_,
)


class TestValidateIedName(unittest.TestCase):
    def test_accepts_real_worked_example_names(self):
        for name in ("CB1", "CB6", "XFMR1", "SCADA1", "BRK1", "BRK2"):
            validate_ied_name(name)  # must not raise

    def test_accepts_short_names(self):
        validate_ied_name("A")
        validate_ied_name("AB")
        validate_ied_name("ABC")

    def test_accepts_long_names_up_to_64(self):
        validate_ied_name("A" * 64)

    def test_rejects_hyphens(self):
        with self.assertRaises(NameError_):
            validate_ied_name("IED-BRK1")

    def test_rejects_leading_digit(self):
        with self.assertRaises(NameError_):
            validate_ied_name("1CB")

    def test_rejects_over_64_chars(self):
        with self.assertRaises(NameError_):
            validate_ied_name("A" * 65)

    def test_rejects_empty(self):
        with self.assertRaises(NameError_):
            validate_ied_name("")

    def test_rejects_spaces(self):
        with self.assertRaises(NameError_):
            validate_ied_name("CB 1")

    def test_four_char_names_not_starting_with_n(self):
        validate_ied_name("CB10")
        validate_ied_name("Fred")

    def test_four_char_names_starting_with_n(self):
        # N + [0-9A-Za-np-z_] (excludes o/O) + 2 more -- "Node" has 'o' as
        # its 2nd char, which the real schema pattern excludes.
        with self.assertRaises(NameError_):
            validate_ied_name("Node")
        validate_ied_name("Na12")


class TestValidateIdentifier(unittest.TestCase):
    def test_accepts_worked_example_names(self):
        for name in ("V800", "BusA800", "Diameter1", "N1", "Line1", "Feed1"):
            validate_identifier(name)

    def test_rejects_slash(self):
        with self.assertRaises(NameError_):
            validate_identifier("Bus/A")

    def test_rejects_leading_digit(self):
        with self.assertRaises(NameError_):
            validate_identifier("1Bus")

    def test_rejects_empty(self):
        with self.assertRaises(NameError_):
            validate_identifier("")


class TestSanitizeIdentifier(unittest.TestCase):
    def test_replaces_spaces_and_punctuation(self):
        self.assertEqual(sanitize_identifier("Bus A 800kV!"), "Bus_A_800kV")

    def test_prefixes_leading_digit(self):
        self.assertEqual(sanitize_identifier("800kV Bus"), "_800kV_Bus")

    def test_idempotent_on_already_clean_name(self):
        self.assertEqual(sanitize_identifier("Diameter1"), "Diameter1")


class TestAddressHelpers(unittest.TestCase):
    def test_mac_address_matches_worked_example(self):
        self.assertEqual(mac_address("01-0C-CD-01-00-", 1), "01-0C-CD-01-00-01")
        self.assertEqual(mac_address("01-0C-CD-01-00-", 20), "01-0C-CD-01-00-20")

    def test_appid_matches_worked_example(self):
        self.assertEqual(appid(1, 1), "0001")
        self.assertEqual(appid(1, 6), "0006")
        self.assertEqual(appid(20, 1), "0020")


if __name__ == "__main__":
    unittest.main()
