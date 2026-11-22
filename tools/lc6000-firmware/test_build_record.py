"""Tests for build_record.py (#572): `make arm` records how blocks A and B were built, and the kit reads that record
instead of asking the owner. The record is trusted only for the exact bytes it names: A's inside the owner's image and
B's inside its .dfu. Anything missing, unreadable or mismatched refuses; nothing is ever assumed. Synthetic data only.
Run from the repo root: python3 -I -m unittest discover tools/lc6000-firmware"""
import contextlib, io, json, os, tempfile, unittest

import build_record
import dfupatch
from test_build_upper_dfu import good_block
from test_dfupatch import dfuse_file, full_wd_element

APP_BASE = 0x08008000
UPPER = 0x08080000


def block_a(seed):
    """A synthetic block A: fills the padding, its bytes set by `seed` so two builds differ."""
    size = dfupatch.PAD_END - dfupatch.PAD_START
    return bytes((i * 13 + seed) & 0xFF for i in range(size))


def owner_element(a):
    element = bytearray(full_wd_element())
    element[dfupatch.PAD_START - APP_BASE:dfupatch.PAD_END - APP_BASE] = a
    return bytes(element)


def run(*argv):
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        try:
            code = build_record.main(list(argv))
        except SystemExit as e:
            code = e.code
    return code, out.getvalue(), err.getvalue()


class BuildRecordTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)

    def path(self, name, data):
        p = os.path.join(self.dir.name, name)
        with open(p, "wb" if isinstance(data, bytes) else "w") as f:
            f.write(data)
        return p

    def record(self, a=None, b=None, draw="1", proven="1", name="build.json"):
        """A record as `make arm` writes it, for these blocks and flags."""
        a_bin = self.path("block.bin", a if a is not None else block_a(1))
        b_bin = self.path("upper.bin", b if b is not None else good_block())
        out = os.path.join(self.dir.name, name)
        code, _, err = run("write", a_bin, b_bin, "--draw", draw, "--proven", proven, out)
        self.assertEqual(code, 0, err)
        return out

    def files(self, a=None, b=None):
        owner = self.path("owner.dfu", dfuse_file(owner_element(a if a is not None else block_a(1)), APP_BASE))
        upper = self.path("upper.dfu", dfuse_file(b if b is not None else good_block(), UPPER))
        return owner, upper

    def check(self, record, owner, upper):
        return run("check", record, owner, upper)

    def assertRefused(self, result, *words):
        code, out, err = result
        self.assertNotEqual(code, 0, out)
        self.assertIn("refused", err)
        for word in words:
            self.assertIn(word, err)

    def test_the_record_for_these_very_files_says_proven_and_same_build(self):
        code, out, err = self.check(self.record(), *self.files())
        self.assertEqual(code, 0, err)
        self.assertIn("ARM_UPPER_PROVEN=1", out)
        self.assertIn("same build", out)

    def test_a_record_from_one_build_next_to_files_from_another_refuses(self):
        record = self.record(a=block_a(1))
        self.assertRefused(self.check(record, *self.files(a=block_a(2))), "block A", "owner's image")
        other_b = good_block()[:-1] + b"8"
        import upper_header  # noqa: E402  (on sys.path through build_upper_dfu)
        other_b = upper_header.seal(other_b)
        self.assertRefused(self.check(record, *self.files(b=other_b)), "block B")

    def test_a_missing_or_unreadable_record_refuses(self):
        owner, upper = self.files()
        self.assertRefused(self.check(os.path.join(self.dir.name, "none.json"), owner, upper), "no build record")
        self.assertRefused(self.check(self.path("bad.json", "{ not json"), owner, upper), "build record")
        self.assertRefused(self.check(self.path("short.json", json.dumps({"record": 1})), owner, upper),
                           "build record")

    def test_a_block_a_built_without_the_proof_refuses_even_when_its_bytes_match(self):
        self.assertRefused(self.check(self.record(proven="0"), *self.files()), "ARM_UPPER_PROVEN=0")

    def test_a_block_a_without_drawing_refuses(self):
        for draw in ("0", "stub"):
            with self.subTest(draw):
                self.assertRefused(self.check(self.record(draw=draw), *self.files()), f"ARM_DRAW={draw}")

    def test_files_that_arent_the_owners_image_and_block_b_refuse(self):
        record = self.record()
        owner, upper = self.files()
        self.assertRefused(self.check(record, upper, owner))

    def test_the_record_says_which_commit_and_when_it_was_built(self):
        # #603: the wizard picks the newest build and shows its commit and time on the word screen.
        import subprocess, time
        before = time.time()
        with open(self.record()) as f:
            record = json.load(f)
        here = os.path.dirname(os.path.realpath(build_record.__file__))
        head = subprocess.run(["git", "-C", here, "rev-parse", "--short=12", "HEAD"], capture_output=True,
                              text=True).stdout.strip()
        self.assertTrue(record["commit"].startswith(head), record["commit"])
        self.assertLessEqual(abs(record["built"] - before), 5)

    def test_judge_hands_back_the_record_for_the_plan(self):
        owner, upper = self.files()
        judged = build_record.judge(self.record(), owner, upper)
        self.assertEqual((judged.draw, judged.proven), ("1", "1"))


if __name__ == "__main__":
    unittest.main()
