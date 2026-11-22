"""Tests for add_panel_image.py (#686): the build step that puts a deck panel image into the updater's catalog."""
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).with_name("add_panel_image.py")
LC6000 = [{"wd": "00.50", "tp": "00.31", "entries": [{"kind": "patch", "chip": "wd", "file": "lc6000/x.patch"}]}]


def run(*args):
    return subprocess.run([sys.executable, "-I", str(SCRIPT), *map(str, args)], capture_output=True, text=True)


class AddPanelImage(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = pathlib.Path(self.tmp.name)
        self.catalog = root / "Resources"
        self.catalog.mkdir()
        (self.catalog / "catalog.json").write_text(json.dumps({"panel": [], "lc6000": LC6000}))
        self.image = root / "firmware.bin"
        self.image.write_bytes(b"\xe9" + bytes(range(255)) * 8)

    def tearDown(self):
        self.tmp.cleanup()

    def listed(self):
        return json.loads((self.catalog / "catalog.json").read_text())

    def test_the_image_is_copied_in_and_listed_with_its_version_and_sha(self):
        result = run("--catalog", self.catalog, "--image", self.image, "--version", "1.0.0", "--sha", "1d0683f")
        self.assertEqual(result.returncode, 0, result.stderr)
        listed = self.listed()
        self.assertEqual(listed["panel"], [{"version": "1.0.0", "sha": "1d0683f", "image": "panel/deck-panel-1.0.0-1d0683f.bin"}])
        self.assertEqual(listed["lc6000"], LC6000)
        self.assertEqual((self.catalog / "panel/deck-panel-1.0.0-1d0683f.bin").read_bytes(), self.image.read_bytes())

    def refused(self, *, sha="1d0683f", version="1.0.0", image=None):
        before = (self.catalog / "catalog.json").read_text()
        result = run("--catalog", self.catalog, "--image", image or self.image, "--version", version, "--sha", sha)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.catalog / "catalog.json").read_text(), before)
        self.assertFalse((self.catalog / "panel").exists() and any((self.catalog / "panel").iterdir()))
        return result.stderr

    def test_a_dirty_build_is_refused(self):
        self.assertIn("-dirty", self.refused(sha="1d0683f-dirty"))

    def test_a_sha_that_is_not_7_to_40_hex_is_refused(self):
        for sha in ["unknown", "1d068", "1D0683F", "1d0683g"]:
            self.refused(sha=sha)

    def test_a_version_that_is_not_dotted_numbers_is_refused(self):
        for version in ["v1.0", "1..0", "", "1.0-beta"]:
            self.refused(version=version)

    def test_a_file_that_is_not_an_esp32_app_image_is_refused(self):
        other = pathlib.Path(self.tmp.name) / "other.bin"
        other.write_bytes(b"\x00" * 4096)
        self.assertIn("ESP32", self.refused(image=other))

    def test_a_sha_or_version_already_listed_is_refused(self):
        run("--catalog", self.catalog, "--image", self.image, "--version", "1.0.0", "--sha", "1d0683f")
        before = (self.catalog / "catalog.json").read_text()
        for version, sha in [("1.0.1", "1d0683f"), ("1.0.0", "2e1794a")]:
            result = run("--catalog", self.catalog, "--image", self.image, "--version", version, "--sha", sha)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual((self.catalog / "catalog.json").read_text(), before)


    def boot_parts(self, loader=b"\xe9\x03\x02\x4f" + bytes(61), table=b"\xaa\x50" + bytes(3070)):
        root = pathlib.Path(self.tmp.name)
        (root / "bootloader.bin").write_bytes(loader)
        (root / "partitions.bin").write_bytes(table)
        return root / "bootloader.bin", root / "partitions.bin"

    def test_the_builds_bootloader_and_partition_table_go_in_beside_its_image(self):
        # For making a blank board a deck panel (#687): the two other files pio upload writes.
        loader, table = self.boot_parts()
        result = run("--catalog", self.catalog, "--image", self.image, "--version", "1.0.0", "--sha", "1d0683f",
                     "--bootloader", loader, "--partitions", table)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.listed()["panel"], [{
            "version": "1.0.0", "sha": "1d0683f", "image": "panel/deck-panel-1.0.0-1d0683f.bin",
            "bootloader": "panel/deck-panel-1.0.0-1d0683f-bootloader.bin",
            "partitions": "panel/deck-panel-1.0.0-1d0683f-partitions.bin"}])
        self.assertEqual((self.catalog / "panel/deck-panel-1.0.0-1d0683f-bootloader.bin").read_bytes(), loader.read_bytes())
        self.assertEqual((self.catalog / "panel/deck-panel-1.0.0-1d0683f-partitions.bin").read_bytes(), table.read_bytes())

    def test_one_boot_part_without_the_other_or_a_misshapen_one_is_refused(self):
        loader, table = self.boot_parts()
        for extra in (["--bootloader", loader], ["--partitions", table]):
            result = run("--catalog", self.catalog, "--image", self.image, "--version", "1.0.0", "--sha", "1d0683f", *extra)
            self.assertNotEqual(result.returncode, 0, extra)
            self.assertIn("both", result.stderr)
        good_loader, good_table = b"\xe9\x03\x02\x4f" + bytes(61), b"\xaa\x50" + bytes(3070)
        for loader_bytes, table_bytes, says in [(bytes(65), good_table, "bootloader"),
                                                (b"\xe9\x03\x02\x1f" + bytes(61), good_table, "16 MB"),
                                                (good_loader, bytes(3072), "partition table"),
                                                (good_loader, b"\xaa\x50" + bytes(100), "partition table")]:
            loader, table = self.boot_parts(loader_bytes, table_bytes)
            result = run("--catalog", self.catalog, "--image", self.image, "--version", "1.0.0", "--sha", "1d0683f",
                         "--bootloader", loader, "--partitions", table)
            self.assertNotEqual(result.returncode, 0, says)
            self.assertIn(says, result.stderr)
            self.assertEqual(self.listed()["panel"], [])

if __name__ == "__main__":
    unittest.main()
