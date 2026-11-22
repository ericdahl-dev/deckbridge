"""Tests for our block built for the display chip (#467): its layout, its reproducibility, and its two entry shims run
in an emulator (unicorn) against a synthetic flash. The stock functions the shims call are stubs here; no vendor bytes.

Run from tools/lc6000-display-fw after `make arm`:  python3 -I arm/test/test_block.py [BUILD_DIR]
Needs arm-none-eabi binutils and the `unicorn` Python package (pip install unicorn)."""
import hashlib, json, os, shutil, struct, subprocess, sys, tempfile, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
FW = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(FW, "..", "lc6000-firmware"))
import dfupatch  # noqa: E402
sys.path.insert(0, os.path.join(FW, "arm"))
import upper_header  # noqa: E402  (B's header, #572)

import unicorn  # noqa: E402
from unicorn import arm_const as A  # noqa: E402

BUILD = os.environ.get("ARM_BUILD", os.path.join(FW, "build", "arm"))
PAD_START, PAD_END = dfupatch.PAD_START, dfupatch.PAD_END
MARKER = 0x31574644
MARKER_AT = PAD_END - 4
STATE_AT, SRAM_END = 0x2002AE94, 0x20030000

# The stock addresses the block uses (#466), and where the synthetic chip puts its stubs.
STOCK_RENDER, STOCK_MALLOC, STOCK_SEND = 0x0800BEA0, 0x08017860, 0x080144C4
UPTIME, RX_COUNT, RX, WITNESS = 0x20001BA0, 0x2000189A, 0x20001DE0, 0xE000E400
LAYER2_SURFACE_PIXELS = 0x20001DC0
FRAME_AT, LAYER_AT = 0xD0100000, 0xD0180000
RETURN = 0x08000100  # where a shim returns to: the test stops there
UPPER, UPPER_SIZE = upper_header.BASE, upper_header.LIMIT  # block B's home (#501): sectors 8-11


def block():
    with open(os.path.join(BUILD, "block.bin"), "rb") as f:
        return f.read()


def symbols():
    out = subprocess.run(["arm-none-eabi-nm", os.path.join(BUILD, "block.elf")], capture_output=True, text=True,
                         check=True).stdout
    return {name: int(value, 16) for value, _, name in (line.split() for line in out.splitlines() if line.count(" ") == 2)}


def sections():
    out = subprocess.run(["arm-none-eabi-objdump", "-h", os.path.join(BUILD, "block.elf")], capture_output=True,
                         text=True, check=True).stdout
    found = {}
    for line in out.splitlines():
        parts = line.split()
        if len(parts) >= 7 and parts[0].isdigit():
            found[parts[1]] = (int(parts[2], 16), int(parts[3], 16))  # size, VMA
    return found


class LayoutTests(unittest.TestCase):
    def test_the_block_fills_the_padding_exactly_with_the_marker_last(self):
        data = block()
        self.assertEqual(len(data), PAD_END - PAD_START)
        self.assertEqual(struct.unpack_from("<I", data, len(data) - 4)[0], MARKER)

    def test_the_entries_sit_where_the_hook_patch_calls(self):
        names = symbols()
        self.assertEqual(names["hook_entry_command"] & ~1, dfupatch.HOOK_COMMAND_ENTRY)
        self.assertEqual(names["hook_entry_render"] & ~1, dfupatch.HOOK_RENDER_ENTRY)

    def test_nothing_needs_startup_code_and_our_state_sits_in_the_free_top_of_sram(self):
        found = sections()
        for name, (size, _) in found.items():
            if name.startswith((".data", ".bss")):
                self.assertEqual(size, 0, f"{name} would need startup code we don't have")
        size, at = found[".hookstate"]
        self.assertEqual(at, STATE_AT)
        self.assertLessEqual(at + size, SRAM_END)

    def test_no_allocator_is_linked_in(self):
        # The one stock malloc is called through a pointer (hook_stock.malloc); no allocator of our own exists.
        for name in symbols():
            self.assertNotRegex(name.lower(), r"malloc|calloc|realloc|free$|sbrk")

    def test_the_command_entry_ends_as_the_replaced_instruction_did(self):
        out = subprocess.run(["arm-none-eabi-objdump", "-d", "-j", ".entry_command", os.path.join(BUILD, "block.elf")],
                             capture_output=True, text=True, check=True).stdout
        self.assertIn("mov.w\tr8, #1", out)


