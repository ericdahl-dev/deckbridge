"""Tests for drawn_flash.py (#468): the checks the flash-day wizard's drawn path runs before and after each write. Synthetic
files only; no vendor data, nothing sent to a unit.
Run from the repo root: python3 -I -m unittest discover tools/lc6000-firmware"""
import contextlib, io, os, subprocess, sys, tempfile, unittest

import drawn_flash
from test_build_upper_dfu import good_block
from test_dfupatch import dfuse_file, full_wd_element

UPPER, UPPER_SIZE = 0x08080000, 0x80000


def run(*argv):
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        code = drawn_flash.main(list(argv))
    return code, out.getvalue(), err.getvalue()


class DrawnFlashTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)

    def path(self, name, content):
        path = os.path.join(self.dir.name, name)
        with open(path, "wb") as f:
            f.write(content)
        return path

    def upper_dfu(self, block=None, address=UPPER):
        return self.path("upper.dfu", dfuse_file(block if block is not None else good_block(), address))

    def owner_dfu(self, address=0x08008000):
        return self.path("owner.dfu", dfuse_file(full_wd_element(), address))

    def assertRefused(self, result, reason):
        code, _, err = result
        self.assertEqual(code, 1)
        self.assertIn(reason, err)


class FilesTests(DrawnFlashTests):
    """Before either typed word: each file is what its step writes, so the two can't be swapped."""

    def test_block_b_and_the_owners_image_in_their_places_pass(self):
        code, out, _ = run("files", self.upper_dfu(), self.owner_dfu())
        self.assertEqual(code, 0)
        self.assertIn("0x08080000", out)
        self.assertIn("0x08008000", out)

    def test_the_two_files_swapped_are_refused(self):
        self.assertRefused(run("files", self.owner_dfu(), self.upper_dfu()), "block B")

    def test_a_block_b_file_anywhere_but_0x08080000_is_refused(self):
        self.assertRefused(run("files", self.upper_dfu(address=0x08008000), self.owner_dfu()), "0x08080000")

    def test_a_block_b_whose_header_doesnt_check_out_is_refused(self):
        bad = bytearray(good_block())
        bad[-1] ^= 1
        self.assertRefused(run("files", self.upper_dfu(bytes(bad)), self.owner_dfu()), "CRC")

    def test_an_owners_image_anywhere_but_0x08008000_is_refused(self):
        self.assertRefused(run("files", self.upper_dfu(), self.owner_dfu(address=0x08080000)), "0x08008000")


class UpperTests(DrawnFlashTests):
    """The read-only read of 0x08080000-0x080FFFFF, judged against B's file: the gate before step 1 and its read-back
    after."""

    def read(self, content):
        return self.path("wd-upper-read.bin", content)

    def test_all_erased_says_erased(self):
        code, out, _ = run("upper", self.upper_dfu(), self.read(b"\xff" * UPPER_SIZE))
        self.assertEqual((code, out.split()[0]), (0, "erased"))

    def test_exactly_this_block_then_erased_says_holds(self):
        block = good_block()
        code, out, _ = run("upper", self.upper_dfu(), self.read(block + b"\xff" * (UPPER_SIZE - len(block))))
        self.assertEqual((code, out.split()[0]), (0, "holds"))

    def test_this_block_with_a_byte_off_is_refused_with_its_address(self):
        read = bytearray(good_block() + b"\xff" * (UPPER_SIZE - len(good_block())))
        read[30] ^= 1
        self.assertRefused(run("upper", self.upper_dfu(), self.read(bytes(read))), "0x0808001E")

    def test_a_half_written_block_says_replace(self):
        # A write cut off part way: this B's first bytes, then erased flash. B is rewritten behind its own word.
        block = good_block()
        read = block[:20] + b"\xff" * (UPPER_SIZE - 20)
        code, out, _ = run("upper", self.upper_dfu(), self.read(read))
        self.assertEqual((code, out.split()[0]), (0, "replace"))

    def test_another_good_block_b_says_replace(self):
        # #501's first B: version 2, the 20-byte header, CRC 0x22B5DF72 from Python's zlib. Every layout change makes
        # a new B (#516), so an older one is replaced, not refused.
        old = bytes.fromhex("44465742" "02000000" "1d000000" "72dfb522" "15000808") + b"123456789"
        code, out, _ = run("upper", self.upper_dfu(), self.read(old + b"\xff" * (UPPER_SIZE - len(old))))
        self.assertEqual((code, out.split()[0]), (0, "replace"))

    def test_another_block_b_with_a_bad_CRC_is_refused(self):
        old = bytearray(bytes.fromhex("44465742" "02000000" "1d000000" "72dfb522" "15000808") + b"123456789")
        old[-1] ^= 1
        self.assertRefused(run("upper", self.upper_dfu(), self.read(bytes(old) + b"\xff" * (UPPER_SIZE - 29))),
                           "CRC")

    def test_another_block_b_with_bytes_after_it_is_refused(self):
        old = bytes.fromhex("44465742" "02000000" "1d000000" "72dfb522" "15000808") + b"123456789"
        read = bytearray(old + b"\xff" * (UPPER_SIZE - len(old)))
        read[0x50000] = 0
        self.assertRefused(run("upper", self.upper_dfu(), self.read(bytes(read))), "0x080D0000")

    def test_anything_else_there_is_refused(self):
        read = bytearray(b"\xff" * UPPER_SIZE)
        read[0x40000] = 0
        self.assertRefused(run("upper", self.upper_dfu(), self.read(bytes(read))), "0x080C0000")

    def test_bytes_after_this_block_that_arent_erased_are_refused(self):
        block = good_block()
        read = bytearray(block + b"\xff" * (UPPER_SIZE - len(block)))
        read[-1] = 0
        self.assertRefused(run("upper", self.upper_dfu(), self.read(bytes(read))), "0x080FFFFF")

    def test_a_read_that_isnt_the_whole_512k_is_refused(self):
        self.assertRefused(run("upper", self.upper_dfu(), self.read(b"\xff" * (UPPER_SIZE - 1))), "524288")


