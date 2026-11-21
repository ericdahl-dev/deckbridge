"""Tests for git_sha.py's build version (#695): run with python3 -I tools/deck-panel/test_git_sha.py."""
import pathlib
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import git_sha  # noqa: E402


def git(cwd, *args):
    subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True)


class BuildVersion(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = pathlib.Path(self.tmp.name)
        self.panel = root / "tools" / "deck-panel"
        self.panel.mkdir(parents=True)
        (self.panel / "VERSION").write_text("1.2.0\n")
        git(root, "init", "-q")
        git(root, "-c", "user.email=t@t", "-c", "user.name=t", "add", ".")
        git(root, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "one")
        self.root = root

    def tearDown(self):
        self.tmp.cleanup()

    def test_a_clean_build_on_its_release_tag_is_a_release(self):
        git(self.root, "tag", "deck-panel-v1.2.0")
        self.assertEqual(git_sha.build_version(str(self.panel)), ("1.2.0", True))

    def test_without_the_tag_it_is_a_local_build(self):
        self.assertEqual(git_sha.build_version(str(self.panel)), ("1.2.0", False))

    def test_a_tag_for_another_version_is_a_local_build(self):
        git(self.root, "tag", "deck-panel-v1.1.0")
        self.assertEqual(git_sha.build_version(str(self.panel)), ("1.2.0", False))

    def test_uncommitted_changes_on_the_release_tag_are_a_local_build(self):
        git(self.root, "tag", "deck-panel-v1.2.0")
        (self.panel / "main.cpp").write_text("changed\n")
        self.assertEqual(git_sha.build_version(str(self.panel)), ("1.2.0", False))

    def test_a_version_that_isnt_dotted_digits_stops_the_build(self):
        (self.panel / "VERSION").write_text("1.2.0-beta\n")
        with self.assertRaises(ValueError):
            git_sha.build_version(str(self.panel))

    def test_outside_git_it_is_a_local_build(self):
        with tempfile.TemporaryDirectory() as bare:
            (pathlib.Path(bare) / "VERSION").write_text("1.2.0\n")
            self.assertEqual(git_sha.build_version(bare), ("1.2.0", False))


if __name__ == "__main__":
    unittest.main()