class ReproducibleTests(unittest.TestCase):
    def test_two_builds_are_byte_identical(self):
        with tempfile.TemporaryDirectory() as one, tempfile.TemporaryDirectory() as two:
            for out in (one, two):
                subprocess.run(["make", "-s", "-C", FW, "arm", f"ARM_BUILD={out}", "ARM_DRAW=stub"], check=True,
                               capture_output=True)
            for name in ("block.bin", "block.elf"):
                with open(os.path.join(one, name), "rb") as a, open(os.path.join(two, name), "rb") as b:
                    self.assertEqual(a.read(), b.read(), name)

    def test_the_default_build_is_the_flashed_one(self):
        # #573: `make arm` builds what's on the owner's unit (block A reading block B, ARM_UPPER_PROVEN=1), not an inert
        # variant nobody flashes.
        with tempfile.TemporaryDirectory() as default, tempfile.TemporaryDirectory() as flashed:
            subprocess.run(["make", "-s", "-C", FW, "arm", f"ARM_BUILD={default}"], check=True, capture_output=True)
            subprocess.run(["make", "-s", "-C", FW, "arm", f"ARM_BUILD={flashed}", "ARM_UPPER_PROVEN=1"], check=True,
                           capture_output=True)
            for name in ("block.bin", "upper.bin"):
                with open(os.path.join(default, name), "rb") as a, open(os.path.join(flashed, name), "rb") as b:
                    self.assertEqual(a.read(), b.read(), name)


class BuildRecordTests(unittest.TestCase):
    def test_make_arm_records_the_bytes_and_flags_of_what_it_built(self):
        # #572: the kit reads this record instead of asking the owner how A was built.
        for proven in ("1", "0"):
            with self.subTest(proven=proven), tempfile.TemporaryDirectory() as out:
                subprocess.run(["make", "-s", "-C", FW, "arm", f"ARM_BUILD={out}", f"ARM_UPPER_PROVEN={proven}"],
                               check=True, capture_output=True)
                with open(os.path.join(out, "build.json")) as f:
                    record = json.load(f)
                with open(os.path.join(out, "block.bin"), "rb") as f:
                    a = f.read()
                with open(os.path.join(out, "upper.bin"), "rb") as f:
                    b = f.read()
                self.assertEqual(record["block_a"]["sha1"], hashlib.sha1(a).hexdigest())
                self.assertEqual(record["block_b"]["sha1"], hashlib.sha1(b).hexdigest())
                self.assertEqual((record["block_a"]["draw"], record["block_a"]["proven"]), ("1", proven))


class SizeTests(unittest.TestCase):
    """Each block's limit is a check on every toolchain that builds it, Mac and CI's Ubuntu GCC alike (#501): block A
    the 9,184-byte padding, block B the 512 KB upper flash."""

    def test_arm_size_reports_a_and_b_within_their_limits(self):
        with tempfile.TemporaryDirectory() as out:
            done = subprocess.run(["make", "-s", "-C", FW, "arm-size", f"ARM_SIZE_BUILD={out}"], capture_output=True,
                                  text=True)
        self.assertEqual(done.returncode, 0, done.stderr)
        lines = [line for line in done.stdout.splitlines() if line.startswith("block ")]
        self.assertEqual([line.split(":")[0] for line in lines],
                         ["block A (hook and protocol)", "block A (hook only)", "block B (drawing)"])
        for line, limit in zip(lines, (PAD_END - PAD_START, PAD_END - PAD_START, UPPER_SIZE)):
            used, of = (int(word) for word in line.split(":")[1].split()[0:3:2])
            self.assertEqual(of, limit, line)
            self.assertLessEqual(used, limit, line)

    def test_a_block_b_over_the_upper_flash_fails_arm_size(self):
        with tempfile.TemporaryDirectory() as out:
            big = os.path.join(out, "big.c")
            with open(big, "w") as f:
                f.write("const unsigned char upper_too_big[0x80000] = {1};\n"
                        "const unsigned char *upper_keep(void) { return upper_too_big; }\n")
            done = subprocess.run(["make", "-s", "-C", FW, "arm-size", f"ARM_SIZE_BUILD={out}/b",
                                   f"ARM_SIZE_UPPER_EXTRA={big}", "ARM_SIZE_UPPER_LDFLAGS=-Wl,-u,upper_keep"],
                                  capture_output=True, text=True)
        self.assertNotEqual(done.returncode, 0)
        self.assertRegex(done.stdout + done.stderr, r"block B \(drawing\): over|overflow")

    def test_a_block_too_big_for_the_padding_fails_the_link(self):
        with tempfile.TemporaryDirectory() as out:
            subprocess.run(["make", "-s", "-C", FW, "arm", f"ARM_BUILD={out}", "ARM_DRAW=0"], check=True,
                           capture_output=True)
            big_c, big_o = os.path.join(out, "big.c"), os.path.join(out, "big.o")
            with open(big_c, "w") as f:
                f.write("const unsigned char hook_too_big[9184] = {1};\n"
                        "const unsigned char *hook_keep(void) { return hook_too_big; }\n")
            cpu = ["-mcpu=cortex-m4", "-mthumb", "-mfloat-abi=hard", "-mfpu=fpv4-sp-d16"]
            subprocess.run(["arm-none-eabi-gcc", *cpu, "-c", big_c, "-o", big_o], check=True)
            objects = sorted(os.path.join(out, name) for name in os.listdir(out) if name.endswith(".o"))
            done = subprocess.run(["arm-none-eabi-gcc", *cpu, "-nostdlib", "-nostartfiles", "-Wl,-u,hook_keep",
                                   "-Wl,-T," + os.path.join(FW, "arm", "block.ld"), "-o", os.path.join(out, "x.elf"),
                                   *objects, "-lgcc"], capture_output=True, text=True)
        self.assertNotEqual(done.returncode, 0)
        self.assertRegex(done.stderr, r"doesn't fit|overflow")


