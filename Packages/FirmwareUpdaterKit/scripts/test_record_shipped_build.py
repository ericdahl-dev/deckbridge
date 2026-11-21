"""Tests for record_shipped_build.py (#703): after publishing, the repo's catalog lists the build just shipped, so the
next release still carries it and the app can tell an older panel from an unknown one."""
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).with_name("record_shipped_build.py")
OLD = {"version": "1.0.0", "sha": "aaaaaaa", "image": "panel/deck-panel-1.0.0-aaaaaaa.bin"}
LC6000 = [{"wd": "00.50", "tp": "00.31", "entries": [{"kind": "patch", "chip": "wd", "file": "lc6000/x.patch"}]}]


class RecordShippedBuild(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = pathlib.Path(self.tmp.name)
        self.repo = root / "catalog.json"
        self.repo.write_text(json.dumps({"panel": [OLD], "lc6000": LC6000}, indent=2) + "\n")
        self.draft = root / "draft.json"
        self.draft.write_text(json.dumps({"panel": [
            {"version": "1.0.0", "sha": "aaaaaaa", "image": "deck-panel-1.0.0-aaaaaaa.bin"},
            {"version": "1.1.0", "sha": "1d0683f", "image": "deck-panel-1.1.0-1d0683f.bin"}], "lc6000": []}))

    def tearDown(self):
        self.tmp.cleanup()

    def run_script(self):
        return subprocess.run([sys.executable, "-I", str(SCRIPT), "--draft", str(self.draft), "--catalog", str(self.repo)],
                              capture_output=True, text=True)

    def test_the_new_build_is_added_with_the_repos_nested_name_and_the_rest_is_kept(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        repo = json.loads(self.repo.read_text())
        self.assertEqual(repo["panel"], [OLD, {"version": "1.1.0", "sha": "1d0683f", "image": "panel/deck-panel-1.1.0-1d0683f.bin"}])
        self.assertEqual(repo["lc6000"], LC6000)

    def test_running_it_twice_records_the_build_once(self):
        self.run_script()
        before = self.repo.read_text()
        result = self.run_script()
        self.assertEqual(result.returncode, 3)  # nothing new: the caller makes no pull request
        self.assertEqual(self.repo.read_text(), before)


if __name__ == "__main__":
    unittest.main()
