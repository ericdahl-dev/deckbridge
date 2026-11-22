"""Tests for build_owner_image.py (#467): the drawn-display image for the owner's unit, built from a synthetic stock
image and a synthetic block. No vendor data.
Run from the repo root: python3 -I -m unittest discover tools/lc6000-firmware"""
import contextlib, io, json, os, struct, tempfile, unittest

import build_owner_image
import build_record
import dfupatch
from test_dfupatch import BASE, PAD_END, PAD_START, changed_offsets, dfuse_file, full_wd_element

MARKER = struct.pack("<I", 0x31574644)
HOOK_SITES = {0x0800F464: "4ff00108", 0x08012456: "f9f723fd"}
VOS_SITE, VOS_OLD = 0x0800A69E, "40f40040"


def stock_like_element():
    """A full-size synthetic wd image holding the old bytes the hook and VOS patches expect, nothing else of Denon's."""
    element = bytearray(full_wd_element())
    for at, old in {**HOOK_SITES, VOS_SITE: VOS_OLD}.items():
        element[at - BASE:at - BASE + 4] = bytes.fromhex(old)
    covered = len(element) - 20
    struct.pack_into("<I", element, covered, dfupatch.stm32_crc(bytes(element[:covered])))
    return bytes(element)


def synthetic_block(marker=True):
    body = bytearray(b"\x5a" * 200 + b"\xff" * (PAD_END - PAD_START - 200))
    body[-4:] = MARKER if marker else b"\xff\xff\xff\xff"
    return bytes(body)


def run(*argv):
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        code = build_owner_image.main(list(argv))
    return code, out.getvalue(), err.getvalue()


class BuildOwnerImageTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.data = dfuse_file(stock_like_element())
        cls.start = len(cls.data) - 16 - (PAD_END - BASE + 32)

    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)

    def path(self, name, content=None):
        path = os.path.join(self.dir.name, name)
        if content is not None:
            with open(path, "wb") as f:
                f.write(content)
        return path

    def build(self, *extra, block=None):
        stock = self.path("stock.dfu", self.data)
        blob = self.path("block.bin", block if block is not None else synthetic_block())
        output = self.path("owner.dfu")
        code, out, err = run(stock, blob, output, *extra)
        return code, out, err, output

    def build_plain(self, *extra, block=None):
        """A build with slot 16 explicitly off, the choice every build must now make."""
        return self.build("--no-show-slot-16", *extra, block=block)

    def element(self, path):
        with open(path, "rb") as f:
            return f.read()

    def test_slot_16_has_no_default_so_a_build_without_the_choice_is_refused(self):
        # the owner's unit runs the slot 16 patch now (#425); a silent default would take slot 16 away on deck 4
        code, _, err, output = self.build()
        self.assertEqual(code, 1)
        self.assertIn("slot 16", err)
        self.assertFalse(os.path.exists(output))

    def test_it_changes_only_the_hook_the_block_and_the_two_crcs(self):
        code, out, err, output = self.build_plain()
        self.assertEqual(code, 0, err)
        result = self.element(output)
        allowed = set(range(self.start + PAD_START - BASE, self.start + PAD_END - BASE))
        for at in HOOK_SITES:
            allowed |= set(range(self.start + at - BASE, self.start + at - BASE + 4))
        covered = self.start + PAD_END - BASE + 32 - 20
        allowed |= set(range(covered, covered + 4)) | set(range(len(result) - 4, len(result)))
        self.assertTrue(set(changed_offsets(self.data, result)) <= allowed)
        image = dfupatch.parse(result)
        self.assertEqual(image.element[PAD_END - BASE - 4:PAD_END - BASE], MARKER)
        self.assertEqual(image.element[0x0800F464 - BASE:0x0800F468 - BASE], bytes.fromhex("6ef0ccfb"))
        self.assertEqual(dfupatch.patch(result, ""), result)  # both CRCs check out

    def test_the_voltage_fix_is_off_by_default_and_on_when_asked(self):
        _, _, _, plain = self.build_plain()
        vos = VOS_SITE - BASE
        self.assertEqual(dfupatch.parse(self.element(plain)).element[vos:vos + 4], bytes.fromhex(VOS_OLD))
        os.remove(plain)
        code, out, err, fixed = self.build_plain("--vos-scale-1")
        self.assertEqual(code, 0, err)
        self.assertEqual(dfupatch.parse(self.element(fixed)).element[vos:vos + 4], bytes.fromhex("40f44040"))
        self.assertIn("VOS", out)

    def test_slot_16_is_kept_when_asked_so_the_first_drawn_flash_changes_one_thing(self):
        # the owner's unit already runs the slot 16 patch (#425): keeping it means only the hook and block are new
        element = bytearray(stock_like_element())
        element[0x0800BDA4 - BASE:0x0800BDA6 - BASE] = bytes.fromhex("0f28")
        covered = len(element) - 20
        struct.pack_into("<I", element, covered, dfupatch.stm32_crc(bytes(element[:covered])))
        stock = self.path("stock16.dfu", dfuse_file(bytes(element)))
        output = self.path("owner16.dfu")
        code, out, err = run(stock, self.path("block.bin", synthetic_block()), output, "--show-slot-16")
        self.assertEqual(code, 0, err)
        self.assertEqual(dfupatch.parse(self.element(output)).element[0x0800BDA4 - BASE], 0x10)
        self.assertIn("slot 16", out)

    def test_a_block_without_our_marker_last_is_refused(self):
        # the hook calls into the block, so the hook never goes out without a whole block behind it
        code, _, err, output = self.build_plain(block=synthetic_block(marker=False))
        self.assertEqual(code, 1)
        self.assertIn("marker", err)
        self.assertFalse(os.path.exists(output))

    def test_a_block_that_isnt_the_whole_padding_is_refused(self):
        code, _, err, output = self.build_plain(block=synthetic_block()[:-8] + MARKER)
        self.assertEqual(code, 1)
        self.assertIn("9184", err)

    def test_it_wont_write_inside_the_repository(self):
        stock = self.path("stock.dfu", self.data)
        blob = self.path("block.bin", synthetic_block())
        inside = os.path.join(dfupatch.repository_root(), "owner-test.dfu")
        code, _, err = run(stock, blob, inside, "--no-show-slot-16")
        self.assertEqual(code, 1)
        self.assertIn("outside the repository", err)
        self.assertFalse(os.path.exists(inside))


    def test_the_build_record_beside_the_block_travels_with_the_image(self):
        # make arm writes build.json beside block.bin; the wizard finds it beside the owner's image (#593).
        from test_build_upper_dfu import good_block
        record = build_record.record_of(synthetic_block(), good_block(), "1", "1")
        with open(self.path("build.json"), "w") as f:
            json.dump(record, f)
        code, out, err, output = self.build_plain()
        self.assertEqual(code, 0, err)
        with open(self.path("owner.build.json")) as f:
            self.assertEqual(json.load(f), record)
        self.assertIn("owner.build.json", out)

    def test_a_record_for_another_a_or_none_doesnt_travel(self):
        from test_build_upper_dfu import good_block
        other = build_record.record_of(synthetic_block(marker=False), good_block(), "1", "1")
        for record in (other, None):
            with self.subTest(record=record is not None):
                self.setUp()
                if record:
                    with open(self.path("build.json"), "w") as f:
                        json.dump(record, f)
                code, out, err, output = self.build_plain()
                self.assertEqual(code, 0, err)
                self.assertTrue(os.path.exists(output))
                self.assertFalse(os.path.exists(self.path("owner.build.json")))
                self.assertIn("no build record", out)


if __name__ == "__main__":
    unittest.main()