class RewriteTests(DrawnFlashTests):
    """The file step 1 writes over part of a B or an older one (#468). A DfuSe write erases only the sectors its element
    covers, so an older B reaching further would leave its tail: the rewrite carries erased bytes over all of it."""

    def rewrite(self, old):
        read = self.path("wd-upper-read.bin", old + b"\xff" * (UPPER_SIZE - len(old)))
        out = os.path.join(self.dir.name, "rewrite.dfu")
        return run("rewrite", self.upper_dfu(), read, out), out

    def element(self, path):
        import dfupatch
        image = dfupatch.parse(dfupatch.read(path))
        return image.address, image.element

    def test_over_a_longer_older_b_it_is_this_b_then_erased_to_the_old_ones_end(self):
        import struct
        upper_header = drawn_flash.build_upper_dfu.upper_header
        rest = bytes((i * 5 + 1) & 0xFF for i in range(0x30000 - 16))  # spans sectors 8 and 9
        old = upper_header.seal(struct.pack("<IIII", upper_header.MARKER, 2, 0, 0) + rest)  # a version-2 B
        (code, _, err), out = self.rewrite(old)
        self.assertEqual(code, 0, err)
        address, element = self.element(out)
        block = good_block()
        self.assertEqual(address, UPPER)
        self.assertEqual(len(element), 0x30000)
        self.assertEqual(element[:len(block)], block)
        self.assertEqual(set(element[len(block):]), {0xFF})

    def test_over_part_of_this_b_it_is_this_b(self):
        (code, _, err), out = self.rewrite(good_block()[:20])
        self.assertEqual(code, 0, err)
        self.assertEqual(self.element(out), (UPPER, good_block()))

    def test_with_nothing_to_rewrite_it_is_refused(self):
        for read in (b"", good_block()):
            with self.subTest(len(read)):
                (code, _, err), out = self.rewrite(read)
                self.assertEqual(code, 1)
                self.assertIn("nothing to rewrite", err)
                self.assertFalse(os.path.exists(out))


def option_bytes(rdp=0xAA, nwrp=0x0FFF, db1m=0, sprmod=0):
    """A 16-byte read of 0x1FFFC000 (RM0090's option bytes, bank 1): USER at +0, RDP at +1, and at +8 the half-word
    of nWRP (bits 0-11, a sector each, 1 = not write-protected), DB1M (bit 14) and SPRMOD (bit 15)."""
    half = nwrp | db1m << 14 | sprmod << 15
    return bytes([0xEC, rdp]) + b"\xff" * 6 + bytes([half & 0xFF, half >> 8]) + b"\xff" * 6


