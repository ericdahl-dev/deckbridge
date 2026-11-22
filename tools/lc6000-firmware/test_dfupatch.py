"""Tests for dfupatch.py. They build synthetic DfuSe files, so they need no vendor data.
Run from the repo root: python3 -I -m unittest discover tools/lc6000-firmware"""
import contextlib, io, os, shutil, struct, subprocess, tempfile, unittest, zlib

import dfupatch

BASE = 0x08008000


def dfuse_file(element, address=BASE, *, targets=1, elements=1, vid=0x0483, pid=0xDF11):
    """A DfuSe file built straight from the UM0391 layout, independent of dfupatch."""
    body = struct.pack("<II", address, len(element)) + element
    target = b"Target" + struct.pack("<BI255sII", 0, 0, b"", len(body), elements) + body
    image_size = 11 + len(target) * targets + 16  # the whole file, suffix included, as in ST's own tool
    prefix = b"DfuSe" + struct.pack("<BIB", 1, image_size, targets)
    data = prefix + target * targets
    data += struct.pack("<HHHH", 0x0000, pid, vid, 0x011A) + b"UFD" + bytes([16])
    return data + struct.pack("<I", zlib.crc32(data) ^ 0xFFFFFFFF)


class ParseTests(unittest.TestCase):
    def test_the_image_size_field_counts_the_whole_file_with_its_suffix(self):
        data = bytearray(dfuse_file(bytes(32)))
        struct.pack_into("<I", data, 6, len(data) - 16)
        struct.pack_into("<I", data, len(data) - 4, zlib.crc32(data[:-4]) ^ 0xFFFFFFFF)
        with self.assertRaisesRegex(dfupatch.Refused, "image size"):
            dfupatch.parse(bytes(data))

    def test_it_reads_the_one_element_address_and_bytes(self):
        image = dfupatch.parse(dfuse_file(b"\x01\x02\x03\x04" * 8, address=0x08008000))
        self.assertEqual(image.address, 0x08008000)
        self.assertEqual(image.element, b"\x01\x02\x03\x04" * 8)

    def test_a_wrong_suffix_crc_is_refused(self):
        data = bytearray(dfuse_file(bytes(32)))
        data[-1] ^= 0xFF
        with self.assertRaisesRegex(dfupatch.Refused, "suffix CRC"):
            dfupatch.parse(bytes(data))

    def test_a_file_that_is_not_dfuse_is_refused(self):
        with self.assertRaisesRegex(dfupatch.Refused, "DfuSe"):
            dfupatch.parse(b"\x00" * 64)

    def test_more_than_one_target_or_element_is_refused(self):
        # the stock updater reads the element at a fixed offset (0x11D), so anything else would flash wrongly
        with self.assertRaisesRegex(dfupatch.Refused, "target"):
            dfupatch.parse(dfuse_file(bytes(32), targets=2))
        with self.assertRaisesRegex(dfupatch.Refused, "element"):
            dfupatch.parse(dfuse_file(bytes(32), elements=2))

    def test_a_truncated_file_is_refused(self):
        data = dfuse_file(bytes(64))
        cut = data[:200] + data[-16:-4]
        cut += struct.pack("<I", zlib.crc32(cut) ^ 0xFFFFFFFF)
        with self.assertRaises(dfupatch.Refused):
            dfupatch.parse(cut)


