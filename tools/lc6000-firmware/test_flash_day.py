"""Guards for the flash-day kit (#435): the wizard and the update-mode tool. No hardware, no vendor data.
Run from the repo root: python3 -I -m unittest discover tools/lc6000-firmware"""
import os, re, shutil, subprocess, sys, unittest

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import drawn_plan  # noqa: E402

HERE = os.path.dirname(os.path.realpath(__file__))


def text(name):
    with open(os.path.join(HERE, name)) as f:
        return f.read()


class WizardTests(unittest.TestCase):
    def setUp(self):
        self.script = text("flash-day.sh")
        self.stages = self.script[self.script.index("# STAGES:"):]

    def body(self, function):
        """One shell function's text, from its opening line to the closing brace at the start of a line."""
        start = self.stages.index(f"{function}() {{")
        return self.stages[start:self.stages.index("\n}\n", start)]

    def test_the_script_parses(self):
        bash = shutil.which("bash")
        self.assertIsNotNone(bash)
        self.assertEqual(subprocess.run([bash, "-n", os.path.join(HERE, "flash-day.sh")]).returncode, 0)

    def test_the_stage_count_matches_the_stages_written(self):
        for function in ("run_wizard", "run_drawn"):
            with self.subTest(function):
                body = self.body(function)
                declared = int(re.search(r"^TOTAL_STAGES=(\d+)", body, re.M).group(1))
                self.assertEqual(declared, len(re.findall(r'^stage "', body, re.M)))

    def test_the_only_writes_to_the_chip_are_flash_and_the_drawn_write_step(self):
        # flash() for the stock wizard, behind its typed word here; the drawn loop's write step, which drawn_plan.py
        # asks for only after its typed word (#567, tested there).
        downloads = [m.start() for m in re.finditer(r"dfu-util[^\n]*\s-D\s", self.stages)]
        self.assertEqual(len(downloads), 2)
        start, end = self.stages.index("flash() {"), self.stages.index("# reboot_check")
        self.assertTrue(start < downloads[0] < end)
        drawn = self.stages.index("run_drawn() {")
        self.assertGreater(downloads[1], drawn)
        gate = self.stages.index('[[ "$typed" == "FLASH" ]] || way_back')
        self.assertTrue(start < gate < downloads[0])

    def test_no_dangerous_dfu_util_options_appear(self):
        # 0x1FFF only as the option bytes' 16-byte read (#468): never the system memory or anything else up there.
        option_line = 'OPTION_ADDRESS="0x1FFFC000"; OPTION_SIZE="16"'
        self.assertEqual(self.stages.count("0x1FFF"), self.stages.count(option_line))
        for word in (":mass-erase", ":unprotect", ":force", "-s 0x08000000"):
            self.assertNotIn(word, self.stages)

    def test_every_read_stays_in_the_settings_app_upper_and_option_bytes(self):
        self.assertIn('APP_ADDRESS="0x08008000"; APP_SIZE="0x78000"', self.stages)
        self.assertIn('SETTINGS_ADDRESS="0x08004000"; SETTINGS_SIZE="0x4000"', self.stages)
        self.assertIn('UPPER_ADDRESS="0x08080000"; UPPER_SIZE="0x80000"', self.stages)
        self.assertIn('OPTION_ADDRESS="0x1FFFC000"; OPTION_SIZE="16"', self.stages)
        uploads = re.findall(r"dfu-util[^\n]*-U[^\n]*", self.stages)
        for upload in uploads:
            # Flash on alt 0, the option bytes on alt 1, each only at its own address and size.
            self.assertRegex(upload, r'-a 0 -s "\$(APP|SETTINGS|UPPER)_ADDRESS:\$\1_SIZE"|'
                                     r'-a 1 -s "\$OPTION_ADDRESS:\$OPTION_SIZE"')
        self.assertTrue(any("$OPTION_ADDRESS" in upload for upload in uploads))

    def test_the_stock_flash_is_denons_own_updater_before_any_patched_image(self):
        # Seen on hardware (2026-11-19): the updater flashes a chip that's in update mode, and refuses a running,
        # current unit. So Denon's tool does the stock flash, and dfu-util is kept for the patched image.
        stock = self.stages.index('stage "Stock flash: Denon\'s own updater"')
        patched = self.stages.index('stage "Patched image (optional)"')
        self.assertLess(stock, patched)
        between = self.stages[stock:patched]
        self.assertIn("Open Denon's updater", between)
        self.assertNotIn('flash "$STOCK_WD"', self.stages[:stock])

    def test_the_patched_stage_checks_the_chip_holds_stock_before_writing(self):
        patched = self.stages[self.stages.index('stage "Patched image (optional)"'):]
        self.assertLess(patched.index('dfupatch compare "$STOCK_WD"'), patched.index('flash "$PATCHED_WD" "patched"'))

    def test_the_way_back_says_update_mode_first_then_denons_updater(self):
        way_back = self.stages[self.stages.index("way_back() {"):self.stages.index("# dfu_paths")]
        self.assertIn("update mode", way_back)
        self.assertIn("refuses a unit that's running and current", way_back)
        self.assertIn("BACK + FWD + VINYL", way_back)

    def test_no_part_of_the_script_branches_on_pythons_printed_words(self):
        # #567: every drawn decision is drawn_plan.py's; the stock wizard never judged B or the app against the owner's
        # image, so none of that is left anywhere in the shell.
        for text in ("^holds", "holds*", "replace*", "drawn upper", "drawn app", "read_upper", "read_options",
                     '\ndrawn() {'):
            self.assertNotIn(text, self.stages, text)

    def test_look_asks_the_plan_about_the_devices_and_counts_nothing_itself(self):
        # One judgment for both wizards (#567): exactly one device, and the display chip, not the top panel chip.
        look = self.body("look")
        self.assertIn('plan devices "$listing"', look)
        self.assertNotIn("grep -c", look)
        self.assertNotIn("0x08000000", look)

    def test_the_update_mode_message_needs_a_confirmation_first(self):
        send = self.stages.index("send --yes-enter-update-mode")
        ask = self.stages.index('confirm "Send the update-mode message to the display chip now?" || way_back')
        self.assertLess(ask, send)