class Chip:
    """A synthetic display chip: flash with our block in the padding and stubs where stock's functions are."""

    def __init__(self, marker=True, data=None, upper=None, count_upper_reads=False):
        self.uc = uc = unicorn.Uc(unicorn.UC_ARCH_ARM, unicorn.UC_MODE_THUMB | unicorn.UC_MODE_MCLASS)
        for base, size in ((0x08000000, 0x100000), (0x10000000, 0x10000), (0x20000000, 0x30000),
                           (0x40016000, 0x1000), (0xD0000000, 0x200000), (0xE000E000, 0x1000)):
            uc.mem_map(base, size)
        data = bytearray(data if data is not None else block())
        if not marker:
            data[-4:] = b"\xff\xff\xff\xff"
        uc.mem_write(PAD_START, bytes(data))
        # The upper flash, 0x08080000-0x080FFFFF: erased, unless a test puts a block B there.
        uc.mem_write(UPPER, b"\xff" * UPPER_SIZE)
        if upper is not None:
            uc.mem_write(UPPER, upper)
        self.upper_reads = 0

        def on_upper_read(uc, access, address, size, value, _):
            self.upper_reads += 1
        # Only for the tests that prove nothing reads it: with a read hook over the code B runs from, unicorn 2.1.4
        # skips instructions in that code (#515 found an `mls` skipped mid-glyph; the same B with no hook draws as the
        # native build does), so a chip that runs B has none.
        if count_upper_reads:
            uc.hook_add(unicorn.UC_HOOK_MEM_READ, on_upper_read, begin=UPPER, end=UPPER + UPPER_SIZE - 1)
        bx_lr = b"\x70\x47"
        uc.mem_write(STOCK_RENDER, b"\x55\x20" + bx_lr)  # movs r0, #0x55 ; bx lr
        uc.mem_write(STOCK_MALLOC, b"\x00\x48" + bx_lr + struct.pack("<I", FRAME_AT))  # ldr r0, =FRAME_AT ; bx lr
        uc.mem_write(STOCK_SEND, bx_lr)
        uc.mem_write(RETURN, b"\x00\xbf")
        uc.mem_write(LAYER2_SURFACE_PIXELS, struct.pack("<I", LAYER_AT))
        uc.mem_write(0x4001680C, struct.pack("<I", (67 << 16) | 17))  # LTDC_BPCR: AHBP 67, AVBP 17 (#438's timing)
        uc.mem_write(STATE_AT, b"\xa5" * 0x400)  # SRAM garbage, as at power-on
        self.calls = {"render": 0, "malloc": 0}
        self.sent = []

        def on_code(uc, address, size, _):
            if address == STOCK_RENDER:
                self.calls["render"] += 1
            elif address == STOCK_MALLOC:
                self.calls["malloc"] += 1
            elif address == STOCK_SEND:
                length = uc.reg_read(A.UC_ARM_REG_R2)
                self.sent.append(bytes(uc.mem_read(uc.reg_read(A.UC_ARM_REG_R1), length)))
        uc.hook_add(unicorn.UC_HOOK_CODE, on_code)

    def call(self, entry, count=2_000_000, **regs):
        uc = self.uc
        uc.reg_write(A.UC_ARM_REG_SP, 0x10010000 - 0x100)
        uc.reg_write(A.UC_ARM_REG_LR, RETURN | 1)
        for name, value in regs.items():
            uc.reg_write(getattr(A, f"UC_ARM_REG_{name.upper()}"), value)
        self.instructions = 0
        counting = uc.hook_add(unicorn.UC_HOOK_CODE, self.count_instruction)
        uc.emu_start(entry | 1, RETURN, count=count)
        uc.hook_del(counting)
        return {name: uc.reg_read(getattr(A, f"UC_ARM_REG_{name.upper()}"))
                for name in ("r0", "r4", "r5", "r6", "r7", "r8", "r9", "r10", "r11", "sp")}

    def count_instruction(self, uc, address, size, _):
        self.instructions += 1

    def receive(self, hexbytes):
        message = bytes.fromhex(hexbytes)
        self.uc.mem_write(RX, message)
        self.uc.mem_write(RX_COUNT, struct.pack("<H", len(message)))
        return message

    def word(self, address):
        return struct.unpack("<I", self.uc.mem_read(address, 4))[0]


