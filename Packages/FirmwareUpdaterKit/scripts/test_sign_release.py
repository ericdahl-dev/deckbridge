"""Tests for sign_release.sh (#689, ADR 0012): the maintainer's one release step, against a fake `gh` and a fake
signing tool, so no GitHub release, key or passphrase is touched."""
import os
import pathlib
import stat
import subprocess
import tempfile
import textwrap
import unittest

SCRIPT = pathlib.Path(__file__).with_name("sign_release.sh")


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

    def tearDown(self):
        self.tmp.cleanup()

    def run_script(self):
        executable(self.bin / "gh", f"""
            echo "gh $*" >> "{self.log}"
            case "$1 $2" in
              "release view") echo "{self.draft}" ;;
              "release download") dir=""; while [ $# -gt 0 ]; do [ "$1" = --dir ] && dir="$2"; shift; done
                                  echo '{{"panel": [], "lc6000": []}}' > "$dir/catalog.json"
                                  {'echo old > "$dir/manifest.json"; echo old > "$dir/manifest.sig"' if self.signed_before else ""} ;;
            esac
            """)
        executable(self.bin / "firmware-release", f"""
            echo "firmware-release $*" >> "{self.log}"
            {"exit 1" if self.sign_fails else ""}
            dir=""; while [ $# -gt 0 ]; do [ "$1" = --folder ] && dir="$2"; shift; done
            [ -e "$dir/manifest.json" ] || [ -e "$dir/manifest.sig" ] && {{ echo "unnamed file manifest.json" >&2; exit 1; }}
            echo manifest > "$dir/manifest.json"; echo sig > "$dir/manifest.sig"
            """)
        env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}", FIRMWARE_RELEASE=str(self.bin / "firmware-release"))
        result = subprocess.run([str(SCRIPT), "panel-v1.1.0", "--key", "/keys/primary.key", "--lowest", "1.0.0"],
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


if __name__ == "__main__":
    unittest.main()