class DrawnPathTests(unittest.TestCase):
    """The drawn flash (#468, #567): `flash-day.sh drawn` is a thin adapter over drawn_plan.py, which decides every
    step (tested with a fake unit in test_drawn_plan.py). Here: the shell asks the plan, does what it's told, and
    records the result. The wizard is never run here: it builds and runs the real update-mode tool and dfu-util."""

    body = WizardTests.body

    def setUp(self):
        WizardTests.setUp(self)
        self.drawn = self.body("run_drawn")
        loop = self.drawn.index("while :; do")
        self.loop = self.drawn[loop:self.drawn.index("\ndone\n", loop)]

    def branch(self, kind):
        """One step's branch of the loop's case, up to the next step's label (a branch may hold a case of its own)."""
        start = self.loop.index(f"\n    {kind})")
        following = re.search(r"\n    [a-z*-]+\)", self.loop[start + 1:])
        return self.loop[start:start + 1 + following.start()] if following else self.loop[start:]

    def test_the_drawn_path_runs_only_when_asked_for(self):
        dispatch = self.stages[self.stages.index('if [[ "${1:-}" == "drawn" ]]; then'):]
        self.assertLess(dispatch.index("run_drawn"), dispatch.index("else\n  run_wizard \"$@\""))

    def test_it_never_does_a_stock_flash(self):
        self.assertNotIn('flash "$STOCK_WD"', self.drawn)

    def test_it_begins_a_plan_and_asks_it_for_each_step(self):
        self.assertIn('plan begin "$PLAN" "$CURRENT_WD" "$UPPER_DFU" "$OWNER_DFU" "$RECORD" "$WORK"', self.drawn)
        self.assertIn('plan next "$PLAN"', self.loop)

    def test_it_handles_exactly_the_steps_the_plan_can_ask_for(self):
        handled = set(re.findall(r"^    ([a-z-]+)\)", self.loop, re.M))
        self.assertEqual(handled, set(drawn_plan.ACTIONS))

    def test_it_never_branches_on_pythons_printed_words(self):
        for word in ("holds", "replace", "erased", "UPPER_STATE", "APP_STATE", "B_DONE", "A_DONE", "B_REPLACE"):
            self.assertNotIn(word, self.drawn, word)

    def test_every_answer_and_result_goes_back_to_the_plan(self):
        for kind in ("ask", "type", "update-mode", "list", "read", "write", "power-cycle", "skip"):
            with self.subTest(kind):
                self.assertIn('plan record "$PLAN"', self.branch(kind))

    def test_its_only_write_is_the_write_step(self):
        downloads = [m.start() for m in re.finditer(r"dfu-util[^\n]*\s-D\s", self.drawn)]
        self.assertEqual(len(downloads), 1)
        self.assertIn("-D", self.branch("write"))

    def test_a_stop_says_why_and_goes_the_way_back(self):
        self.assertIn("way_back", self.branch("stop"))

    def test_the_way_back_says_block_b_stays_and_is_harmless(self):
        way_back = self.stages[self.stages.index("way_back() {"):self.stages.index("# dfu_paths")]
        self.assertIn("Block B", way_back)
        self.assertIn("only block A calls it", way_back)


class UpdateModeToolTests(unittest.TestCase):
    def setUp(self):
        self.source = text("enter-update-mode.swift")

    def test_it_sends_only_the_updaters_message(self):
        self.assertIn("[0xF0, 0x00, 0x02, 0x0B, 0x01, 0x10, 0x72, 0x00, 0x00, 0xF7]", self.source)
        self.assertEqual(self.source.count("MIDISendEventList("), 1)

    def test_it_only_addresses_the_wd_port_and_needs_exactly_one(self):
        self.assertIn('let portHint = "LC6000 PRIME WD"', self.source)
        self.assertIn("found.count == 1", self.source)

    def test_send_needs_its_long_flag(self):
        self.assertIn('case "send" where arguments.dropFirst().first == "--yes-enter-update-mode":', self.source)


if __name__ == "__main__":
    unittest.main()