CALLEE_SAVED = dict(r4=0x44444444, r6=0x66666666, r9=0x99999999, r11=0xBBBBBBBB)
CAPABILITY = "F000020B7F1020000200 01F7".replace(" ", "")
BEGIN = "F000020B7F102000020101F7"
DECK_2_RED_TRACK = "F000020B7F10200009030201 7F0000000001F7".replace(" ", "")
TITLE_STROBE = "F000020B7F102000080400 5374726F6265F7".replace(" ", "")  # title "Strobe", as test/test_sequence.c
TEMPO_128 = "F000020B7F10200003050A00F7"
END = "F000020B7F102000020201F7"
TIME_83_OF_165 = "F000020B7F10200005060053 0125F7".replace(" ", "")  # 83 of 165 s: the progress ring under way


class CommandEntryTests(unittest.TestCase):
    def command(self, chip, cmd, message_hex):
        message = chip.receive(message_hex)
        length = (message[7] << 7) | message[8]
        return chip.call(dfupatch.HOOK_COMMAND_ENTRY, r10=cmd, r7=RX, r5=length, r8=0, **CALLEE_SAVED)

    def test_another_command_gets_what_the_replaced_instruction_did_and_nothing_else(self):
        chip = Chip()
        out = self.command(chip, 0x7F, "F000020B7F107F000101F7")
        self.assertEqual(out["r8"], 1)
        self.assertEqual(out["r5"], 1)
        self.assertEqual(out["r7"], RX)
        self.assertEqual(out["sp"], 0x10010000 - 0x100)
        for reg, value in CALLEE_SAVED.items():
            self.assertEqual(out[reg], value, reg)
        self.assertEqual(chip.word(STATE_AT), 0xA5A5A5A5)  # our state untouched

    def test_without_the_marker_our_command_runs_nothing(self):
        chip = Chip(marker=False)
        out = self.command(chip, 0x20, CAPABILITY)
        self.assertEqual(out["r8"], 1)
        self.assertEqual(chip.calls["malloc"], 0)
        self.assertEqual(chip.word(STATE_AT), 0xA5A5A5A5)

    def test_a_capability_ask_is_answered_through_stocks_sender_after_one_malloc(self):
        chip = Chip()
        self.command(chip, 0x20, CAPABILITY)
        chip.call(dfupatch.HOOK_RENDER_ENTRY)
        self.assertEqual(chip.calls["malloc"], 1)
        self.assertEqual(chip.sent, [bytes.fromhex("F000020B01102000020001F7")])


class RenderEntryTests(unittest.TestCase):
    def test_it_calls_stocks_render_and_returns_zero(self):
        for marker in (True, False):
            chip = Chip(marker=marker)
            out = chip.call(dfupatch.HOOK_RENDER_ENTRY, **CALLEE_SAVED)
            self.assertEqual(chip.calls["render"], 1)
            self.assertEqual(out["r0"], 0)
            for reg, value in CALLEE_SAVED.items():
                self.assertEqual(out[reg], value, reg)

    def test_before_our_first_message_the_tick_touches_nothing(self):
        chip = Chip()
        for _ in range(3):
            chip.call(dfupatch.HOOK_RENDER_ENTRY)
        self.assertEqual(chip.word(STATE_AT), 0xA5A5A5A5)
        self.assertEqual(chip.calls["malloc"], 0)
        self.assertEqual(chip.sent, [])


