"""Whole runs of the real `flash-day.sh drawn` (#567) against a fake unit: stand-ins for dfu-util, the update-mode tool
and swiftc on a PATH that holds only them and /usr/bin:/bin, with HOME and the work folder in a temporary folder. So the
real dfu-util, the real update-mode tool in ~/lc6000 and MIDI are out of reach, and each test checks that first: the
owner's unit may be plugged in while these run.
Run from the repo root: python3 -I -m unittest discover tools/lc6000-firmware"""
import contextlib, io, json, os, shutil, subprocess, sys, tempfile, textwrap, unittest

import build_owner_image
import build_record
import build_upper_dfu
import dfupatch
from test_drawn_plan import write_record
from test_build_owner_image import stock_like_element, synthetic_block
from test_build_upper_dfu import good_block
from test_dfupatch import dfuse_file, full_wd_element

HERE = os.path.dirname(os.path.realpath(__file__))
WIZARD = os.path.join(HERE, "flash-day.sh")
APP, UPPER = 0x08008000, 0x08080000
DISPLAY_LAYOUT = "@Internal Flash  /0x08000000/04*016Kg,01*064Kg,07*128Kg"
OPTIONS_OK = bytes([0xEC, 0xAA]) + b"\xff" * 6 + bytes([0xFF, 0x0F]) + b"\xff" * 6

# The fake dfu-util: the unit is files in $FAKE_UNIT (app.bin, upper.bin, options.bin, listing.txt); every call is
# logged there. -U refuses an existing file, as dfu-util does.
FAKE_DFU_UTIL = textwrap.dedent('''\
    import os, sys
    sys.path.insert(0, {here!r})
    import dfupatch
    unit = os.environ["FAKE_UNIT"]
    args = sys.argv[1:]
    with open(os.path.join(unit, "calls.log"), "a") as log:
        log.write(" ".join(args) + "\\n")
    def opt(flag):
        return args[args.index(flag) + 1] if flag in args else None
    if "-l" in args:
        # Only a chip in update mode is listed (#603): the update-mode stand-in's send puts it there. The second list
        # after a write is the wizard waiting for the power cycle (the first may be the plan's own look before the
        # owner's image): the fake owner power-cycles then, unless the chip is stuck.
        written = os.path.join(unit, "written")
        if os.path.exists(written):
            looks = int(open(written).read() or 0) + 1
            open(written, "w").write(str(looks))
            if looks >= 2 and not os.path.exists(os.path.join(unit, "stuck-in-update-mode")):
                os.remove(written)
                os.remove(os.path.join(unit, "in-update-mode"))
                open(os.path.join(unit, "cycled"), "w").close()
        if os.path.exists(os.path.join(unit, "in-update-mode")):
            sys.stdout.write(open(os.path.join(unit, "listing.txt")).read())
        sys.exit(0)
    fail = open(os.path.join(unit, "fail.txt")).read().split() if os.path.exists(os.path.join(unit, "fail.txt")) else []
    if opt("-U"):
        out = opt("-U")
        address = int(opt("-s").split(":")[0], 0)
        if ("read-" + ("options" if opt("-a") == "1" else "app" if address == {app} else "upper")) in fail:
            sys.exit("dfu-util: fake read failure")
        if os.path.exists(out):
            sys.exit("dfu-util: file exists")
        address, size = (int(x, 0) for x in opt("-s").split(":"))
        if opt("-a") == "1":
            data = open(os.path.join(unit, "options.bin"), "rb").read()[:size]
        else:
            name, base = ("app.bin", {app}) if address == {app} else ("upper.bin", {upper})
            data = open(os.path.join(unit, name), "rb").read()[address - base:address - base + size]
        open(out, "wb").write(data)
        sys.exit(0)
    if opt("-D"):
        image = dfupatch.parse(dfupatch.read(opt("-D")))
        if ("write-" + ("app" if image.address == {app} else "upper")) in fail:
            sys.exit("dfu-util: fake write failure")
        name, base = ("app.bin", {app}) if image.address == {app} else ("upper.bin", {upper})
        path = os.path.join(unit, name)
        memory = bytearray(open(path, "rb").read())
        element = image.element
        cut = "cut-app" in fail and image.address == {app}   # erased, then cut off half way
        if cut:
            memory[image.address - base:image.address - base + len(element)] = bytes([0xFF]) * len(element)
            element = element[:len(element) // 2]
        memory[image.address - base:image.address - base + len(element)] = element
        open(path, "wb").write(bytes(memory))
        if cut:   # the run stops here: no power cycle follows, so the chip stays in update mode
            if os.path.exists(os.path.join(unit, "written")):
                os.remove(os.path.join(unit, "written"))
            sys.exit("dfu-util: fake write cut off")
        open(os.path.join(unit, "written"), "w").close()
        sys.exit(0)
    sys.exit("fake dfu-util: unexpected " + " ".join(args))
    ''')
