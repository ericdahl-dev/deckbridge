"""Tests for build_upper_dfu.py (#501): block B's own DfuSe file at 0x08080000, built only with the owner's read-only
read of the upper flash as proof that sector 8 exists and is empty. Synthetic data only, no vendor bytes.
Run from the repo root: python3 -I -m unittest discover tools/lc6000-firmware"""
import contextlib, io, json, os, struct, tempfile, unittest

import build_record
import build_upper_dfu
import dfupatch

upper_header = build_upper_dfu.upper_header  # B's header (#572)
UPPER = upper_header.BASE
PROOF_SIZE = 512 * 1024


def good_block():
    """The same B as the C header tests (arm/test/test_hook.c), sealed by upper_header: its layout word (#516) and its
    draw and band entries (#524)."""
    return upper_header.build(b"123456789", 0x1A2B3C4D, 0x0808001D, 0x0808001F)


def run(*argv):
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        code = build_upper_dfu.main(list(argv))
    return code, out.getvalue(), err.getvalue()


class BuildUpperDfuTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)

    def path(self, name, content=None):
        path = os.path.join(self.dir.name, name)
        if content is not None:
            with open(path, "wb") as f:
                f.write(content)
        return path

    def build(self, block=None, proof=None):
        blob = self.path("upper.bin", block if block is not None else good_block())
        read = self.path("wd-upper-512k.bin", proof if proof is not None else b"\xff" * PROOF_SIZE)
        output = self.path("upper.dfu")
        code, out, err = run(blob, output, "--proof", read)
        return code, out, err, output

    def test_a_good_block_with_the_proof_becomes_one_element_at_0x08080000(self):
        code, _, err, output = self.build()
        self.assertEqual(code, 0, err)
        image = dfupatch.parse(dfupatch.read(output))
        self.assertEqual(image.address, UPPER)
        self.assertEqual(image.element, good_block())

    def assertRefused(self, result, reason):
        code, out, err, output = result
        self.assertEqual(code, 1)
        self.assertIn(reason, err)
        self.assertFalse(os.path.exists(output), "nothing is written when refused")

    def test_without_the_proof_it_is_refused(self):
        blob = self.path("upper.bin", good_block())
        output = self.path("upper.dfu")
        code, out, err = run(blob, output)
        self.assertRefused((code, out, err, output), "--proof")


    def test_a_proof_that_isnt_the_whole_512k_read_is_refused(self):
        self.assertRefused(self.build(proof=b"\xff" * (PROOF_SIZE - 1)), "524288")
        self.assertRefused(self.build(proof=b""), "524288")


    def test_a_proof_with_anything_but_erased_flash_is_refused(self):
        proof = bytearray(b"\xff" * PROOF_SIZE)
        proof[0x1234] = 0x00
        self.assertRefused(self.build(proof=bytes(proof)), "erased")


    def test_a_proof_inside_the_repository_is_refused(self):
        repo_dir = tempfile.TemporaryDirectory(dir=dfupatch.repository_root())
        self.addCleanup(repo_dir.cleanup)
        proof = os.path.join(repo_dir.name, "wd-upper-512k.bin")
        with open(proof, "wb") as f:
            f.write(b"\xff" * PROOF_SIZE)
        blob = self.path("upper.bin", good_block())
        output = self.path("upper.dfu")
        code, out, err = run(blob, output, "--proof", proof)
        self.assertRefused((code, out, err, output), "outside the repository")


    def test_a_block_whose_header_doesnt_check_out_is_refused(self):
        good = good_block()
        bad_crc = bytearray(good)
        bad_crc[32] ^= 1
        cases = {
            "marker": b"\xff\xff\xff\xff" + good[4:],
            # Another version, its CRC still good (the CRC starts past the version): refused on the version alone.
            "version": good[:upper_header.VERSION_AT] + struct.pack("<I", upper_header.VERSION + 1)
            + good[upper_header.VERSION_AT + 4:],
            "CRC": bytes(bad_crc),
            "length": good + b"\xff",  # the file is longer than the header's length
            # No Thumb bit, sealed with a good CRC, so only the entry check can refuse it.
            "draw entry": upper_header.build(b"123456789", 0x1A2B3C4D, 0x0808001C, 0x0808001F),
            "band entry": upper_header.build(b"123456789", 0x1A2B3C4D, 0x0808001D, 0x0808001E),
        }
        for reason, block in cases.items():
            with self.subTest(reason):
                self.assertRefused(self.build(block=block), reason)


    def test_it_wont_write_inside_the_repository_or_over_a_file(self):
        repo_dir = tempfile.TemporaryDirectory(dir=dfupatch.repository_root())
        self.addCleanup(repo_dir.cleanup)
        blob = self.path("upper.bin", good_block())
        proof = self.path("wd-upper-512k.bin", b"\xff" * PROOF_SIZE)
        inside = os.path.join(repo_dir.name, "upper.dfu")
        code, out, err = run(blob, inside, "--proof", proof)
        self.assertRefused((code, out, err, inside), "outside the repository")
        existing = self.path("upper.dfu", b"keep me")
        code, out, err = run(blob, existing, "--proof", proof)
        self.assertEqual(code, 1)
        self.assertIn("already exists", err)
        self.assertEqual(dfupatch.read(existing), b"keep me")


    def test_the_build_record_beside_the_block_travels_with_the_dfu(self):
        # make arm writes build.json beside upper.bin; the wizard finds it beside the .dfu (#593).
        record = build_record.record_of(bytes(dfupatch.PAD_END - dfupatch.PAD_START), good_block(), "1", "1")
        with open(self.path("build.json"), "w") as f:
            json.dump(record, f)
        code, out, err, output = self.build()
        self.assertEqual(code, 0, err)
        with open(self.path("upper.build.json")) as f:
            self.assertEqual(json.load(f), record)
        self.assertIn("upper.build.json", out)

    def test_a_record_for_another_b_or_none_doesnt_travel(self):
        other = build_record.record_of(b"", upper_header.build(b"other", 0x1A2B3C4D, 0x0808001D, 0x0808001F), "1", "1")
        for record in (other, None):
            with self.subTest(record=record is not None):
                self.setUp()
                if record:
                    with open(self.path("build.json"), "w") as f:
                        json.dump(record, f)
                code, out, err, output = self.build()
                self.assertEqual(code, 0, err)
                self.assertTrue(os.path.exists(output))
                self.assertFalse(os.path.exists(self.path("upper.build.json")))
                self.assertIn("no build record", out)


if __name__ == "__main__":
    unittest.main()