def built_layout():
    """The layout word (#516) the built B carries: the chip's DFW_LAYOUT, which the Mac can't work out."""
    return upper_header.parse(upper_block()).layout


def sealed_upper(layout, entry, body, band=None):
    """A sealed block B (upper_header.build). Its band entry is the draw entry plus 2 unless given: a capability ask
    calls neither."""
    return upper_header.build(body, layout, entry, band if band is not None else entry + 2)


def good_upper():
    """A small block B for the chip's layout. Its entry is never called by a capability ask."""
    return sealed_upper(built_layout(), 0x0808001D, b"123456789")


def proven_block():
    with tempfile.TemporaryDirectory() as out:
        subprocess.run(["make", "-s", "-C", FW, "arm", f"ARM_BUILD={out}", "ARM_UPPER_PROVEN=1"], check=True,
                       capture_output=True)
        with open(os.path.join(out, "block.bin"), "rb") as f:
            return f.read()


def full_upper():
    """A good B filling all 512 KB, so the check is as long as it can ever be."""
    return sealed_upper(built_layout(), 0x0808001D, bytes((i * 7 + 3) & 0xFF for i in range(UPPER_SIZE - upper_header.HEADER)))


class UpperSwitchTests(unittest.TestCase):
    """Block A reads B only when built with the "upper flash proven" switch (#501)."""

    def test_checking_all_512_kb_at_the_ask_stays_well_under_the_apps_half_second(self):
        # Measured at 6.1M instructions for all 512 KB: at 180 MHz and about 1.3 cycles an instruction (flash wait
        # states), about 45 ms, once per boot. Today's B (about 10 KB) is about 1 ms. The app waits 0.5 s.
        chip = Chip(data=proven_block(), upper=full_upper())
        message = chip.receive(CAPABILITY)
        chip.call(dfupatch.HOOK_COMMAND_ENTRY, count=20_000_000, r10=0x20, r7=RX, r5=(message[7] << 7) | message[8],
                  r8=0)
        self.assertLess(chip.instructions, 7_500_000)
        chip.call(dfupatch.HOOK_RENDER_ENTRY)
        self.assertEqual(chip.sent, [bytes.fromhex("F000020B01102000020001F7")])

    def ask(self, chip):
        message = chip.receive(CAPABILITY)
        chip.call(dfupatch.HOOK_COMMAND_ENTRY, r10=0x20, r7=RX, r5=(message[7] << 7) | message[8], r8=0)
        chip.call(dfupatch.HOOK_RENDER_ENTRY)

    def test_flipping_the_switch_rebuilds_block_a_in_the_same_build_dir(self):
        # The README's own order: make arm, then, after the read-only checks, make arm ARM_UPPER_PROVEN=1.
        with tempfile.TemporaryDirectory() as out:
            built = []
            for proven in ("0", "1", "0"):
                subprocess.run(["make", "-s", "-C", FW, "arm", f"ARM_BUILD={out}", f"ARM_UPPER_PROVEN={proven}"],
                               check=True, capture_output=True)
                with open(os.path.join(out, "block.bin"), "rb") as f:
                    built.append(f.read())
        self.assertNotEqual(built[0], built[1], "the switch on must give a new block A")
        self.assertEqual(built[0], built[2], "and off again the old one")

    def test_with_the_switch_the_tick_touches_nothing_before_our_first_message(self):
        # A power cycle clears any crash of ours only if our code runs after our first message (#501).
        chip = Chip(data=proven_block(), upper=upper_block(), count_upper_reads=True)
        for _ in range(3):
            chip.call(dfupatch.HOOK_RENDER_ENTRY)
        self.assertEqual(chip.upper_reads, 0)
        self.assertEqual(chip.word(STATE_AT), 0xA5A5A5A5)
        self.assertEqual(chip.uc.mem_read(WITNESS, 1), b"\x00")

    def test_without_the_switch_block_a_never_reads_the_upper_flash(self):
        chip = Chip(upper=good_upper(), count_upper_reads=True)
        for _ in range(3):
            chip.call(dfupatch.HOOK_RENDER_ENTRY)
        self.ask(chip)
        self.assertEqual(chip.upper_reads, 0)

    def test_with_the_switch_only_a_good_block_b_gets_the_ask_answered(self):
        proven = proven_block()
        answer = bytes.fromhex("F000020B01102000020001F7")
        for upper, sent in ((None, []), (good_upper(), [answer])):
            with self.subTest(upper=upper is not None):
                chip = Chip(data=proven, upper=upper)
                self.ask(chip)
                self.assertEqual(chip.sent, sent)