def wd_element(size=0x400, fill=b"\x5a\xa5\x0f\xf0"):
    """A wd-style image: code, then the 32-byte trailer (version, 0xDEADBEEF, length, CRC, EndOfFlashToken)."""
    body = bytearray((fill * (size // len(fill)))[:size])
    covered = size - 20
    struct.pack_into("<4sII", body, size - 32, b"\x00\x00\x05\x00", 0xDEADBEEF, covered)
    struct.pack_into("<I", body, covered, dfupatch.stm32_crc(bytes(body[:covered])))
    body[size - 16:] = b"EndOfFlashToken\x00"
    return bytes(body)


def tp_element(size=0x400):
    """A tp-style image: its trailer has no magic and no length, just an undecoded field (an invented value here)."""
    body = bytearray(b"\xff" * size)
    struct.pack_into("<4sIII", body, size - 32, b"\x00\x00\x03\x01", 0x00C0FFEE, 0, 0)
    body[size - 16:] = b"EndOfFlashToken\x00"
    return bytes(body)


class Stm32CrcTests(unittest.TestCase):
    def test_it_matches_the_crc_units_bit_by_bit_definition_on_many_words_and_when_chained(self):
        # The definition, one bit at a time, as the reference for the fast version (#567).
        def by_bits(data, crc=0xFFFFFFFF):
            for (word,) in struct.iter_unpack("<I", data):
                crc ^= word
                for _ in range(32):
                    crc = ((crc << 1) ^ 0x04C11DB7) & 0xFFFFFFFF if crc & 0x80000000 else (crc << 1) & 0xFFFFFFFF
            return crc
        import random
        data = random.Random(567).randbytes(4096)
        self.assertEqual(dfupatch.stm32_crc(data), by_bits(data))
        self.assertEqual(dfupatch.stm32_crc(data[2048:], dfupatch.stm32_crc(data[:2048])), by_bits(data))
        self.assertEqual(dfupatch.stm32_crc(data, 0x1234ABCD), by_bits(data, 0x1234ABCD))

    def test_it_matches_the_stm32_crc_unit_on_a_known_word(self):
        # ST's CRC unit fed the one word 0x12345678 from reset reads back 0xDF8A8A2B
        self.assertEqual(dfupatch.stm32_crc(struct.pack("<I", 0x12345678)), 0xDF8A8A2B)

    def test_no_words_leave_the_reset_value(self):
        self.assertEqual(dfupatch.stm32_crc(b""), 0xFFFFFFFF)


class TrailerTests(unittest.TestCase):
    def test_a_no_op_patch_gives_back_the_input_bit_for_bit(self):
        data = dfuse_file(wd_element())
        self.assertEqual(dfupatch.patch(data, ""), data)

    def test_a_tp_no_op_patch_gives_back_the_input_bit_for_bit(self):
        # The tp startup stage only checks that the image ends with EndOfFlashToken (read from the unit's sector 0,
        # #434): there's no checksum to fix, so a tp image is patchable as long as its trailer stays as it is.
        data = dfuse_file(tp_element())
        self.assertEqual(dfupatch.patch(data, ""), data)

    def test_a_tp_patch_changes_only_its_byte_and_the_suffix_crc(self):
        element = tp_element()
        data = dfuse_file(element)
        start = len(data) - 16 - len(element)
        out = dfupatch.patch(data, f"0x{BASE + 0x40:08X} ff 00\n")
        self.assertEqual(set(changed_offsets(data, out)) - set(range(len(out) - 4, len(out))), {start + 0x40})
        self.assertEqual(out[start + len(element) - 32:start + len(element)], element[-32:])

    def test_a_tp_patch_that_touches_the_trailer_is_refused(self):
        element = tp_element()
        with self.assertRaisesRegex(dfupatch.Refused, "trailer"):
            dfupatch.patch(dfuse_file(element), f"0x{BASE + len(element) - 28:08X} ee 00\n")

    def test_an_image_without_the_end_token_is_refused(self):
        element = bytearray(tp_element())
        element[-1] = 0x01
        with self.assertRaisesRegex(dfupatch.Refused, "EndOfFlashToken"):
            dfupatch.patch(dfuse_file(bytes(element)), "")

    def test_the_chip_is_told_from_the_trailer(self):
        self.assertEqual(dfupatch.chip(wd_element()), "wd")
        self.assertEqual(dfupatch.chip(tp_element()), "tp")

    def test_a_stale_trailer_crc_on_the_input_is_refused(self):
        element = bytearray(wd_element())
        element[0x10] ^= 0x01
        with self.assertRaisesRegex(dfupatch.Refused, "CRC"):
            dfupatch.patch(dfuse_file(bytes(element)), "")

    def test_a_length_field_that_isnt_the_element_size_less_20_is_refused(self):
        element = bytearray(wd_element())
        struct.pack_into("<I", element, len(element) - 24, len(element) - 24)
        with self.assertRaises(dfupatch.Refused):
            dfupatch.patch(dfuse_file(bytes(element)), "")


def changed_offsets(a, b):
    return [i for i in range(len(a)) if a[i] != b[i]]


class PatchTests(unittest.TestCase):
    def setUp(self):
        self.element = wd_element()
        self.data = dfuse_file(self.element)
        self.element_start = len(self.data) - 16 - len(self.element)

    def test_a_one_byte_patch_changes_only_that_byte_the_trailer_crc_and_the_suffix_crc(self):
        old = self.element[0x40]
        out = dfupatch.patch(self.data, f"# one byte\n0x{BASE + 0x40:08X} {old:02x} {old ^ 0xFF:02x}\n")
        self.assertEqual(len(out), len(self.data))
        crc_at = self.element_start + len(self.element) - 20
        allowed = {self.element_start + 0x40, *range(crc_at, crc_at + 4), *range(len(out) - 4, len(out))}
        self.assertTrue(set(changed_offsets(self.data, out)) <= allowed)
        self.assertIn(self.element_start + 0x40, changed_offsets(self.data, out))
        self.assertEqual(dfupatch.patch(out, ""), out)  # its trailer and suffix now check out

    def test_old_bytes_that_dont_match_are_refused(self):
        wrong = self.element[0x40] ^ 0x01
        with self.assertRaisesRegex(dfupatch.Refused, "old bytes"):
            dfupatch.patch(self.data, f"0x{BASE + 0x40:08X} {wrong:02x} 00")

    def test_a_patch_that_touches_the_trailer_is_refused(self):
        at = len(self.element) - 32
        old = self.element[at:at + 4].hex()
        with self.assertRaisesRegex(dfupatch.Refused, "trailer"):
            dfupatch.patch(self.data, f"0x{BASE + at:08X} {old} 00000000")
        at = len(self.element) - 40
        old = self.element[at:at + 12].hex()
        with self.assertRaisesRegex(dfupatch.Refused, "trailer"):
            dfupatch.patch(self.data, f"0x{BASE + at:08X} {old} {'00' * 12}")

    def test_a_patch_outside_the_image_is_refused(self):
        with self.assertRaisesRegex(dfupatch.Refused, "outside"):
            dfupatch.patch(self.data, f"0x{BASE - 4:08X} 00 00")

    def test_old_and_new_bytes_of_different_lengths_are_refused(self):
        old = self.element[0x40:0x42].hex()
        with self.assertRaisesRegex(dfupatch.Refused, "length"):
            dfupatch.patch(self.data, f"0x{BASE + 0x40:08X} {old} 00")

    def test_overlapping_patch_lines_are_refused(self):
        a, b = self.element[0x40:0x42].hex(), self.element[0x41:0x43].hex()
        with self.assertRaisesRegex(dfupatch.Refused, "overlap"):
            dfupatch.patch(self.data, f"0x{BASE + 0x40:08X} {a} 0000\n0x{BASE + 0x41:08X} {b} 0000")

    def test_a_malformed_line_is_refused_with_its_line_number(self):
        with self.assertRaisesRegex(dfupatch.Refused, "line 2"):
            dfupatch.patch(self.data, "# fine\nnot a patch line")


# The wd 00.50 layout: the image fills 0x08008000-0x0807FFFF; its own padding, 0xFF inside the CRC, runs from
# 0x0807DC00 to the trailer (#466).
WD_SIZE = 0x78000
PAD_START, PAD_END = 0x0807DC00, 0x0807FFE0


def full_wd_element():
    """A synthetic full-size wd image: invented code bytes, 0xFF padding where the real image has it, the trailer."""
    body = bytearray(wd_element(WD_SIZE))
    body[PAD_START - BASE:PAD_END - BASE] = b"\xff" * (PAD_END - PAD_START)
    covered = WD_SIZE - 20
    struct.pack_into("<I", body, covered, dfupatch.stm32_crc(bytes(body[:covered])))
    return bytes(body)


class PlaceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.element = full_wd_element()
        cls.data = dfuse_file(cls.element)
        cls.element_start = len(cls.data) - 16 - len(cls.element)

    def test_a_block_lands_at_the_start_of_the_padding_and_the_crcs_are_redone(self):
        block = bytes(range(1, 101))
        out = dfupatch.place(self.data, block)
        image = dfupatch.parse(out)
        at = PAD_START - BASE
        self.assertEqual(image.element[at:at + len(block)], block)
        crc_at = self.element_start + WD_SIZE - 20
        allowed = {*range(self.element_start + at, self.element_start + at + len(block)),
                   *range(crc_at, crc_at + 4), *range(len(out) - 4, len(out))}
        self.assertTrue(set(changed_offsets(self.data, out)) <= allowed)
        self.assertEqual(dfupatch.patch(out, ""), out)  # trailer CRC and suffix CRC both check out

    def test_a_block_that_fills_the_padding_exactly_fits(self):
        out = dfupatch.place(self.data, b"\x11" * (PAD_END - PAD_START))
        self.assertEqual(dfupatch.parse(out).element[PAD_END - BASE - 1], 0x11)

    def test_a_block_one_byte_too_big_is_refused(self):
        with self.assertRaisesRegex(dfupatch.Refused, "too big"):
            dfupatch.place(self.data, b"\x11" * (PAD_END - PAD_START + 1))

    def test_an_empty_block_is_refused(self):
        with self.assertRaisesRegex(dfupatch.Refused, "empty"):
            dfupatch.place(self.data, b"")

    def test_padding_that_isnt_all_ff_is_refused(self):
        element = bytearray(self.element)
        element[PAD_START - BASE + 50] = 0x00
        covered = WD_SIZE - 20
        struct.pack_into("<I", element, covered, dfupatch.stm32_crc(bytes(element[:covered])))
        with self.assertRaisesRegex(dfupatch.Refused, "0xFF"):
            dfupatch.place(dfuse_file(bytes(element)), b"\x11" * 100)

    def test_an_image_without_the_padding_range_is_refused(self):
        with self.assertRaisesRegex(dfupatch.Refused, "0x0807DC00"):
            dfupatch.place(dfuse_file(wd_element()), b"\x11" * 4)

    def test_a_tp_image_is_refused(self):
        with self.assertRaisesRegex(dfupatch.Refused, "wd"):
            dfupatch.place(dfuse_file(tp_element(WD_SIZE)), b"\x11" * 4)


def run(*argv):
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        code = dfupatch.main(list(argv))
    return code, out.getvalue(), err.getvalue()


class CommandLineTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.element = wd_element()
        self.input = self.path("in.dfu", dfuse_file(self.element))

    def path(self, name, content=None):
        path = os.path.join(self.dir.name, name)
        if content is not None:
            with open(path, "wb" if isinstance(content, bytes) else "w") as f:
                f.write(content)
        return path

    def test_verify_passes_a_good_wd_file(self):
        code, out, _ = run("verify", self.input)
        self.assertEqual(code, 0)
        self.assertIn("bit for bit", out)

    def test_verify_passes_a_tp_file_and_says_it_has_no_checksum(self):
        code, out, _ = run("verify", self.path("tp.dfu", dfuse_file(tp_element())))
        self.assertEqual(code, 0)
        self.assertIn("tp image", out)
        self.assertIn("no checksum", out)

    def test_apply_on_a_tp_file_says_no_trailer_crc_was_needed(self):
        patch = self.path("p.txt", f"0x{BASE + 0x40:08X} ff 00\n")
        output = self.path("tp-out.dfu")
        code, out, _ = run("apply", self.path("tp.dfu", dfuse_file(tp_element())), patch, output)
        self.assertEqual(code, 0)
        self.assertIn("tp image", out)

    def test_compare_passes_a_readback_equal_to_the_files_image(self):
        code, out, _ = run("compare", self.input, self.path("readback.bin", self.element))
        self.assertEqual(code, 0)
        self.assertIn(f"match: {len(self.element):#x} bytes at 0x{BASE:08X}", out)

    def test_compare_refuses_a_readback_with_one_byte_changed_and_says_where(self):
        changed = bytearray(self.element)
        changed[0x123] ^= 0x01
        code, _, err = run("compare", self.input, self.path("readback.bin", bytes(changed)))
        self.assertEqual(code, 1)
        self.assertIn(f"1 byte differs, the first at 0x{BASE + 0x123:08X}", err)

    def test_compare_refuses_a_readback_of_another_length(self):
        code, _, err = run("compare", self.input, self.path("readback.bin", self.element[:-4]))
        self.assertEqual(code, 1)
        self.assertIn("bytes, the image is", err)

    def test_apply_writes_the_patched_file(self):
        old = self.element[0x40]
        patch = self.path("p.txt", f"0x{BASE + 0x40:08X} {old:02x} {old ^ 0xFF:02x}\n")
        output = self.path("out.dfu")
        code, out, _ = run("apply", self.input, patch, output)
        self.assertEqual(code, 0)
        with open(output, "rb") as f:
            self.assertEqual(dfupatch.parse(f.read()).element[0x40], old ^ 0xFF)
        self.assertIn("trailer CRC", out)

    def test_apply_writes_nothing_when_refused(self):
        patch = self.path("p.txt", f"0x{BASE + 0x40:08X} {self.element[0x40] ^ 1:02x} 00\n")
        output = self.path("out.dfu")
        code, _, err = run("apply", self.input, patch, output)
        self.assertEqual(code, 1)
        self.assertIn("old bytes", err)
        self.assertFalse(os.path.exists(output))

    def test_apply_refuses_a_call_into_empty_padding_and_writes_nothing(self):
        # A BL into the 0xFF padding with no block there faults on the chip with a valid CRC: no USB way back (#467).
        element = bytearray(full_wd_element())
        covered = len(element) - 20
        struct.pack_into("<I", element, covered, dfupatch.stm32_crc(bytes(element[:covered])))
        stock = self.path("padded.dfu", dfuse_file(bytes(element)))
        at = BASE + 0x40
        old = bytes(element[0x40:0x44]).hex()
        patch = self.path("p.txt", f"0x{at:08X} {old} {dfupatch.thumb_bl(at, PAD_START).hex()}\n")
        output = self.path("out.dfu")
        code, _, err = run("apply", stock, patch, output)
        self.assertEqual(code, 1)
        self.assertIn("empty padding", err)
        self.assertFalse(os.path.exists(output))

    def test_place_writes_the_file_and_refuses_inside_the_repository(self):
        data = dfuse_file(full_wd_element())
        source = self.path("full.dfu", data)
        block = self.path("block.bin", b"\x42" * 64)
        output = self.path("placed.dfu")
        code, out, _ = run("place", source, block, output)
        self.assertEqual(code, 0, out)
        self.assertIn("0x0807DC00", out)
        with open(output, "rb") as f:
            self.assertEqual(dfupatch.parse(f.read()).element[PAD_START - BASE], 0x42)
        inside = os.path.join(dfupatch.repository_root(), "placed-test.dfu")
        code, _, err = run("place", source, block, inside)
        self.assertEqual(code, 1)
        self.assertIn("outside the repository", err)
        self.assertFalse(os.path.exists(inside))

    def test_apply_wont_overwrite_a_file(self):
        patch = self.path("p.txt", "")
        output = self.path("out.dfu", b"keep")
        code, _, err = run("apply", self.input, patch, output)
        self.assertEqual(code, 1)
        with open(output, "rb") as f:
            self.assertEqual(f.read(), b"keep")

    def test_apply_wont_write_inside_the_repository(self):
        # patched images are never committed: the output has to land outside the repo
        output = os.path.join(os.path.dirname(os.path.abspath(dfupatch.__file__)), "patched-test-output.dfu")
        code, _, err = run("apply", self.input, self.path("p.txt", ""), output)
        self.assertEqual(code, 1)
        self.assertIn("outside the repository", err)
        self.assertFalse(os.path.exists(output))


class ThumbBlTests(unittest.TestCase):
    """The Thumb-2 BL encoder, against encodings read from the stock image and checked by disassembly (#466)."""

    def test_forward_calls_from_the_hook_sites_to_the_padding(self):
        self.assertEqual(dfupatch.thumb_bl(0x0800F464, 0x0807DC00), bytes.fromhex("6ef0ccfb"))
        self.assertEqual(dfupatch.thumb_bl(0x08012456, 0x0807DC40), bytes.fromhex("6bf0f3fb"))
        self.assertEqual(dfupatch.thumb_bl(0x08017720, 0x0807DC80), bytes.fromhex("66f0aefa"))

    def test_backward_calls_as_the_stock_image_encodes_them(self):
        self.assertEqual(dfupatch.thumb_bl(0x08012456, 0x0800BEA0), bytes.fromhex("f9f723fd"))
        self.assertEqual(dfupatch.thumb_bl(0x0801244C, 0x0800F200), bytes.fromhex("fcf7d8fe"))
        self.assertEqual(dfupatch.thumb_bl(0x0800F45A, 0x08014644), bytes.fromhex("05f0f3f8"))

    def test_odd_addresses_and_targets_out_of_reach_are_refused(self):
        with self.assertRaisesRegex(dfupatch.Refused, "even"):
            dfupatch.thumb_bl(0x0800F465, 0x0807DC00)
        with self.assertRaisesRegex(dfupatch.Refused, "even"):
            dfupatch.thumb_bl(0x0800F464, 0x0807DC01)
        with self.assertRaisesRegex(dfupatch.Refused, "reach"):
            dfupatch.thumb_bl(0x08000000, 0x09000004)


class CommittedPatchTests(unittest.TestCase):
    """The patch descriptions in patches/ are data the user flashes from, so their shape is pinned here."""

    def patch_text(self, name):
        here = os.path.dirname(os.path.abspath(__file__))
        with open(os.path.join(here, "patches", name)) as f:
            return f.read()

    def test_show_slot_16_is_one_edit_that_raises_the_show_bound_from_15_to_16(self):
        # wd 00.50, 0x0800BDA4: `cmp r0, #0xf` (0f 28) becomes `cmp r0, #0x10` (10 28). See #425.
        edits = dfupatch.parse_patch(self.patch_text("wd-00.50-show-slot-16.patch"))
        self.assertEqual(edits, [(0x0800BDA4, bytes.fromhex("0f28"), bytes.fromhex("1028"))])

    def test_show_slot_16_changes_one_byte_and_the_two_crcs_of_an_image_that_has_the_old_bytes(self):
        element = bytearray(wd_element(size=0x4000))
        element[0x3DA4:0x3DA6] = bytes.fromhex("0f28")
        covered = len(element) - 20
        struct.pack_into("<I", element, covered, dfupatch.stm32_crc(bytes(element[:covered])))
        data = dfuse_file(bytes(element))
        start = len(data) - 16 - len(element)
        out = dfupatch.patch(data, self.patch_text("wd-00.50-show-slot-16.patch"))
        crcs = {*range(start + covered, start + covered + 4), *range(len(out) - 4, len(out))}
        changed = set(changed_offsets(data, out))
        self.assertEqual(changed - crcs, {start + 0x3DA4})
        self.assertEqual(out[start + 0x3DA4], 0x10)

    def test_drawn_hook_calls_our_two_entries_from_the_two_hook_sites(self):
        # 0x0800F464 `mov.w r8, #1` (the unknown-command fallthrough) and 0x08012456 `bl 0x0800BEA0` (the render
        # step) each become a BL into our block's fixed entries at the start of the padding. See #466.
        edits = dfupatch.parse_patch(self.patch_text("wd-00.50-drawn-hook.patch"))
        self.assertEqual(edits, [
            (0x0800F464, bytes.fromhex("4ff00108"), dfupatch.thumb_bl(0x0800F464, dfupatch.HOOK_COMMAND_ENTRY)),
            (0x08012456, bytes.fromhex("f9f723fd"), dfupatch.thumb_bl(0x08012456, dfupatch.HOOK_RENDER_ENTRY)),
        ])
        self.assertTrue(PAD_START <= dfupatch.HOOK_COMMAND_ENTRY < dfupatch.HOOK_RENDER_ENTRY < PAD_END)

    def test_drawn_hook_changes_only_its_8_bytes_and_the_two_crcs(self):
        element = bytearray(full_wd_element())
        element[0x0800F464 - BASE:0x0800F468 - BASE] = bytes.fromhex("4ff00108")
        element[0x08012456 - BASE:0x0801245A - BASE] = bytes.fromhex("f9f723fd")
        covered = len(element) - 20
        struct.pack_into("<I", element, covered, dfupatch.stm32_crc(bytes(element[:covered])))
        data = dfuse_file(bytes(element))
        start = len(data) - 16 - len(element)
        out = dfupatch.patch(data, self.patch_text("wd-00.50-drawn-hook.patch"))
        crcs = {*range(start + covered, start + covered + 4), *range(len(out) - 4, len(out))}
        hook = {*range(start + 0xF464 - 0x8000, start + 0xF468 - 0x8000),
                *range(start + 0x12456 - 0x8000, start + 0x1245A - 0x8000)}
        self.assertTrue(set(changed_offsets(data, out)) - crcs <= hook)  # f0 stays f0 at 0x0800F465
        self.assertEqual(out[start + 0xF464 - 0x8000:start + 0xF468 - 0x8000], bytes.fromhex("6ef0ccfb"))
        self.assertEqual(out[start + 0x12456 - 0x8000:start + 0x1245A - 0x8000], bytes.fromhex("6bf0f3fb"))

    def test_drawn_hook_is_refused_on_an_image_without_the_old_bytes(self):
        with self.assertRaisesRegex(dfupatch.Refused, "old bytes"):
            dfupatch.patch(dfuse_file(full_wd_element()), self.patch_text("wd-00.50-drawn-hook.patch"))

    def test_show_slot_16_is_refused_on_an_image_without_the_old_bytes(self):
        with self.assertRaisesRegex(dfupatch.Refused, "old bytes"):
            dfupatch.patch(dfuse_file(wd_element(size=0x4000)), self.patch_text("wd-00.50-show-slot-16.patch"))

    def test_vos_scale_1_is_one_edit_that_sets_both_vos_bits(self):
        # wd 00.50, 0x0800A69E: `orr r0, r0, #0x8000` (40 f4 00 40) becomes `orr r0, r0, #0xc000` (40 f4 40 40). See #438.
        edits = dfupatch.parse_patch(self.patch_text("wd-00.50-vos-scale-1.patch"))
        self.assertEqual(edits, [(0x0800A69E, bytes.fromhex("40f40040"), bytes.fromhex("40f44040"))])

    def test_vos_scale_1_changes_one_byte_and_the_two_crcs_of_an_image_that_has_the_old_bytes(self):
        element = bytearray(wd_element(size=0x4000))
        element[0x269E:0x26A2] = bytes.fromhex("40f40040")
        covered = len(element) - 20
        struct.pack_into("<I", element, covered, dfupatch.stm32_crc(bytes(element[:covered])))
        data = dfuse_file(bytes(element))
        start = len(data) - 16 - len(element)
        out = dfupatch.patch(data, self.patch_text("wd-00.50-vos-scale-1.patch"))
        crcs = {*range(start + covered, start + covered + 4), *range(len(out) - 4, len(out))}
        changed = set(changed_offsets(data, out))
        self.assertEqual(changed - crcs, {start + 0x26A0})
        self.assertEqual(out[start + 0x26A0], 0x40)

    def test_vos_scale_1_is_refused_on_an_image_without_the_old_bytes(self):
        with self.assertRaisesRegex(dfupatch.Refused, "old bytes"):
            dfupatch.patch(dfuse_file(wd_element(size=0x4000)), self.patch_text("wd-00.50-vos-scale-1.patch"))

    def test_no_deck_select_is_one_edit_that_starts_the_deck_byte_at_deck_1(self):
        # tp 00.31, 0x08015CDB: one token of the compressed start-up data (control 0a, count 14, the literal, offset
        # 64). The literal is the first value of the deck byte at 0x20000703: ff (no deck) becomes 00 (deck 1). #439.
        edits = dfupatch.parse_patch(self.patch_text("tp-00.31-no-deck-select-on-hello.patch"))
        self.assertEqual(edits, [(0x08015CDB, bytes.fromhex("0a14ff64"), bytes.fromhex("0a140064"))])

    def test_no_deck_select_changes_one_byte_and_the_suffix_crc_of_a_tp_image_that_has_the_old_bytes(self):
        element = bytearray(tp_element(size=0x10000))
        element[0xDCDB:0xDCDF] = bytes.fromhex("0a14ff64")
        data = dfuse_file(bytes(element))
        start = len(data) - 16 - len(element)
        out = dfupatch.patch(data, self.patch_text("tp-00.31-no-deck-select-on-hello.patch"))
        changed = set(changed_offsets(data, out))
        self.assertEqual(changed - set(range(len(out) - 4, len(out))), {start + 0xDCDD})
        self.assertEqual(out[start + 0xDCDD], 0x00)
        self.assertEqual(out[start + len(element) - 32:start + len(element)], bytes(element[-32:]))

    def test_no_deck_select_is_refused_on_an_image_without_the_old_bytes(self):
        with self.assertRaisesRegex(dfupatch.Refused, "old bytes"):
            dfupatch.patch(dfuse_file(tp_element(size=0x10000)),
                           self.patch_text("tp-00.31-no-deck-select-on-hello.patch"))


class IgnoreRuleTests(unittest.TestCase):
    def test_patch_descriptions_are_not_ignored_by_git(self):
        here = os.path.dirname(os.path.abspath(__file__))
        if not shutil.which("git") or subprocess.run(["git", "-C", here, "rev-parse"], capture_output=True).returncode:
            self.skipTest("not in a git checkout")
        for name in ["wd-00.50-show-slot-16.patch", "wd-00.50-vos-scale-1.patch",
                     "tp-00.31-no-deck-select-on-hello.patch"]:
            path = os.path.join(here, "patches", name)
            result = subprocess.run(["git", "-C", here, "check-ignore", "-q", "--no-index", path])
            self.assertEqual(result.returncode, 1, f"{name} is ignored")

    def test_vendor_and_patched_images_in_this_folder_are_ignored_by_git(self):
        here = os.path.dirname(os.path.abspath(__file__))
        if not shutil.which("git") or subprocess.run(["git", "-C", here, "rev-parse"], capture_output=True).returncode:
            self.skipTest("not in a git checkout")
        for name in ["stock.dfu", "wd.bin", "dump.bin", "out.patched.dfu", "images/wd.hex", "notes.elf"]:
            path = os.path.join(here, name)
            result = subprocess.run(["git", "-C", here, "check-ignore", "-q", "--no-index", path])
            self.assertEqual(result.returncode, 0, f"{name} isn't ignored")


if __name__ == "__main__":
    unittest.main()
