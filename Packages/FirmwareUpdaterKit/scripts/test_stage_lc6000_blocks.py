"""Tests for stage_lc6000_blocks.py (#696): the release step that puts the drawn display's own block A and block B,
as `make arm` built them, into the updater's catalog. The blocks here are made up in the tests."""
import hashlib
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).with_name("stage_lc6000_blocks.py")
PATCHES = [{"kind": "patch", "chip": "wd", "file": "lc6000/x.patch"}]


def run(*args):
    return subprocess.run([sys.executable, "-I", str(SCRIPT), *map(str, args)], capture_output=True, text=True)


def sha1(data):
    return hashlib.sha1(data).hexdigest()


class StageBlocks(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = pathlib.Path(self.tmp.name)
        self.catalog = root / "Catalog"
        self.catalog.mkdir()
        self.lc6000 = [{"wd": "00.50", "tp": "00.31", "entries": list(PATCHES)}]
        (self.catalog / "catalog.json").write_text(json.dumps({"panel": [], "lc6000": self.lc6000}))
        self.build = root / "arm"
        self.build.mkdir()
        self.a = b"\xa5" * 9180 + b"DFW1"
        self.b = b"DFWB" + bytes(60)
        (self.build / "block.bin").write_bytes(self.a)
        (self.build / "upper.bin").write_bytes(self.b)
        self.write_record()

    def tearDown(self):
        self.tmp.cleanup()

    def write_record(self, *, a=None, b=None, draw="1", proven="1", commit="0123456789ab"):
        a, b = a or self.a, b or self.b
        record = {"record": 1, "commit": commit, "built": 1,
                  "block_a": {"sha1": sha1(a), "length": len(a), "draw": draw, "proven": proven},
                  "block_b": {"sha1": sha1(b), "length": len(b), "layout": 1, "header_version": 4}}
        (self.build / "build.json").write_text(json.dumps(record))

    def stage(self):
        return run("--catalog", self.catalog, "--build", self.build, "--wd", "00.50", "--tp", "00.31")

    def test_both_blocks_and_their_record_are_copied_in_and_listed_in_the_set(self):
        result = self.stage()
        self.assertEqual(result.returncode, 0, result.stderr)
        listed = json.loads((self.catalog / "catalog.json").read_text())
        self.assertEqual(listed["lc6000"][0]["entries"], PATCHES + [
            {"kind": "block", "chip": "wd", "part": "a", "file": "blocks/block-a.bin", "record": "blocks/build.json"},
            {"kind": "block", "chip": "wd", "part": "b", "file": "blocks/block-b.bin", "record": "blocks/build.json"},
        ])
        self.assertEqual((self.catalog / "blocks/block-a.bin").read_bytes(), self.a)
        self.assertEqual((self.catalog / "blocks/block-b.bin").read_bytes(), self.b)
        self.assertEqual((self.catalog / "blocks/build.json").read_bytes(), (self.build / "build.json").read_bytes())

    def refused(self, says):
        before = (self.catalog / "catalog.json").read_text()
        result = self.stage()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(says, result.stderr)
        self.assertEqual((self.catalog / "catalog.json").read_text(), before)
        self.assertFalse((self.catalog / "blocks").exists())

    def test_a_record_naming_another_block_a_or_b_is_refused_as_different_builds(self):
        self.write_record(a=b"\xa6" * 9180 + b"DFW1")
        self.refused("different builds")
        self.write_record(b=b"DFWB" + bytes(61))
        self.refused("different builds")

    def test_a_build_from_uncommitted_changes_or_outside_git_is_refused(self):
        self.write_record(commit="0123456789ab+changes")
        self.refused("uncommitted")
        self.write_record(commit="unknown")
        self.refused("commit")

    def test_a_block_a_that_does_not_draw_or_never_reads_block_b_is_refused(self):
        self.write_record(draw="0")
        self.refused("ARM_DRAW=0")
        self.write_record(proven="0")
        self.refused("ARM_UPPER_PROVEN=0")

    def test_no_record_or_no_set_for_the_versions_is_refused(self):
        (self.build / "build.json").unlink()
        self.refused("build record")
        self.write_record()
        (self.catalog / "catalog.json").write_text(json.dumps({"panel": [], "lc6000": []}))
        self.refused("00.50")

    def test_a_set_that_already_carries_blocks_is_refused(self):
        self.lc6000[0]["entries"].append({"kind": "block", "chip": "wd", "part": "a", "file": "blocks/block-a.bin",
                                          "record": "blocks/build.json"})
        (self.catalog / "catalog.json").write_text(json.dumps({"panel": [], "lc6000": self.lc6000}))
        self.refused("already")


if __name__ == "__main__":
    unittest.main()
