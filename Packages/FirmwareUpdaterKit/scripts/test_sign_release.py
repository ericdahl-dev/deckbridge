"""Tests for sign_release.sh (#689, ADR 0012): the maintainer's one release step, against a fake `gh` and a fake
signing tool, so no GitHub release, key or passphrase is touched. The script runs from a copy inside a throwaway git
repo with a throwaway origin, so the pull request it opens after publishing (#703) never touches this repo."""
import json
import os
import pathlib
import shutil
import stat
import subprocess
import tempfile
import textwrap
import unittest

HERE = pathlib.Path(__file__).parent
CATALOG = "Packages/FirmwareUpdaterKit/Sources/FirmwareCatalog/Catalog/catalog.json"
OLD = {"version": "1.0.0", "sha": "aaaaaaa", "image": "panel/deck-panel-1.0.0-aaaaaaa.bin"}
GIT_ENV = {"GIT_AUTHOR_NAME": "test", "GIT_AUTHOR_EMAIL": "test@example.invalid", "GIT_COMMITTER_NAME": "test",
           "GIT_COMMITTER_EMAIL": "test@example.invalid", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"}


def executable(path, body):
    path.write_text("#!/bin/sh\n" + textwrap.dedent(body))
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


class SignRelease(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = pathlib.Path(self.tmp.name)
        self.bin = root / "bin"
        self.bin.mkdir()
        self.log = root / "calls.log"
        self.draft = "true"
        self.sign_fails = False
        self.signed_before = False
        self.publish_fails = False
        self.new_build = False
        self.repo, self.origin = root / "repo", root / "origin.git"
        scripts = self.repo / "Packages/FirmwareUpdaterKit/scripts"
        scripts.mkdir(parents=True)
        for name in ["sign_release.sh", "record_shipped_build.py"]:
            shutil.copy2(HERE / name, scripts / name)
        (self.repo / CATALOG).parent.mkdir(parents=True)
        (self.repo / CATALOG).write_text(json.dumps({"panel": [OLD], "lc6000": []}, indent=2) + "\n")
        self.git("init", "-q", "-b", "main")
        self.git("add", ".")
        self.git("commit", "-q", "-m", "start")
        subprocess.run(["git", "init", "-q", "--bare", str(self.origin)], check=True, env=dict(os.environ, **GIT_ENV))
        self.git("remote", "add", "origin", str(self.origin))
        self.git("push", "-q", "origin", "main")
        self.script = scripts / "sign_release.sh"

    def git(self, *args, cwd=None):
        return subprocess.run(["git", *args], cwd=cwd or self.repo, check=True, capture_output=True, text=True,
                              env=dict(os.environ, **GIT_ENV)).stdout

    def tearDown(self):
        self.tmp.cleanup()

    def run_script(self):
        executable(self.bin / "gh", f"""
            echo "gh $*" >> "{self.log}"
            case "$1 $2" in
              "release view") echo "{self.draft}" ;;
              "release download") dir=""; while [ $# -gt 0 ]; do [ "$1" = --dir ] && dir="$2"; shift; done
                                  echo '{json.dumps({"panel": [{"version": "1.0.0", "sha": "aaaaaaa", "image": "deck-panel-1.0.0-aaaaaaa.bin"}] + ([{"version": "1.1.0", "sha": "1d0683f", "image": "deck-panel-1.1.0-1d0683f.bin"}] if self.new_build else []), "lc6000": []})}' > "$dir/catalog.json"
                                  {'echo old > "$dir/manifest.json"; echo old > "$dir/manifest.sig"' if self.signed_before else ""} ;;
              "release edit") {"exit 1" if self.publish_fails else ""} ;;
            esac
            """)
        executable(self.bin / "firmware-release", f"""
            echo "firmware-release $*" >> "{self.log}"
            {"exit 1" if self.sign_fails else ""}
            dir=""; while [ $# -gt 0 ]; do [ "$1" = --folder ] && dir="$2"; shift; done
            [ -e "$dir/manifest.json" ] || [ -e "$dir/manifest.sig" ] && {{ echo "unnamed file manifest.json" >&2; exit 1; }}
            echo manifest > "$dir/manifest.json"; echo sig > "$dir/manifest.sig"
            """)
        env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}", FIRMWARE_RELEASE=str(self.bin / "firmware-release"),
                   **GIT_ENV)
        result = subprocess.run([str(self.script), "deck-panel-v1.1.0", "--key", "/keys/primary.key", "--lowest", "1.0.0"],
                                capture_output=True, text=True, env=env)
        calls = self.log.read_text().splitlines() if self.log.exists() else []
        return result, [" ".join(c.split()[:3]) for c in calls]

    def test_a_draft_is_downloaded_signed_uploaded_and_published_in_that_order(self):
        result, calls = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, ["gh release view", "gh release download", "firmware-release sign --key",
                                 "gh release upload", "gh release edit"])
        upload = [c for c in self.log.read_text().splitlines() if c.startswith("gh release upload")][0]
        self.assertIn("manifest.json", upload)
        self.assertIn("manifest.sig", upload)
        self.assertIn("--draft=false", self.log.read_text().splitlines()[-1])

    def test_a_release_that_is_not_a_draft_is_not_touched(self):
        self.draft = "false"
        result, calls = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, ["gh release view"])

    def test_when_signing_fails_nothing_is_uploaded_or_published(self):
        self.sign_fails = True
        result, calls = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, ["gh release view", "gh release download", "firmware-release sign --key"])

    def test_a_run_that_uploaded_but_did_not_publish_can_be_run_again(self):
        # The draft then already holds manifest.json and manifest.sig: they are re-made, and the upload replaces them.
        self.signed_before = True
        result, calls = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        upload = [c for c in self.log.read_text().splitlines() if c.startswith("gh release upload")][0]
        self.assertIn("--clobber", upload)

    def test_after_publishing_a_new_build_it_opens_a_pull_request_recording_it(self):
        self.new_build = True
        result, calls = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls[-2:], ["gh release edit", "gh pr create"])
        pushed = json.loads(self.git("show", f"record-deck-panel-v1.1.0:{CATALOG}", cwd=self.origin))
        self.assertEqual(pushed["panel"], [OLD, {"version": "1.1.0", "sha": "1d0683f", "image": "panel/deck-panel-1.1.0-1d0683f.bin"}])
        self.assertEqual(json.loads((self.repo / CATALOG).read_text())["panel"], [OLD])  # the owner's checkout untouched
        self.assertNotIn("record-deck-panel-v1.1.0", self.git("worktree", "list"))

    def test_no_pull_request_when_publishing_failed(self):
        self.new_build, self.publish_fails = True, True
        result, calls = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("gh pr create", calls)
        self.assertNotIn("record-", self.git("branch", "-a", cwd=self.origin))

    def test_no_pull_request_when_the_build_is_already_recorded(self):
        result, calls = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("gh pr create", calls)
        self.assertNotIn("record-", self.git("branch", "-a"))


if __name__ == "__main__":
    unittest.main()