# The update-mode tool's stand-in, which the fake swiftc "builds": it sends nothing, and logs each call. Its send
# puts the fake chip in update mode; its check finds the display's MIDI port only while the chip isn't (#603), and
# never after the power cycle when $FAKE_UNIT/no-midi is there (a chip that doesn't boot its new app).
FAKE_UPDATE_MODE = textwrap.dedent('''\
    #!/bin/sh
    echo "$@" >> "$FAKE_UNIT/update-mode.log"
    case "$1" in
      send) touch "$FAKE_UNIT/in-update-mode" ;;
      check) [ ! -e "$FAKE_UNIT/in-update-mode" ] || exit 1
             [ -e "$FAKE_UNIT/no-midi" ] && [ -e "$FAKE_UNIT/cycled" ] && exit 1 ;;
    esac
    exit 0
    ''')


class FlashDayRunTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        root = self.dir.name
        self.stubs, self.unit, self.work, self.home = (os.path.join(root, n) for n in ("stubs", "unit", "work", "home"))
        for folder in (self.stubs, self.unit, self.work, self.home):
            os.makedirs(folder)
        self.stub("dfu-util", f"#!{sys.executable} -I\n" + FAKE_DFU_UTIL.format(here=HERE, app=APP, upper=UPPER))
        update_mode = os.path.join(root, "update-mode-stub")
        with open(update_mode, "w") as f:
            f.write(FAKE_UPDATE_MODE)
        self.stub("swiftc", f'#!/bin/sh\nwhile [ "$1" != "-o" ]; do shift; done\ncp "{update_mode}" "$2"\nchmod +x "$2"\n')
        # pgrep -f PATTERN: an app is running while $FAKE_UNIT/running-NAME holds a count above 0 (each look takes
        # one) or "always", NAME being its executable, the pattern's last part.
        self.stub("pgrep", textwrap.dedent('''\
            #!/bin/sh
            f="$FAKE_UNIT/running-$(basename "$2")"
            [ -e "$f" ] || exit 1
            n=$(cat "$f")
            [ "$n" = always ] && exit 0
            [ "$n" -gt 0 ] || exit 1
            echo $((n - 1)) > "$f"
            exit 0
            '''))
        self.stub("python3", f'#!/bin/sh\nexec "{sys.executable}" "$@"\n')
        self.current_element, self.owner_element = full_wd_element(), stock_like_element()
        # The image the chip runs now, where the owner keeps it: the wizard finds it there from the read (#603).
        self.current = os.path.join(self.work, "current.dfu")
        with open(self.current, "wb") as f:
            f.write(dfuse_file(self.current_element))
        self.owner = self.file("owner.dfu", dfuse_file(self.owner_element))
        self.upper = self.file("upper.dfu", build_upper_dfu.dfuse(good_block()))
        self.record = write_record(os.path.join(self.dir.name, "build.json"), self.owner, self.upper)
        self.env = {"PATH": f"{self.stubs}:/usr/bin:/bin", "HOME": self.home, "LC6000_WORK": self.work,
                    "FAKE_UNIT": self.unit, "TERM": "dumb", "LC6000_APP_WAIT": "1",
                    "LC6000_POWER_WAIT": "1"}

    def stub(self, name, text):
        path = os.path.join(self.stubs, name)
        with open(path, "w") as f:
            f.write(text)
        os.chmod(path, 0o755)

    def file(self, name, content):
        path = os.path.join(self.dir.name, name)
        with open(path, "wb") as f:
            f.write(content)
        return path

    def unit_fails(self, *what):
        """The fake dfu-util fails these: read-app, read-upper, read-options, write-upper, write-app, and cut-app (the
        app write erases, writes half, and fails)."""
        with open(os.path.join(self.unit, "fail.txt"), "w") as f:
            f.write(" ".join(what))

    def unit_holds(self, app, upper=None, devices=(("2-1.2", DISPLAY_LAYOUT),), in_update_mode=False):
        for log in ("calls.log", "update-mode.log", "written", "stuck-in-update-mode", "no-midi", "cycled"):   # a fresh unit
            if os.path.exists(os.path.join(self.unit, log)):
                os.remove(os.path.join(self.unit, log))
        flag = os.path.join(self.unit, "in-update-mode")
        if in_update_mode:
            open(flag, "w").close()
        elif os.path.exists(flag):
            os.remove(flag)
        with open(os.path.join(self.unit, "app.bin"), "wb") as f:
            f.write(app)
        with open(os.path.join(self.unit, "upper.bin"), "wb") as f:
            f.write(upper if upper is not None else b"\xff" * 0x80000)
        with open(os.path.join(self.unit, "options.bin"), "wb") as f:
            f.write(OPTIONS_OK)
        with open(os.path.join(self.unit, "listing.txt"), "w") as f:
            for path, layout in devices:
                f.write(f'Found DFU: [0483:df11] ver=2200, devnum=5, cfg=1, intf=0, path="{path}", alt=0, '
                        f'name="{layout}", serial="FFFFFFFEFFFF"\n')

    def assert_isolated(self):
        """Nothing these runs start can reach the real unit: only the stand-ins are on PATH."""
        for tool in ("dfu-util", "swiftc", "pgrep", "python3"):
            self.assertEqual(shutil.which(tool, path=self.env["PATH"]), os.path.join(self.stubs, tool), tool)
        real = shutil.which("dfu-util")
        if real:
            self.assertNotIn(os.path.dirname(real), self.env["PATH"].split(":"))
        self.assertNotEqual(self.env["HOME"], os.path.expanduser("~"))
        self.assertFalse(self.env["LC6000_WORK"].startswith(os.path.expanduser("~/lc6000")))

    def run_wizard(self, answers, entered=True, sent=None, args=(), left=None):
        """LEFT: a list that gets what the run didn't read of its input (a regular file, so bash seeks back to just
        past each line it reads, and the offset left is exactly where reading stopped)."""
        self.assert_isolated()
        text = "\n".join(answers) + "\n"
        with tempfile.TemporaryFile("w+") as stdin:
            stdin.write(text + ("UNREAD\n" if left is not None else ""))
            stdin.flush()
            stdin.seek(0)
            result = subprocess.run(["/bin/bash", WIZARD, "drawn", *args], stdin=stdin, env=self.env,
                                    cwd=self.dir.name, capture_output=True, text=True, timeout=300)
            if left is not None:
                at = os.lseek(stdin.fileno(), 0, os.SEEK_CUR)
                stdin.seek(at)
                left.append(stdin.read())
        # The update-mode tool that ran was the stand-in, never the real one; a run stopped in the ready check never
        # sends the update-mode message at all.
        with open(os.path.join(self.unit, "update-mode.log")) as f:
            calls = f.read().splitlines()
        self.assertIn("selftest", calls)
        sends = calls.count("send --yes-enter-update-mode")
        self.assertEqual(sends, (1 if entered else 0) if sent is None else sent)
        return result

    def memory(self, name):
        with open(os.path.join(self.unit, name), "rb") as f:
            return f.read()

    def calls(self):
        """Every dfu-util call the run made; none when it never ran."""
        log = os.path.join(self.unit, "calls.log")
        if not os.path.exists(log):
            return []
        with open(log) as f:
            return f.read().splitlines()

    def downloads(self):
        return [line for line in self.calls() if " -D " in f" {line} "]

    def test_a_fresh_flash_writes_b_and_the_owners_image(self):
        self.unit_holds(self.current_element)
        answers = [self.upper, self.owner,                      # the two paths: nothing beside them to find
                   self.record,                                 # the build record
                   "UPDATE",                                    # send the update-mode message
                   "y",                                         # the probe, up front: the image will be written
                   "FLASH",                                     # block B
                   "FLASH"]                                     # the owner's image
        result = self.run_wizard(answers)
        self.assertEqual(result.returncode, 0, result.stdout[-3000:] + result.stderr[-2000:])
        self.assertEqual(len(self.downloads()), 2)
        block = good_block()
        self.assertEqual(self.memory("upper.bin")[:len(block)], block)
        self.assertEqual(self.memory("app.bin"), self.owner_element)

    def test_a_chip_already_in_update_mode_is_flashed_with_no_update_mode_message(self):
        # A re-run after a stop that left the chip in update mode (#603): the display's MIDI port is gone, so the
        # port check would fail. The wizard sees the DFU device instead, says so, and sends nothing.
        self.unit_holds(self.current_element, in_update_mode=True)
        answers = [self.upper, self.owner, self.record, "y", "FLASH", "FLASH"]
        result = self.run_wizard(answers, sent=0)
        self.assertEqual(result.returncode, 0, result.stdout[-3000:] + result.stderr[-2000:])
        self.assertIn("already in update mode", result.stdout)
        self.assertEqual(len(self.downloads()), 2)

    def test_a_b_only_rewrite_leaves_the_app_area_alone(self):
        old_b = bytes.fromhex("44465742" "02000000" "1d000000" "72dfb522" "15000808") + b"123456789"
        self.unit_holds(self.owner_element, upper=old_b + b"\xff" * (0x80000 - len(old_b)))
        answers = [self.upper, self.owner, self.record, "UPDATE", "REWRITE"]
        result = self.run_wizard(answers)
        self.assertEqual(result.returncode, 0, result.stdout[-3000:] + result.stderr[-2000:])
        self.assertEqual(len(self.downloads()), 1)
        self.assertIn("wd-upper-rewrite", self.downloads()[0])
        self.assertEqual(self.memory("app.bin"), self.owner_element)
        block = good_block()
        self.assertEqual(self.memory("upper.bin")[:len(block)], block)

    def app_running(self, looks, executable="MacOS"):
        """DeckBridge's pattern ends in its MacOS folder; the others name their executable."""
        with open(os.path.join(self.unit, f"running-{executable}"), "w") as f:
            f.write(str(looks))

    def test_every_app_that_opens_the_unit_is_waited_for_and_refuses(self):
        # #603: they replace the ready question's y/N. Syndicate isn't one: DeckBridge sits between it and the unit.
        for executable, name in (("djay Pro", "djay Pro"), ("Engine DJ", "Engine DJ"),
                                 ("FirmwareUpdater", "Denon's updater")):
            with self.subTest(name):
                self.unit_holds(self.current_element)
                for f in os.listdir(self.unit):
                    if f.startswith("running-"):
                        os.remove(os.path.join(self.unit, f))
                self.app_running("always", executable)
                result = self.run_wizard(self.answers(), entered=False)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(f"{name} is still running", result.stdout)
                self.assertEqual(self.calls(), [])

    def test_syndicate_open_is_no_stop(self):
        self.unit_holds(self.current_element)
        self.app_running("always", "Syndicate")
        result = self.run_wizard(self.answers())
        self.assertEqual(result.returncode, 0, result.stdout[-3000:] + result.stderr[-2000:])

    def test_the_ready_checklist_is_printed_not_asked(self):
        self.unit_holds(self.current_element)
        result = self.run_wizard(self.answers())
        self.assertNotIn("All of that true?", result.stdout)
        self.assertIn("direct cable", result.stdout)

    def test_deckbridge_quit_while_the_wizard_waits_needs_no_key(self):
        # #603: the wizard waits for DeckBridge to quit, so no Enter is asked for.
        self.unit_holds(self.current_element)
        self.app_running(2)
        result = self.run_wizard(self.answers())
        self.assertEqual(result.returncode, 0, result.stdout[-3000:] + result.stderr[-2000:])
        self.assertIn("Waiting for DeckBridge to quit", result.stdout)
        self.assertEqual(len(self.downloads()), 2)

    def test_deckbridge_still_running_refuses_before_anything_is_sent(self):
        # Today's pause went on after Enter whether DeckBridge had quit or not (#603).
        self.unit_holds(self.current_element)
        self.app_running("always")
        result = self.run_wizard(self.answers(), entered=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("DeckBridge is still running", result.stdout)
        self.assertEqual(self.calls(), [])

    def test_the_update_mode_message_needs_the_typed_word(self):
        # #603: a typed word, not y/N, before the one send to the unit. y is not the word.
        for answer in ("y", "update", ""):
            with self.subTest(answer):
                self.unit_holds(self.current_element)
                result = self.run_wizard([self.upper, self.owner, self.record, answer],
                                         entered=False)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Type UPDATE", result.stdout)
                self.assertEqual([c for c in self.calls() if c != "-l"], [], "only listed: no read, no write")

    def test_the_probe_answer_is_kept_for_the_day_and_probe_again_forgets_it(self):
        self.unit_holds(self.current_element)
        self.assertEqual(self.run_wizard(self.answers()).returncode, 0)
        # The same day and unit: no probe question, and its line is on the image's word screen.
        self.unit_holds(self.current_element)
        result = self.run_wizard([self.upper, self.owner, self.record, "UPDATE", "FLASH", "FLASH"])
        self.assertEqual(result.returncode, 0, result.stdout[-3000:] + result.stderr[-2000:])
        self.assertNotIn("Is an ST-Link probe connected", result.stdout)
        self.assertIn("probe: yes (answered today at ", result.stdout)
        # --probe-again: asked once more.
        self.unit_holds(self.current_element)
        result = self.run_wizard(self.answers(), args=("--probe-again",))
        self.assertEqual(result.returncode, 0, result.stdout[-3000:] + result.stderr[-2000:])
        self.assertIn("Is an ST-Link probe connected", result.stdout)

    def test_each_write_word_screen_reaches_the_owner_with_the_file_and_its_hash(self):
        import hashlib
        self.unit_holds(self.current_element)
        result = self.run_wizard(self.answers())
        self.assertEqual(result.returncode, 0, result.stdout[-3000:] + result.stderr[-2000:])
        for path in (self.upper, self.owner):
            with open(path, "rb") as f:
                self.assertIn(f"▶ sha256: {hashlib.sha256(f.read()).hexdigest()}", result.stdout)
        self.assertIn("▶ probe: yes (answered today at ", result.stdout)

    def test_the_power_cycle_is_seen_on_usb_with_no_key(self):
        self.unit_holds(self.current_element)
        result = self.run_wizard(self.answers())
        self.assertEqual(result.returncode, 0, result.stdout[-3000:] + result.stderr[-2000:])
        self.assertNotIn("Press Enter once it's back on", result.stdout)
        self.assertIn("left update mode", result.stdout)
        self.assertIn("its MIDI port is back", result.stdout)

    def test_a_chip_that_never_leaves_update_mode_is_no_success(self):
        self.unit_holds(self.current_element)
        open(os.path.join(self.unit, "stuck-in-update-mode"), "w").close()
        result = self.run_wizard(self.answers())
        self.assert_stopped_with_the_way_back(result, "still in update mode after 1 s")
        self.assertIn("Check: was the power switched off", result.stdout)
        self.assertNotIn("booted", result.stdout)

    def test_a_chip_whose_midi_port_never_comes_back_is_no_success(self):
        self.unit_holds(self.current_element)
        open(os.path.join(self.unit, "no-midi"), "w").close()
        result = self.run_wizard(self.answers())
        self.assert_stopped_with_the_way_back(result, "MIDI port didn't come back in 1 s")
        self.assertIn("Check:", result.stdout)
        self.assertNotIn("booted", result.stdout)

    def test_the_run_ends_with_the_stock_look_printed_and_no_pause(self):
        self.unit_holds(self.current_element)
        result = self.run_wizard(self.answers())
        self.assertEqual(result.returncode, 0, result.stdout[-3000:] + result.stderr[-2000:])
        self.assertNotIn("does the display look exactly like stock?", result.stdout)
        self.assertIn("should look exactly like stock", result.stdout)
        self.assertNotIn("Ready to start?", result.stdout)
        self.assertNotIn("Press Enter", result.stdout)

    def test_a_wrong_word_writes_nothing(self):
        self.unit_holds(self.current_element)
        result = self.run_wizard([self.upper, self.owner, self.record, "UPDATE", "flash"])
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.downloads(), [])
        self.assertEqual(self.memory("app.bin"), self.current_element)


    FRESH = ["{upper}", "{owner}", "{record}", "UPDATE", "y", "FLASH", "FLASH"]

    def answers(self):
        return [a.format(current=self.current, upper=self.upper, owner=self.owner, record=self.record)
                for a in self.FRESH]

    def assert_stopped_with_the_way_back(self, result, reason):
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(reason, result.stdout)
        self.assertIn("The way back to stock firmware", result.stdout)

    def test_a_failed_write_of_b_says_so_and_the_way_back_and_never_writes_the_image(self):
        # set -e must not end the wizard silently inside the write's pipeline (#567).
        self.unit_holds(self.current_element)
        self.unit_fails("write-upper")
        result = self.run_wizard(self.answers())
        self.assert_stopped_with_the_way_back(result, "dfu-util reported an error writing block B")
        self.assertEqual(self.memory("app.bin"), self.current_element)

    def test_a_failed_write_of_the_image_says_dont_power_cycle(self):
        self.unit_holds(self.current_element)
        self.unit_fails("write-app")
        result = self.run_wizard(self.answers())
        self.assert_stopped_with_the_way_back(result, "Don't power-cycle")

    def test_a_failed_read_says_so_and_the_way_back(self):
        for what in ("read-app", "read-options", "read-upper"):
            with self.subTest(what):
                self.unit_holds(self.current_element)
                self.unit_fails(what)
                result = self.run_wizard(self.answers())
                self.assert_stopped_with_the_way_back(result, "couldn't be read")
                self.assertEqual(self.downloads(), [])


    def test_built_by_the_kit_the_record_is_found_and_never_asked_for(self):
        # make arm's folder, then the two kit tools into the owner's folder, as the README says (#593).
        arm, kit = os.path.join(self.dir.name, "arm"), os.path.join(self.dir.name, "lc6000")
        os.makedirs(arm), os.makedirs(kit)
        block, upper = os.path.join(arm, "block.bin"), os.path.join(arm, "upper.bin")
        with open(block, "wb") as f:
            f.write(synthetic_block())
        with open(upper, "wb") as f:
            f.write(good_block())
        with open(os.path.join(arm, "build.json"), "w") as f:
            json.dump(build_record.record_of(synthetic_block(), good_block(), "1", "1"), f)
        stock, proof = self.file("stock.dfu", dfuse_file(self.owner_element)), self.file("proof.bin", b"\xff" * 0x80000)
        self.upper, self.owner = os.path.join(kit, "wd-upper-drawing.dfu"), os.path.join(kit, "wd-owner.dfu")
        for tool, argv in ((build_upper_dfu, [upper, self.upper, "--proof", proof]),
                           (build_owner_image, [stock, block, self.owner, "--no-show-slot-16"])):
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(tool.main(argv), 0)
        self.unit_holds(self.current_element)
        answers = [self.upper, self.owner,   # no record path: it's found
                   "UPDATE", "y", "FLASH", "FLASH"]
        result = self.run_wizard(answers)
        self.assertEqual(result.returncode, 0, result.stdout[-3000:] + result.stderr[-2000:])
        self.assertIn("Build record: " + os.path.join(kit, "wd-upper-drawing.build.json"), result.stdout)
        self.assertEqual(len(self.downloads()), 2)
        self.assertEqual(self.memory("upper.bin")[:len(good_block())], good_block())


    def kit_pair_in(self, folder):
        """Block B and the owner's image as the kit tools leave them in FOLDER, each with the build record beside it."""
        os.makedirs(folder, exist_ok=True)
        upper, owner = os.path.join(folder, "wd-upper-drawing.dfu"), os.path.join(folder, "wd-owner.dfu")
        shutil.copy(self.upper, upper)
        shutil.copy(self.owner, owner)
        for dfu in (upper, owner):
            shutil.copy(self.record, build_record.carried(dfu))
        return upper, owner

    def test_the_kits_pair_in_the_work_folder_is_used_and_never_asked_for(self):
        # #603: only the image on the chip now is asked for; B, the owner's image and the record are found.
        self.upper, self.owner = self.kit_pair_in(self.work)
        self.unit_holds(self.current_element)
        result = self.run_wizard(["UPDATE", "y", "FLASH", "FLASH"])
        self.assertEqual(result.returncode, 0, result.stdout[-3000:] + result.stderr[-2000:])
        self.assertIn("Block B: " + self.upper, result.stdout)
        self.assertIn("The owner's image: " + self.owner, result.stdout)
        self.assertEqual(len(self.downloads()), 2)

    def test_the_remembered_pair_is_used_when_its_record_is_beside_it(self):
        self.upper, self.owner = self.kit_pair_in(os.path.join(self.dir.name, "built"))
        with open(os.path.join(self.work, "flash-day.env"), "w") as f:
            f.write(f"UPPER_DFU='{self.upper}'\nOWNER_DFU='{self.owner}'\n")
        self.unit_holds(self.current_element)
        result = self.run_wizard(["UPDATE", "y", "FLASH", "FLASH"])
        self.assertEqual(result.returncode, 0, result.stdout[-3000:] + result.stderr[-2000:])
        self.assertIn("Block B: " + self.upper, result.stdout)

    def test_the_image_on_the_chip_is_found_from_the_read_and_never_asked_for(self):
        self.unit_holds(self.current_element)
        result = self.run_wizard(self.answers())
        self.assertEqual(result.returncode, 0, result.stdout[-3000:] + result.stderr[-2000:])
        self.assertIn(f"The chip runs {self.current} now", result.stdout)
        self.assertNotIn("Path to the .dfu the chip runs now", result.stdout)

    def test_an_image_on_the_chip_that_matches_no_file_refuses_before_any_write(self):
        other = bytearray(self.current_element)
        other[0x100] ^= 1
        self.unit_holds(bytes(other))
        result = self.run_wizard(self.answers())
        self.assert_stopped_with_the_way_back(result, "matches none of the images")
        self.assertEqual(self.downloads(), [])

    def test_current_names_a_file_kept_elsewhere(self):
        elsewhere = self.file("slot16.dfu", dfuse_file(self.current_element))
        os.remove(self.current)
        self.unit_holds(self.current_element)
        result = self.run_wizard(self.answers(), args=("--current", elsewhere))
        self.assertEqual(result.returncode, 0, result.stdout[-3000:] + result.stderr[-2000:])
        self.assertEqual(len(self.downloads()), 2)

    OLD_B = bytes.fromhex("44465742" "02000000" "1d000000" "72dfb522" "15000808") + b"123456789"

    def pinned(self, answers, app, upper=None, in_update_mode=False, args=()):
        """A run with the kit's pair in the work folder (#603): exactly ANSWERS, each one a stop the output shows as
        a "?" prompt, and none left over. Returns the run."""
        if os.path.dirname(self.upper) != self.work:
            self.upper, self.owner = self.kit_pair_in(self.work)
        self.unit_holds(app, upper=upper, in_update_mode=in_update_mode)
        left = []
        result = self.run_wizard(answers, sent=0 if in_update_mode else 1, args=args, left=left)
        self.assertEqual(result.returncode, 0, result.stdout[-3000:] + result.stderr[-2000:])
        # Every read of the keyboard took exactly one answer, pauses included: only the line after them is left.
        self.assertEqual(left, ["UNREAD\n"])
        self.assertEqual(result.stdout.count("  ? "), len(answers), result.stdout)
        return result

    def old_b(self):
        return self.OLD_B + b"\xff" * (0x80000 - len(self.OLD_B))

    def test_stops_first_flash(self):
        self.pinned(["UPDATE", "y", "FLASH", "FLASH"], self.current_element)

    def test_stops_first_flash_without_a_probe_then_again_the_same_day(self):
        self.pinned(["UPDATE", "n", "NO PROBE", "FLASH", "FLASH"], self.current_element)
        self.pinned(["UPDATE", "FLASH", "FLASH"], self.current_element)

    def test_stops_b_only_rewrite(self):
        self.pinned(["UPDATE", "REWRITE"], self.owner_element, upper=self.old_b())

    def test_stops_b_only_rewrite_with_the_chip_already_in_update_mode(self):
        # The ticket's case: one typed word and nothing else.
        self.pinned(["REWRITE"], self.owner_element, upper=self.old_b(), in_update_mode=True)

    def test_stops_two_block_rewrite(self):
        self.pinned(["UPDATE", "y", "REWRITE", "FLASH"], self.current_element, upper=self.old_b())

    def test_upper_and_owner_name_the_pair_over_the_newest_build(self):
        chosen_upper, chosen_owner = self.kit_pair_in(os.path.join(self.dir.name, "chosen"))
        self.kit_pair_in(self.work)
        self.unit_holds(self.current_element)
        result = self.run_wizard(["UPDATE", "y", "FLASH", "FLASH"],
                                 args=("--upper", chosen_upper, "--owner", chosen_owner))
        self.assertEqual(result.returncode, 0, result.stdout[-3000:] + result.stderr[-2000:])
        self.assertIn("Block B: " + chosen_upper + " (--upper)", result.stdout)
        self.assertIn("▶ file: " + chosen_owner, result.stdout)

    def test_upper_without_owner_is_refused_before_anything(self):
        self.assert_isolated()
        result = subprocess.run(["/bin/bash", WIZARD, "drawn", "--upper", self.upper], input="", env=self.env,
                                cwd=self.dir.name, capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, 2)
        self.assertIn("--upper and --owner go together", result.stdout)
        self.assertEqual(self.calls(), [])

    def test_a_rerun_after_an_interrupted_image_write_finishes_that_same_write(self):
        # The coordinator's call (#603): the chip sits in update mode with a half-written app area, which matches no
        # file. The wizard's own record of the write it started lets a re-run offer exactly that write again.
        self.upper, self.owner = self.kit_pair_in(self.work)
        self.unit_holds(self.current_element)
        self.unit_fails("cut-app")
        result = self.run_wizard(["UPDATE", "y", "FLASH", "FLASH"])
        self.assert_stopped_with_the_way_back(result, "dfu-util reported an error writing the owner's image")
        self.assertNotEqual(self.memory("app.bin"), self.owner_element)
        for name in ("fail.txt", "update-mode.log", "calls.log"):   # the same unit, still in update mode
            os.remove(os.path.join(self.unit, name))
        left = []
        result = self.run_wizard(["FLASH"], sent=0, left=left)   # still in update mode; B there; probe kept
        self.assertEqual(result.returncode, 0, result.stdout[-3000:] + result.stderr[-2000:])
        self.assertEqual(left, ["UNREAD\n"])
        self.assertIn("FINISHING AN INTERRUPTED WRITE", result.stdout)
        self.assertEqual(self.memory("app.bin"), self.owner_element)
        self.assertFalse(os.path.exists(os.path.join(self.work, "app-write.json")), "cleared once verified")

    def test_an_interrupted_write_of_another_image_still_refuses(self):
        self.upper, self.owner = self.kit_pair_in(self.work)
        self.unit_holds(self.current_element)
        self.unit_fails("cut-app")
        self.run_wizard(["UPDATE", "y", "FLASH", "FLASH"])
        for name in ("fail.txt", "update-mode.log", "calls.log"):   # the same unit, still in update mode
            os.remove(os.path.join(self.unit, name))
        record = os.path.join(self.work, "app-write.json")   # a write of another build's image was cut
        with open(record) as f:
            kept = json.load(f)
        kept["sha256"] = "0" * 64
        with open(record, "w") as f:
            json.dump(kept, f)
        result = self.run_wizard(["FLASH"], sent=0)
        self.assert_stopped_with_the_way_back(result, "interrupted write")
        self.assertEqual(len(self.downloads()), 0)

    def refused_by_the_record(self, record, *reasons):
        self.unit_holds(self.current_element)
        result = self.run_wizard([self.upper, self.owner, record, "UPDATE", "y", "FLASH", "FLASH"],
                                 entered=False)
        self.assertNotEqual(result.returncode, 0)
        for reason in ("Nothing was sent", *reasons):
            self.assertIn(reason, result.stdout)
        self.assertEqual(self.calls(), [], "dfu-util never runs: the record stops the ready check")
        self.assertEqual(self.memory("app.bin"), self.current_element)
        self.assertEqual(set(self.memory("upper.bin")), {0xFF})

    def other_record(self, name, a=None, b=None, proven="1"):
        """A record as make arm writes it, for these blocks (by default the ones in the owner's files)."""
        start = dfupatch.PAD_START - APP
        a = a if a is not None else self.owner_element[start:start + dfupatch.PAD_END - dfupatch.PAD_START]
        with open(os.path.join(self.dir.name, name), "w") as f:
            json.dump(build_record.record_of(a, b if b is not None else good_block(), "1", proven), f)
        return os.path.join(self.dir.name, name)

    def test_no_record_stops_in_the_ready_check(self):
        self.refused_by_the_record(os.path.join(self.dir.name, "nowhere.json"), "no build record")

    def test_files_from_another_build_stop_and_say_which_to_rebuild(self):
        other_a = synthetic_block()
        self.refused_by_the_record(self.other_record("other-a.json", a=other_a),
                                   "block A in the owner's image", "Rebuild the owner's image")
        other_b = build_upper_dfu.upper_header.build(b"another build", 0x1A2B3C4D, 0x0808001D, 0x0808001F)
        self.refused_by_the_record(self.other_record("other-b.json", b=other_b), "block B in " + self.upper)

    def test_a_block_built_without_the_proof_switch_stops(self):
        self.refused_by_the_record(self.other_record("unproven.json", proven="0"), "ARM_UPPER_PROVEN=0")


if __name__ == "__main__":
    unittest.main()