class OptionsTests(DrawnFlashTests):
    """The option bytes, read by the wizard before step 1 (#468): read protection off, sectors 8-11 writable, one
    bank. Anything else stops with a plain message."""

    def options(self, content):
        return run("options", self.path("wd-option-bytes.bin", content))

    def test_level_0_writable_upper_sectors_and_one_bank_pass(self):
        code, out, _ = self.options(option_bytes())
        self.assertEqual((code, out.split()[0]), (0, "ok"))

    def test_read_protection_on_is_refused(self):
        for rdp in (0xBB, 0xCC):
            with self.subTest(rdp=rdp):
                self.assertRefused(self.options(option_bytes(rdp=rdp)), "read protection")

    def test_a_write_protected_upper_sector_is_refused_by_number(self):
        self.assertRefused(self.options(option_bytes(nwrp=0x0FFF & ~(1 << 9))), "sector 9")

    def test_a_protected_lower_sector_doesnt_matter(self):
        code, _, err = self.options(option_bytes(nwrp=0x0FFF & ~(1 << 0)))
        self.assertEqual(code, 0, err)

    def test_dual_bank_is_refused(self):
        self.assertRefused(self.options(option_bytes(db1m=1)), "two banks")

    def test_pcrop_mode_is_refused(self):
        # SPRMOD 1 turns nWRP into read-out protection bits, so they no longer say what's writable.
        self.assertRefused(self.options(option_bytes(sprmod=1)), "SPRMOD")

    def test_a_read_that_isnt_16_bytes_is_refused(self):
        self.assertRefused(self.options(option_bytes()[:15]), "16")




class AppTests(DrawnFlashTests):
    """Before step 2 (#468): a read of the app area judged against the owner's image. When it's already there,
    exactly (a rewrite of block B alone), step 2 writes nothing: the app area's erase and write is the one risky write."""

    def read(self, content):
        return self.path("wd-app-read.bin", content)

    def test_the_owners_image_already_there_says_holds(self):
        code, out, _ = run("app", self.owner_dfu(), self.read(full_wd_element()))
        self.assertEqual((code, out.split()[0]), (0, "holds"))

    def test_another_image_says_differs_with_the_first_address(self):
        other = bytearray(full_wd_element())
        other[0x100] ^= 1
        code, out, _ = run("app", self.owner_dfu(), self.read(bytes(other)))
        self.assertEqual((code, out.split()[0]), (0, "differs"))
        self.assertIn("0x08008100", out)

    def test_a_read_of_the_wrong_size_is_refused(self):
        self.assertRefused(run("app", self.owner_dfu(), self.read(full_wd_element()[:-4])), "read")

    def test_block_bs_file_in_the_owners_place_is_refused(self):
        self.assertRefused(run("app", self.upper_dfu(), self.read(full_wd_element())), "0x08008000")

    def test_it_runs_as_the_wizard_runs_it(self):
        # python3 -I from another folder (#557), on a real decision.
        owner, read = self.owner_dfu(), self.read(full_wd_element())
        script = os.path.join(os.path.dirname(os.path.realpath(__file__)), "drawn_flash.py")
        with tempfile.TemporaryDirectory() as elsewhere:
            result = subprocess.run([sys.executable, "-I", script, "app", owner, read], cwd=elsewhere,
                                    capture_output=True, text=True)
        self.assertEqual((result.returncode, result.stdout.split()[:1]), (0, ["holds"]), result.stderr)


class NoProbeTests(DrawnFlashTests):
    """Flashing without an ST-Link (#468, the owner's decision): the wizard never asks the owner to confirm a probe
    they don't have. Without one it says the risk in plain words and goes on only on a typed phrase."""

    def test_the_risk_is_said_in_plain_words(self):
        code, out, _ = run("no-probe-risk")
        self.assertEqual(code, 0)
        for words in ("update-mode message", "stays dark until a probe", "top panel", "only after our own first message",
                      "NO PROBE"):
            self.assertIn(words, out)

    def test_only_the_whole_phrase_goes_on(self):
        self.assertEqual(run("no-probe", "NO PROBE")[0], 0)
        self.assertEqual(run("no-probe", "  NO PROBE  ")[0], 0)   # stray spaces around it
        for typed in ("", "y", "yes", "FLASH", "no probe", "NO", "NOPROBE", "NO PROBE!"):
            with self.subTest(typed=typed):
                self.assertRefused(run("no-probe", typed), "NO PROBE")


if __name__ == "__main__":
    unittest.main()
