"""Tests for release_draft.py (#703): the unsigned draft release CI builds on a deck panel tag, as a folder of
flat-named files the maintainer's signing step (sign_release.sh, ADR 0012) signs."""
import hashlib
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
        # make arm's output (#696, #707): block A, block B and the build record naming them. Made up here, shaped as built.
        self.arm = root / "arm"
        self.arm.mkdir()
        self.block_a, self.block_b = b"\xa5" * 9180 + b"DFW1", b"DFWB" + bytes(60)
        (self.arm / "block.bin").write_bytes(self.block_a)
        (self.arm / "upper.bin").write_bytes(self.block_b)
        self.write_record()
        self.loader = root / "bootloader.bin"
        self.loader.write_bytes(b"\xe9\x03\x02\x4f" + bytes(61))
        self.table = root / "partitions.bin"
        self.table.write_bytes(b"\xaa\x50" + bytes(3070))

    def write_record(self, commit="0123456789ab"):
        record = {"record": 1, "commit": commit, "built": 1,
                  "block_a": {"sha1": hashlib.sha1(self.block_a).hexdigest(), "length": len(self.block_a),
                              "draw": "1", "proven": "1"},
                  "block_b": {"sha1": hashlib.sha1(self.block_b).hexdigest(), "length": len(self.block_b),
                              "layout": 1, "header_version": 4}}
        (self.arm / "build.json").write_text(json.dumps(record))

    def tearDown(self):
        self.tmp.cleanup()

    def run_script(self, tag="deck-panel-v1.1.0", sha=SHA, boot=False, blocks=False):
        extra = ["--bootloader", str(self.loader), "--partitions", str(self.table)] if boot else []
        if blocks:
            extra += ["--blocks", str(self.arm), "--blocks-wd", "00.50", "--blocks-tp", "00.31"]
        return subprocess.run([sys.executable, "-I", str(SCRIPT), "--tag", tag, "--version-file", str(self.version_file),
                               "--image", str(self.image), "--sha", sha, "--catalog", str(self.catalog),
                               "--out", str(self.out), *extra], capture_output=True, text=True)

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

    def test_the_draft_holds_the_catalog_and_exactly_the_files_it_names_with_flat_names(self):
        self.assertEqual(self.run_script().returncode, 0)
        self.assertEqual(sorted(p.name for p in self.out.iterdir()),
                         ["catalog.json", "deck-panel-1.1.0-1d0683f.bin", "wd-00.50-show-slot-16.patch"])
        catalog = json.loads((self.out / "catalog.json").read_text())
        self.assertIn({"version": "1.1.0", "sha": SHA, "image": "deck-panel-1.1.0-1d0683f.bin"}, catalog["panel"])
        self.assertEqual(catalog["lc6000"][0]["entries"][0]["file"], "wd-00.50-show-slot-16.patch")
        self.assertEqual((self.out / "deck-panel-1.1.0-1d0683f.bin").read_bytes(), self.image.read_bytes())

    def test_the_builds_shipped_before_and_the_lc6000_set_are_carried(self):
        self.assertEqual(self.run_script().returncode, 0)
        catalog = json.loads((self.out / "catalog.json").read_text())
        self.assertEqual([p["sha"] for p in catalog["panel"]], ["aaaaaaa", SHA])
        self.assertEqual(catalog["panel"][0]["image"], "deck-panel-1.0.0-aaaaaaa.bin")
        self.assertEqual([s["wd"] for s in catalog["lc6000"]], ["00.50"])

    def test_the_repos_catalog_is_left_as_it_was(self):
        before = (self.catalog / "catalog.json").read_text()
        self.assertEqual(self.run_script().returncode, 0)
        self.assertEqual((self.catalog / "catalog.json").read_text(), before)
        self.assertFalse((self.catalog / "panel").exists())

    def test_a_dirty_or_malformed_build_is_refused_and_nothing_is_made(self):
        for sha in [SHA + "-dirty", "unknown"]:
            self.assertNotEqual(self.run_script(sha=sha).returncode, 0, sha)
            self.assertFalse(self.out.exists())

    def test_it_prints_the_entry_to_record_in_the_repos_catalog(self):
        # The fallback if the signing step's pull request isn't made: the line to add to Catalog/catalog.json.
        result = self.run_script()
        line = [l for l in result.stdout.splitlines() if l.startswith("record: ")][0]
        self.assertEqual(json.loads(line[len("record: "):]),
                         {"version": "1.1.0", "sha": SHA, "image": "panel/deck-panel-1.1.0-1d0683f.bin"})


    def test_the_builds_bootloader_and_partition_table_ride_in_the_draft_with_flat_names(self):
        # For making a blank board a deck panel (#687).
        result = self.run_script(boot=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        names = sorted(p.name for p in self.out.iterdir())
        self.assertIn("deck-panel-1.1.0-1d0683f-bootloader.bin", names)
        self.assertIn("deck-panel-1.1.0-1d0683f-partitions.bin", names)
        entry = json.loads((self.out / "catalog.json").read_text())["panel"][-1]
        self.assertEqual((entry["bootloader"], entry["partitions"]),
                         ("deck-panel-1.1.0-1d0683f-bootloader.bin", "deck-panel-1.1.0-1d0683f-partitions.bin"))
        self.assertEqual((self.out / entry["partitions"]).read_bytes(), self.table.read_bytes())
        # The repo records the build as history only: version, SHA and image, never the boot parts.
        line = [l for l in result.stdout.splitlines() if l.startswith("record: ")][0]
        self.assertEqual(json.loads(line[len("record: "):]),
                         {"version": "1.1.0", "sha": SHA, "image": "panel/deck-panel-1.1.0-1d0683f.bin"})


    def test_the_drawn_displays_blocks_ride_in_the_draft_with_their_record_and_flat_names(self):
        # #707: blocks A and B and their build record, staged by #696's step, in the deck panel release.
        result = self.run_script(blocks=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.out / "block-a.bin").read_bytes(), self.block_a)
        self.assertEqual((self.out / "block-b.bin").read_bytes(), self.block_b)
        self.assertEqual(json.loads((self.out / "build.json").read_text())["commit"], "0123456789ab")
        entries = json.loads((self.out / "catalog.json").read_text())["lc6000"][0]["entries"]
        self.assertEqual([(e["kind"], e["file"], e.get("record")) for e in entries], [
            ("patch", "wd-00.50-show-slot-16.patch", None),
            ("block", "block-a.bin", "build.json"),
            ("block", "block-b.bin", "build.json")])
        # The repo records the panel build only; it never carries blocks.
        self.assertFalse((self.catalog / "blocks").exists())

    def test_blocks_the_staging_step_refuses_make_no_draft(self):
        self.write_record(commit="0123456789ab+changes")
        result = self.run_script(blocks=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("uncommitted", result.stderr)
        self.assertFalse(self.out.exists())


if __name__ == "__main__":
    unittest.main()
