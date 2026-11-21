"""Tests for check_staged_blocks.py (#696): the staged blocks must be byte for byte what a fresh `make arm` of the
same commit builds. The blocks here are made up in the tests."""
import pathlib
import subprocess
import sys
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).with_name("check_staged_blocks.py")


def run(*args):
    return subprocess.run([sys.executable, "-I", str(SCRIPT), *map(str, args)], capture_output=True, text=True)


class CheckStagedBlocks(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = pathlib.Path(self.tmp.name)
        self.catalog, self.rebuild = root / "Catalog", root / "arm-again"
        (self.catalog / "blocks").mkdir(parents=True)
        self.rebuild.mkdir()
        self.a, self.b = b"\xa5" * 9180 + b"DFW1", b"DFWB" + bytes(60)
        for folder, a, b in ((self.catalog / "blocks", "block-a.bin", "block-b.bin"), (self.rebuild, "block.bin", "upper.bin")):
            (folder / a).write_bytes(self.a)
            (folder / b).write_bytes(self.b)

    def tearDown(self):
        self.tmp.cleanup()

    def check(self):
        return run("--catalog", self.catalog, "--build", self.rebuild)

    def test_blocks_identical_to_the_rebuild_pass(self):
        result = self.check()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_one_byte_off_in_either_block_fails(self):
        for staged in ("block-a.bin", "block-b.bin"):
            with self.subTest(staged):
                path = self.catalog / "blocks" / staged
                good = path.read_bytes()
                path.write_bytes(good[:-1] + bytes([good[-1] ^ 1]))
                result = self.check()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(f"{staged} isn't what this commit builds", result.stderr)
                path.write_bytes(good)

    def test_nothing_staged_or_nothing_rebuilt_fails(self):
        (self.rebuild / "upper.bin").unlink()
        self.assertNotEqual(self.check().returncode, 0)
        (self.rebuild / "upper.bin").write_bytes(self.b)
        (self.catalog / "blocks" / "block-a.bin").unlink()
        self.assertNotEqual(self.check().returncode, 0)


if __name__ == "__main__":
    unittest.main()