def upper_block():
    with open(os.path.join(BUILD, "upper.bin"), "rb") as f:
        return f.read()


class UpperBlockTests(unittest.TestCase):
    """Block B, the drawing, built for 0x08080000 (#501): the header block A checks (upper_header, pinned to A's C)."""

    def test_b_starts_with_a_header_block_a_will_accept(self):
        data = upper_block()
        header = upper_header.check(data)
        length, draw, band = header.length, header.draw, header.band
        self.assertEqual(length, len(data))
        out = subprocess.run(["arm-none-eabi-nm", os.path.join(BUILD, "upper.elf")], capture_output=True, text=True,
                             check=True).stdout
        names = {name: int(value, 16) for value, _, name in (line.split() for line in out.splitlines()
                                                              if line.count(" ") == 2)}
        for entry, name in ((draw, "dfw_draw"), (band, "dfw_draw_band")):
            with self.subTest(name):
                self.assertEqual(entry & ~1, names[name])  # nm prints a Thumb function's address without bit 0
                self.assertEqual(entry & 1, 1, "Thumb")
                self.assertTrue(UPPER + upper_header.HEADER <= entry < UPPER + length)

    def test_block_a_draws_through_a_good_b_and_stays_silent_for_a_corrupted_one(self):
        proven = proven_block()
        answer = bytes.fromhex("F000020B01102000020001F7")
        corrupted = bytearray(upper_block())
        corrupted[len(corrupted) // 2] ^= 0x01
        # B's own bytes, resealed for another dfw_unit (#516): its CRC is good, only the layout is A's no longer.
        built = upper_block()
        header = upper_header.parse(built)
        other_layout = sealed_upper(header.layout ^ 1, header.draw, built[upper_header.HEADER:], header.band)
        for upper, drawn in ((built, True), (bytes(corrupted), False), (other_layout, False)):
            with self.subTest(drawn=drawn):
                chip = Chip(data=proven, upper=upper)
                for hexbytes in (CAPABILITY, BEGIN, DECK_2_RED_TRACK):
                    message = chip.receive(hexbytes)
                    chip.call(dfupatch.HOOK_COMMAND_ENTRY, count=20_000_000, r10=0x20, r7=RX,
                              r5=(message[7] << 7) | message[8], r8=0)
                chip.call(dfupatch.HOOK_RENDER_ENTRY, count=50_000_000)
                self.assertEqual(chip.sent, [answer] if drawn else [])
                layer = bytes(chip.uc.mem_read(LAYER_AT, 320 * 240 * 2))
                self.assertEqual(any(layer), drawn, "B's drawing reached the screen" if drawn else "nothing drawn")

    def test_block_b_draws_a_title_on_the_chip(self):
        # The text path off the Mac for the first time (#458, #501): layout's soft-double math (__aeabi_d*), the kern
        # search and the 4-bit glyph blits. Frame rows 60-90 hold the title; the layer shows the frame turned 180
        # degrees at (61, 21), so they are layer rows 21 + 197 - 90 to 21 + 197 - 60.
        proven = proven_block()
        rows = []
        for extra in ((), (TITLE_STROBE, TEMPO_128)):
            chip = Chip(data=proven, upper=upper_block())
            for hexbytes in (CAPABILITY, BEGIN, DECK_2_RED_TRACK, *extra):
                message = chip.receive(hexbytes)
                chip.call(dfupatch.HOOK_COMMAND_ENTRY, count=20_000_000, r10=0x20, r7=RX,
                          r5=(message[7] << 7) | message[8], r8=0)
            chip.call(dfupatch.HOOK_RENDER_ENTRY, count=200_000_000)
            top, bottom = 21 + 197 - 90, 21 + 197 - 60
            rows.append(bytes(chip.uc.mem_read(LAYER_AT + top * 320 * 2, (bottom - top + 1) * 320 * 2)))
        self.assertNotEqual(rows[0], rows[1], "the title changed the title rows")

    def test_block_a_calls_bs_band_right_after_a_real_present_and_never_otherwise(self):
        # The band (#524) goes straight into layer 2, so it must only follow a present: never on a tick that showed
        # nothing, and never after end. With a time under way, B's band draws the ring outside the frame: at 12
        # o'clock, r 105, frame (99, -7), the fill's start in the red deck's color, 0xF800, at panel (159, 225), which
        # no frame copy touches. The layer is zeroed when it is turned on, so a band called before the present is lost.
        chip = Chip(data=proven_block(), upper=upper_block())

        def deliver(*messages):
            for hexbytes in messages:
                message = chip.receive(hexbytes)
                chip.call(dfupatch.HOOK_COMMAND_ENTRY, count=20_000_000, r10=0x20, r7=RX,
                          r5=(message[7] << 7) | message[8], r8=0)
            chip.call(dfupatch.HOOK_RENDER_ENTRY, count=50_000_000)

        twelve = LAYER_AT + (225 * 320 + 159) * 2

        def corner():
            return struct.unpack("<H", chip.uc.mem_read(twelve, 2))[0]

        deliver(CAPABILITY)
        self.assertEqual(corner(), 0, "the ask presents nothing, so no band")
        deliver(BEGIN, DECK_2_RED_TRACK, TIME_83_OF_165)
        self.assertEqual(corner(), 0xF800, "the band follows the present")
        chip.uc.mem_write(twelve, b"\x00\x00")
        deliver(END)
        deliver()
        self.assertEqual(corner(), 0, "end presents nothing, so no band")


FRAME_DUMP = os.environ.get("FRAME_DUMP", os.path.join(FW, "build", "frame-dump"))
SIZE = 198


def native_frame(messages):
    """The frame the native build (the Mac's compiler, the same src/) draws for these messages: 198x198 0x00RRGGBB."""
    out = subprocess.run([FRAME_DUMP, *messages], check=True, capture_output=True).stdout
    return struct.unpack(f"<{SIZE * SIZE}I", out)


def native_panel(messages):
    """The whole panel the native build shows for these messages (#524): 320x240 RGB565, the frame turned and the band."""
    out = subprocess.run([FRAME_DUMP, "--panel", *messages], check=True, capture_output=True).stdout
    return struct.unpack(f"<{320 * 240}H", out)


def chip_frame(messages):
    """The frame emulated block A and B draw for the same messages: B's back buffer at FRAME_AT, before A turns it."""
    chip = Chip(data=proven_block(), upper=upper_block())
    for hexbytes in (CAPABILITY, *messages):
        message = chip.receive(hexbytes)
        chip.call(dfupatch.HOOK_COMMAND_ENTRY, count=20_000_000, r10=0x20, r7=RX, r5=(message[7] << 7) | message[8], r8=0)
    chip.call(dfupatch.HOOK_RENDER_ENTRY, count=200_000_000)
    return chip, struct.unpack(f"<{SIZE * SIZE}I", bytes(chip.uc.mem_read(FRAME_AT, SIZE * SIZE * 4)))


def frame_difference(a, b):
    """How many pixels differ, and the worst channel difference."""
    count = worst = 0
    for p, q in zip(a, b):
        if p != q:
            count += 1
            worst = max(worst, *(abs((p >> s & 0xFF) - (q >> s & 0xFF)) for s in (0, 8, 16)))
    return count, worst


class NativeFrameTests(unittest.TestCase):
    """#515: the emulated chip draws, pixel for pixel, what the native build draws for the same messages. Both come
    from the same source, so any difference is the Arm's: its float math, its libc stand-ins, an uninitialized read."""

    def assert_same_frame(self, name, messages):
        native = native_frame(messages)
        _, arm = chip_frame(messages)
        count, worst = frame_difference(native, arm)
        self.assertEqual((count, worst), (0, 0), f"{name}: {count} pixels differ, worst by {worst}")

    def test_a_deck_alone(self):
        self.assert_same_frame("deck 2, red, track", (BEGIN, DECK_2_RED_TRACK))

    def test_every_drawn_element_matches(self):
        def message(op, args=b""):
            body = bytes([op]) + args
            return (bytes.fromhex("F000020B7F1020") + bytes([len(body) >> 7, len(body) & 0x7F]) + body + b"\xf7").hex()

        def text(field, chars):
            # Windows-1252, 0x80 and up as 7F then the code minus 0x80.
            escaped = b"".join(bytes([0x7F, c - 0x80]) if c >= 0x80 else bytes([c]) for c in chars.encode("cp1252"))
            return message(0x04, bytes([field]) + escaped)

        deck = message(0x03, bytes([2, 1, 0x7F, 0, 0, 0, 0, 1]))   # deck 2, 255/0/0, a track
        empty_deck = message(0x03, bytes([4, 0, 0, 1, 0, 1, 0x7F, 0]))   # deck 4, 0/128/255, empty
        cases = {
            # The text path: a title over two lines at 20 px, an artist with an é cut at the circle, key and tempo.
            "text": (BEGIN, deck, text(0, "Night Drive And Another Line"),
                     text(1, "Café del Mar with a name long enough to cut"), text(2, "11B"), message(0x05, bytes([0x0A, 0]))),
            # An empty deck: no title, the untitled words and the caption.
            "untitled": (BEGIN, empty_deck, text(0, ""), text(3, "No track")),
            # A letter the font lacks: the box (0x81).
            "box": (BEGIN, deck, message(0x04, bytes([0, 0x41, 0x7F, 0x01]))),
            # The live elements: beat 3 lit, the needle at 1500, the meter at 64 with the peak held at 90.
            "live": (BEGIN, deck, message(0x08, bytes([3])), message(0x09, bytes([1500 >> 7, 1500 & 0x7F])),
                     message(0x0A, bytes([64, 90]))),
            # The phase rule: in phase (the tick), then a hundredth of a beat behind (the bar).
            "in phase": (BEGIN, deck, message(0x0B, bytes([0, 0]))),
            "behind": (BEGIN, deck, message(0x0B, bytes([0x7E, 0x5C]))),
            # The waiting look: loaded, feedback stale.
            "stale": (BEGIN, deck, message(0x07, bytes([0x21]))),
        }
        for name, messages in cases.items():
            with self.subTest(name):
                self.assert_same_frame(name, messages)

    def test_the_panel_shows_the_native_frame_turned_and_in_rgb565_with_black_around_it(self):
        # Layer 2 is the whole 320x240 panel: the frame turned 180 degrees at (61, 21), each pixel's top 5, 6 and 5 bits
        # of red, green and blue; the band's ring round it (#524), frame (x, y) at panel (61 + 197 - x, 21 + 197 - y);
        # black everywhere else. The native build's panel (frame-dump --panel) is all of that, from the same source.
        messages = (BEGIN, DECK_2_RED_TRACK, TIME_83_OF_165)
        want = native_panel(messages)
        self.assertGreater(sum(1 for i, w in enumerate(want) if w and not (61 <= i % 320 < 259 and 21 <= i // 320 < 219)),
                           1000, "the native panel has the band's ring outside the frame")
        chip, _ = chip_frame(messages)
        layer = struct.unpack(f"<{320 * 240}H", bytes(chip.uc.mem_read(LAYER_AT, 320 * 240 * 2)))
        wrong = sum(1 for got, w in zip(layer, want) if got != w)
        self.assertEqual(wrong, 0, f"{wrong} of the panel's pixels differ")


def struct_fields(source, opening, closing):
    """The field names declared between `opening` and `closing` in a C header, comments dropped."""
    import re
    end = source.index(closing)
    body = source[source.rindex(opening, 0, end) + len(opening):end]
    body = re.sub(r"//[^\n]*|/\*.*?\*/", "", body, flags=re.S)
    names = []
    for declaration in body.split(";"):
        declaration = re.sub(r"\[[^\]]*\]", "", declaration).strip()
        if declaration:
            names += [re.findall(r"\w+$", part.strip())[0] for part in declaration.split(",")]
    return names


class LayoutWordTests(unittest.TestCase):
    """DFW_LAYOUT (#516) is only a guard if it counts every field B can read: a field added into padding moves nothing
    else, so only its own term changes the word."""

    def test_every_dfw_unit_and_deck_field_is_in_the_layout_word(self):
        with open(os.path.join(FW, "src", "dfw.h")) as f:
            source = f.read()
        layout = source[source.index("#define DFW_LAYOUT"):]
        layout = layout[:layout.index("\n\n")]
        for struct_name, opening, closing in (
                ("dfw_unit", "typedef struct dfw_unit {", "} dfw_unit;"),
                ("dfw_deck_state", "typedef struct {", "} dfw_deck_state;")):
            fields = struct_fields(source, opening, closing)
            self.assertGreater(len(fields), 4, struct_name)
            for field in fields:
                with self.subTest(struct=struct_name, field=field):
                    self.assertIn(f"offsetof({struct_name}, {field})", layout)

if __name__ == "__main__":
    if len(sys.argv) > 1:
        BUILD = sys.argv.pop(1)
    unittest.main()
