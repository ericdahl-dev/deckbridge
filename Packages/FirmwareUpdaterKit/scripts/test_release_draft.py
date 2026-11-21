"""Tests for release_draft.py (#703): the unsigned draft release CI builds on a deck panel tag, as a folder of
flat-named files the maintainer's signing step (sign_release.sh, ADR 0012) signs."""
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).with_name("release_draft.py")
SHA = "1d0683f"


class ReleaseDraft(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = pathlib.Path(self.tmp.name)
        self.catalog = root / "Catalog"
        (self.catalog / "lc6000").mkdir(parents=True)
        (self.catalog / "lc6000/wd-00.50-show-slot-16.patch").write_text("0x0800BDA4 0f28 1028\n")
        (self.catalog / "catalog.json").write_text(json.dumps({
            "panel": [{"version": "1.0.0", "sha": "aaaaaaa", "image": "panel/deck-panel-1.0.0-aaaaaaa.bin"}],
            "lc6000": [{"wd": "00.50", "tp": "00.31", "entries": [
                {"kind": "patch", "chip": "wd", "file": "lc6000/wd-00.50-show-slot-16.patch"}]}]}))
        self.version_file = root / "VERSION"
        self.version_file.write_text("1.1.0\n")
        self.image = root / "firmware.bin"
        self.image.write_bytes(b"\xe9" + bytes(1024))
        self.out = root / "draft"

    def tearDown(self):
        self.tmp.cleanup()

    def run_script(self, tag="deck-panel-v1.1.0", sha=SHA):
        return subprocess.run([sys.executable, "-I", str(SCRIPT), "--tag", tag, "--version-file", str(self.version_file),
                               "--image", str(self.image), "--sha", sha, "--catalog", str(self.catalog),
                               "--out", str(self.out)], capture_output=True, text=True)

    def test_a_tag_matching_the_panels_version_makes_a_draft_folder(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.out / "catalog.json").exists())

    def test_a_tag_that_does_not_match_the_panels_version_is_refused_and_nothing_is_made(self):
        for tag in ["deck-panel-v1.0.9", "deck-panel-1.1.0", "v1.1.0", "deck-panel-v1.1.0-rc1"]:
            result = self.run_script(tag=tag)
            self.assertNotEqual(result.returncode, 0, tag)
            self.assertIn("VERSION", result.stderr)
            self.assertFalse(self.out.exists())


if __name__ == "__main__":
    unittest.main()
