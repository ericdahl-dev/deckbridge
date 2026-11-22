"""The drawn wizard's plan (#567): the facts so far in, the next step out. A fake unit plays the shell's part (dfu-util,
the keyboard), so whole runs are tested with no hardware. Nothing here talks to a unit.
Run from the repo root: python3 -I -m unittest discover tools/lc6000-firmware"""
import json, os, tempfile, unittest

import build_record
import build_upper_dfu
import dfupatch
import drawn_flash
import drawn_plan
from test_build_owner_image import stock_like_element
from test_build_upper_dfu import good_block
from test_dfupatch import dfuse_file, full_wd_element

UPPER, UPPER_SIZE, APP_SIZE = 0x08080000, 0x80000, 0x78000
DISPLAY_LAYOUT = "@Internal Flash  /0x08000000/04*016Kg,01*064Kg,07*128Kg"
TOP_PANEL_LAYOUT = "@Internal Flash  /0x08000000/04*016Kg,01*064Kg,01*128Kg"
# The option bytes as read (RM0090: RDP 0xAA at +1; nWRP, DB1M and SPRMOD in the half-word at +8).
OPTIONS_OK = bytes([0xEC, 0xAA]) + b"\xff" * 6 + bytes([0xFF, 0x0F]) + b"\xff" * 6


def write_record(path, owner, upper, draw="1", proven="1"):
    """The build record `make arm` would have written for the block A inside OWNER and the block B inside UPPER."""
    start = dfupatch.PAD_START - drawn_flash.APP_BASE
    a = drawn_flash.owner_image(owner)[start:start + dfupatch.PAD_END - dfupatch.PAD_START]
    with open(path, "w") as f:
        json.dump(build_record.record_of(a, drawn_flash.upper_block(upper), draw, proven), f)
    return path


def listing(*devices):
    """dfu-util -l's lines for each (path, alt 0 layout)."""
    return "".join(f'Found DFU: [0483:df11] ver=2200, devnum=5, cfg=1, intf=0, path="{path}", alt=0, name="{layout}", '
                   f'serial="FFFFFFFEFFFF"\n' for path, layout in devices)


class FakeUnit:
    """The display chip in update mode, and the owner at the keyboard: runs each action the plan asks for."""

    def __init__(self, folder, app, upper=None, options=OPTIONS_OK, devices=(("2-1.2", DISPLAY_LAYOUT),),
                 answers=None, words=None, cut_upper_write_at=None, cut_reports_ok=False, failing_reads=()):
        self.folder = folder
        self.app = bytearray(app)
        self.upper = bytearray(upper if upper is not None else b"\xff" * UPPER_SIZE)
        self.options = options
        self.devices = devices
        self.answers = {"probe": "y", **(answers or {})}
        self.words = words or {}
        self.cut_upper_write_at = cut_upper_write_at
        self.cut_reports_ok = cut_reports_ok
        self.failing_reads = failing_reads
        self.log = []
        self.writes = []

    def run(self, plan_path, limit=60):
        for _ in range(limit):
            action = drawn_plan.next_action(plan_path)
            self.log.append(action)
            kind = action[0]
            if kind in ("done", "stop"):
                return action
            self.act(plan_path, action)
        raise AssertionError(f"no end after {limit} steps: {self.log}")

    def file(self, name):
        return os.path.join(self.folder, name)

    def act(self, plan_path, action):
        kind = action[0]
        record = lambda key, value: drawn_plan.record(plan_path, key, value)
        if kind == "ask":
            record(action[1], self.answers.get(action[1], "y"))
        elif kind == "type":
            record(action[1], self.words.get(action[1], action[2]))
        elif kind == "update-mode":
            record("update_mode", "ok")
        elif kind == "list":
            with open(action[1], "w") as f:
                f.write(listing(*self.devices))
            record(action[2], action[1])
        elif kind == "read":
            area, path, out = action[1], action[2], action[3]
            if action[4] in self.failing_reads:
                record(action[4], "failed")   # dfu-util -U refused, as the shell records it
                return
            data = {"app": self.app, "upper": self.upper, "options": self.options}[area]
            with open(out, "wb") as f:
                f.write(bytes(data))
            record(action[4], out)
        elif kind == "write":
            area, path, image = action[1], action[2], action[3]
            element = dfupatch.parse(dfupatch.read(image)).element
            self.writes.append(area)
            if area == "upper":
                if self.cut_upper_write_at is not None:
                    element = element[:self.cut_upper_write_at]
                self.upper[:len(element)] = element
            else:
                self.app[:len(element)] = element
            failed = area == "upper" and self.cut_upper_write_at is not None and not self.cut_reports_ok
            record(action[4], "1" if failed else "0")
        elif kind == "power-cycle":
            record("power_cycle", "ok")
        elif kind == "skip":
            record(action[1], "seen")
        else:
            raise AssertionError(f"unknown action {action}")


class DrawnPlanTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.current_element = full_wd_element()
        self.owner_element = stock_like_element()
        self.current = self.write("current.dfu", dfuse_file(self.current_element))
        self.owner = self.write("owner.dfu", dfuse_file(self.owner_element))
        self.upper = self.write("upper.dfu", build_upper_dfu.dfuse(good_block()))
        self.record = write_record(os.path.join(self.dir.name, "build.json"), self.owner, self.upper)

    def write(self, name, content):
        path = os.path.join(self.dir.name, name)
        with open(path, "wb") as f:
            f.write(content)
        return path

    def plan(self):
        path = os.path.join(self.dir.name, "plan.json")
        drawn_plan.begin(path, current=self.current, upper=self.upper, owner=self.owner, record=self.record,
                         work=self.dir.name)
        return path

    def kinds(self, unit):
        return [a[0] if a[0] not in ("read", "write", "ask", "type", "skip") else f"{a[0]} {a[1]}" for a in unit.log]


class FreshFlashTests(DrawnPlanTests):
    def test_a_fresh_flash_writes_b_then_the_image_each_behind_flash_and_reads_each_back(self):
        unit = FakeUnit(self.dir.name, self.current_element)
        end = unit.run(self.plan())
        self.assertEqual(end, ("done",))
        self.assertEqual(self.kinds(unit), [
            "update-mode", "list",
            "read app", "read options", "read upper", "ask probe",
            "type word_upper", "write upper", "read upper",
            "list", "type word_app", "write app", "read app",
            "power-cycle", "done"])
        words = [a for a in unit.log if a[0] == "type"]
        self.assertEqual([(w[1], w[2]) for w in words], [("word_upper", "FLASH"), ("word_app", "FLASH")])
        self.assertEqual(unit.writes, ["upper", "app"])
        block = good_block()
        self.assertEqual(bytes(unit.upper[:len(block)]), block)
        self.assertEqual(set(unit.upper[len(block):]), {0xFF})
        self.assertEqual(bytes(unit.app), self.owner_element)
        # Every dfu-util action names the one device's path.
        self.assertTrue(all(a[2] == "2-1.2" for a in unit.log if a[0] in ("read", "write")))




class RewriteTests(DrawnPlanTests):
    # #501's first B: version 2, the 20-byte header, CRC from Python's zlib (as test_drawn_flash): an older good B.
    OLD_B = bytes.fromhex("44465742" "02000000" "1d000000" "72dfb522" "15000808") + b"123456789"

    def test_a_b_only_rewrite_writes_b_behind_rewrite_and_leaves_the_app_area_alone(self):
        # The chip runs the owner's image already, so it's both "runs now" and "the owner's image" (#560).
        self.current = self.owner
        upper = self.OLD_B + b"\xff" * (UPPER_SIZE - len(self.OLD_B))
        unit = FakeUnit(self.dir.name, self.owner_element, upper=upper)
        self.assertEqual(unit.run(self.plan()), ("done",))
        kinds = self.kinds(unit)
        self.assertEqual(kinds[kinds.index("read upper"):], [
            "read upper", "type word_upper", "write upper", "read upper", "skip app_step",
            "power-cycle", "done"])
        self.assertEqual([(a[1], a[2]) for a in unit.log if a[0] == "type"], [("word_upper", "REWRITE")])
        self.assertEqual(unit.writes, ["upper"])
        self.assertEqual(bytes(unit.app), self.owner_element)
        block = good_block()
        self.assertEqual(bytes(unit.upper[:len(block)]), block)
        self.assertEqual(set(unit.upper[len(block):]), {0xFF})

    def test_b_already_there_and_the_image_too_writes_nothing(self):
        self.current = self.owner
        block = good_block()
        unit = FakeUnit(self.dir.name, self.owner_element, upper=block + b"\xff" * (UPPER_SIZE - len(block)))
        self.assertEqual(unit.run(self.plan()), ("done",))
        self.assertEqual(unit.writes, [])
        self.assertIn("skip upper_step", self.kinds(unit))
        self.assertIn("skip app_step", self.kinds(unit))



class WordScreenTests(DrawnPlanTests):
    """Each write's typed word is shown with exactly what goes where (#603): the file, its sha256, the address range,
    what's there now, and the checks only the owner can make."""

    def screens(self, unit):
        return {a[1]: a[3] for a in unit.log if a[0] == "type"}

    def sha256(self, path):
        import hashlib
        with open(path, "rb") as f:
            return hashlib.sha256(f.read()).hexdigest()

    def test_a_fresh_flash_shows_each_file_its_hash_its_range_and_whats_there(self):
        unit = FakeUnit(self.dir.name, self.current_element)
        self.assertEqual(unit.run(self.plan()), ("done",))
        upper, app = self.screens(unit)["word_upper"], self.screens(unit)["word_app"]
        end = UPPER + len(good_block()) - 1
        for text, path in ((upper, self.upper), (app, self.owner)):
            self.assertIn(f"▶ file: {path}", text)
            self.assertIn(f"▶ sha256: {self.sha256(path)}", text)
            self.assertIn("direct cable", text)
        self.assertIn(f"0x08080000-0x{end:08X}", upper)
        self.assertIn("there now: erased", upper)
        self.assertIn("0x08008000-0x0807FFFF", app)
        self.assertIn(f"there now: {self.current}", app)

    def stamp(self, path, commit, built):
        with open(path) as f:
            record = json.load(f)
        record.update(commit=commit, built=built)
        with open(path, "w") as f:
            json.dump(record, f)
        return path

    def test_each_screen_shows_the_builds_commit_and_time_and_last_runs_when_it_differs(self):
        import time
        self.stamp(self.record, "abc123def456", 1700000000)
        last = self.stamp(write_record(os.path.join(self.dir.name, "last.json"), self.owner, self.upper),
                          "0ld0ld0ld0ld", 1600000000)
        path = os.path.join(self.dir.name, "plan.json")
        drawn_plan.begin(path, current=self.current, upper=self.upper, owner=self.owner, record=self.record,
                         work=self.dir.name, last_record=last)
        unit = FakeUnit(self.dir.name, self.current_element)
        self.assertEqual(unit.run(path), ("done",))
        built = time.strftime("%Y-%m-%d %H:%M", time.localtime(1700000000))
        for text in self.screens(unit).values():
            self.assertIn(f"▶ build: abc123def456, built {built}", text)
            self.assertIn("▶ last run used: 0ld0ld0ld0ld", text)

    def test_last_run_is_not_shown_when_its_the_same_build(self):
        unit = FakeUnit(self.dir.name, self.current_element)
        self.assertEqual(unit.run(self.plan()), ("done",))
        for text in self.screens(unit).values():
            self.assertIn("▶ build: commit unknown", text)
            self.assertNotIn("last run used", text)

    def test_a_rewrite_shows_the_rewrite_file_that_is_written(self):
        self.current = self.owner
        old = RewriteTests.OLD_B + b"\xff" * (UPPER_SIZE - len(RewriteTests.OLD_B))
        unit = FakeUnit(self.dir.name, self.owner_element, upper=old)
        self.assertEqual(unit.run(self.plan()), ("done",))
        written = [a[3] for a in unit.log if a[:2] == ("write", "upper")][0]
        text = self.screens(unit)["word_upper"]
        self.assertIn(f"▶ file: {written}", text)
        self.assertIn(f"▶ sha256: {self.sha256(written)}", text)
        self.assertIn("there now: another block B", text)


class ProbeTests(DrawnPlanTests):
    """The probe question (#603): asked only when the owner's image is written, and remembered for the day and the
    unit (the DFU serial) in the work folder, shown on the image's word screen."""

    def b_only(self):
        self.current = self.owner
        upper = RewriteTests.OLD_B + b"\xff" * (UPPER_SIZE - len(RewriteTests.OLD_B))
        return FakeUnit(self.dir.name, self.owner_element, upper=upper)

    def word_app_text(self, unit):
        return [a[3] for a in unit.log if a[:2] == ("type", "word_app")][0]

    def remembered(self):
        with open(os.path.join(self.dir.name, "probe.json")) as f:
            return json.load(f)

    def test_a_b_only_rewrite_never_asks(self):
        unit = self.b_only()
        self.assertEqual(unit.run(self.plan()), ("done",))
        self.assertNotIn("probe", [a[1] for a in unit.log if a[0] in ("ask", "type")])

    def test_a_yes_is_remembered_and_shown_and_not_asked_again_today(self):
        unit = FakeUnit(self.dir.name, self.current_element)
        self.assertEqual(unit.run(self.plan()), ("done",))
        self.assertEqual(self.remembered()["serial"], "FFFFFFFEFFFF")
        self.assertEqual(self.remembered()["answer"], "yes")
        self.assertIn("probe: yes (answered today at ", self.word_app_text(unit))
        again = FakeUnit(self.dir.name, self.current_element)
        self.assertEqual(again.run(self.plan()), ("done",))
        self.assertNotIn("probe", [a[1] for a in again.log if a[0] == "ask"])
        self.assertIn("probe: yes (answered today at ", self.word_app_text(again))

    def test_no_probe_is_remembered_with_its_phrase(self):
        unit = FakeUnit(self.dir.name, self.current_element, answers={"probe": "n"})
        self.assertEqual(unit.run(self.plan()), ("done",))
        self.assertEqual(self.remembered()["answer"], "no probe")
        again = FakeUnit(self.dir.name, self.current_element)
        self.assertEqual(again.run(self.plan()), ("done",))
        self.assertEqual([a[1] for a in again.log if a[0] in ("ask", "type") and "probe" in a[1]], [])
        self.assertIn("probe: NO, NO PROBE typed today at ", self.word_app_text(again))

    def test_a_wrong_phrase_isnt_remembered(self):
        unit = FakeUnit(self.dir.name, self.current_element, answers={"probe": "n"}, words={"no_probe": "no"})
        self.assertEqual(unit.run(self.plan())[0], "stop")
        self.assertFalse(os.path.exists(os.path.join(self.dir.name, "probe.json")))

    def test_another_day_or_another_unit_asks_again(self):
        for field, value in (("date", "2001-01-01"), ("serial", "123456789ABC")):
            with self.subTest(field):
                FakeUnit(self.dir.name, self.current_element).run(self.plan())
                remembered = self.remembered()
                remembered[field] = value
                with open(os.path.join(self.dir.name, "probe.json"), "w") as f:
                    json.dump(remembered, f)
                again = FakeUnit(self.dir.name, self.current_element)
                again.run(self.plan())
                self.assertIn("probe", [a[1] for a in again.log if a[0] == "ask"])

    def test_an_unreadable_remembered_answer_is_asked_again(self):
        with open(os.path.join(self.dir.name, "probe.json"), "w") as f:
            f.write("{not json")
        unit = FakeUnit(self.dir.name, self.current_element)
        self.assertEqual(unit.run(self.plan()), ("done",))
        self.assertIn("probe", [a[1] for a in unit.log if a[0] == "ask"])


class CutOffTests(DrawnPlanTests):
    """A write of B cut off part way (#567): the run stops before the owner's image, and a new run rewrites B."""

    def cut_run(self, reports_ok):
        unit = FakeUnit(self.dir.name, self.current_element, cut_upper_write_at=20, cut_reports_ok=reports_ok)   # B is 37 bytes: part of it
        end = unit.run(self.plan())
        self.assertEqual(end[0], "stop")
        self.assertEqual(unit.writes, ["upper"], "the owner's image is never written after a bad B")
        return unit, end

    def test_dfu_util_reporting_the_error_stops_with_the_way_back(self):
        _, end = self.cut_run(reports_ok=False)
        self.assertIn("dfu-util reported an error writing block B", end[1])

    def test_a_cut_write_dfu_util_called_good_is_caught_by_the_read_back(self):
        unit, end = self.cut_run(reports_ok=True)
        self.assertIn("isn't exactly block B after the write", end[1])
        self.assertEqual(self.kinds(unit)[-2:], ["read upper", "stop"])

    def test_a_new_run_sees_part_of_b_and_rewrites_it(self):
        unit, _ = self.cut_run(reports_ok=False)
        again = FakeUnit(self.dir.name, self.current_element, upper=bytes(unit.upper))
        self.assertEqual(again.run(self.plan()), ("done",))
        self.assertEqual([(a[1], a[2]) for a in again.log if a[0] == "type"],
                         [("word_upper", "REWRITE"), ("word_app", "FLASH")])
        block = good_block()
        self.assertEqual(bytes(again.upper[:len(block)]), block)
        self.assertEqual(bytes(again.app), self.owner_element)



class DeviceListTests(DrawnPlanTests):
    """Exactly one device, and it's the display chip, before any read (#567)."""

    def stopped_before_reading(self, devices, answers=None):
        unit = FakeUnit(self.dir.name, self.current_element, devices=devices, answers=answers)
        end = unit.run(self.plan())
        self.assertEqual(end[0], "stop")
        self.assertFalse([a for a in unit.log if a[0] in ("read", "write")], "nothing read or written")
        return end[1]

    def test_no_device_stops(self):
        self.assertIn("0 update-mode devices", self.stopped_before_reading(()))

    def test_two_chips_in_update_mode_stop(self):
        why = self.stopped_before_reading((("2-1.2", DISPLAY_LAYOUT), ("2-1.3", TOP_PANEL_LAYOUT)))
        self.assertIn("2 update-mode devices", why)

    def test_the_top_panel_chip_alone_stops_with_a_plain_message(self):
        # The owner's slip on 2026-11-19: BACK + FWD + VINYL, so the one device was the top panel chip (256 KB).
        why = self.stopped_before_reading((("2-1.2", "@Internal Flash  /0x08000000/04*016Kg,01*064Kg,01*128Kg"),))
        self.assertIn("top panel chip", why)

    def test_another_layout_stops_and_is_never_asked(self):
        # #603: a wrong-chip guard is a hard refusal, not a question; a yes answer can't take it past.
        other = (("2-1.2", "@Internal Flash  /0x08000000/12*016Kg"),)
        self.assertIn("isn't the display chip's", self.stopped_before_reading(other, {"list_layout_go_on": "y"}))



def options(rdp=0xAA, half=0x0FFF):
    return bytes([0xEC, rdp]) + b"\xff" * 6 + bytes([half & 0xFF, half >> 8]) + b"\xff" * 6


class RefusalTests(DrawnPlanTests):
    """Each refusal stops the run; one before the first write writes nothing (#567)."""

    def refused(self, expect, writes=(), **unit):
        unit.setdefault("app", self.current_element)
        app = unit.pop("app")
        fake = FakeUnit(self.dir.name, app, **unit)
        end = fake.run(self.plan())
        self.assertEqual(end[0], "stop", fake.log)
        self.assertIn(expect, end[1])
        self.assertEqual(fake.writes, list(writes))
        return fake

    def test_read_protection_on_stops_before_any_write(self):
        self.refused("read protection is on", options=options(rdp=0xBB))

    def test_a_write_protected_upper_sector_stops_before_any_write(self):
        self.refused("sector 9", options=options(half=0x0FFF & ~(1 << 9)))

    def test_a_wrong_word_for_b_writes_nothing(self):
        self.refused("not FLASH", words={"word_upper": "flash"})

    def test_a_wrong_word_for_the_image_writes_only_b(self):
        self.refused("not FLASH", writes=["upper"], words={"word_app": "yes"})

    def test_no_probe_without_the_phrase_stops_before_anything_is_written(self):
        # #603, the coordinator's call: asked up front whenever the owner's image is to be written, so a run never
        # ends half done on an answer it could have had at the start.
        self.refused("not NO PROBE", answers={"probe": "n"}, words={"no_probe": "y"})

    def test_no_probe_with_the_phrase_goes_on(self):
        fake = FakeUnit(self.dir.name, self.current_element, answers={"probe": "n"})
        self.assertEqual(fake.run(self.plan()), ("done",))

    def test_the_files_swapped_stop_before_anything_is_sent(self):
        self.upper, self.owner = self.owner, self.upper
        # B's file given as the owner's image fails its own check first; either way, nothing is sent.
        fake = self.refused("Nothing was sent")
        self.assertEqual(fake.log[0][0], "stop")

    def test_a_chip_not_holding_the_image_it_runs_now_stops_before_any_write(self):
        other = bytearray(self.current_element)
        other[0x100] ^= 1
        self.refused("doesn't hold the image it runs now", app=bytes(other))

    def test_something_else_in_the_upper_flash_stops_before_any_write(self):
        upper = bytearray(b"\xff" * UPPER_SIZE)
        upper[0x40000] = 0
        self.refused("Nothing is written over it", upper=bytes(upper))

    def test_the_ready_checklist_is_never_asked(self):
        # #603: the apps are watched by the shell; the rest (direct cable, no gig) is printed, not asked.
        unit = FakeUnit(self.dir.name, self.current_element)
        self.assertEqual(unit.run(self.plan()), ("done",))
        self.assertNotIn("all_true", [a[1] for a in unit.log if a[0] == "ask"])

    def test_the_stock_look_is_never_asked(self):
        # #603: printed by the shell at the end; nothing is written after it.
        unit = FakeUnit(self.dir.name, self.current_element)
        self.assertEqual(unit.run(self.plan()), ("done",))
        self.assertNotIn("stock_look", [a[1] for a in unit.log if a[0] == "ask"])


    def test_a_read_dfu_util_refuses_stops_and_isnt_asked_forever(self):
        for key in ("app_read", "options_read", "upper_read"):
            with self.subTest(key):
                self.refused("couldn't be read", failing_reads=(key,))

    def test_a_failed_read_back_stops_after_the_write(self):
        self.refused("couldn't be read", writes=["upper"], failing_reads=("upper_back",))



class BuildRecordTests(DrawnPlanTests):
    """How A and B were built is read from `make arm`'s record, judged against the very bytes (#593): never asked."""

    def test_a_good_record_is_read_and_the_owner_is_never_asked(self):
        unit = FakeUnit(self.dir.name, self.current_element)
        self.assertEqual(unit.run(self.plan()), ("done",))
        self.assertEqual(self.kinds(unit)[0], "update-mode")
        self.assertNotIn("both_true", [a[1] for a in unit.log if a[0] == "ask"])

    def test_no_record_stops_before_anything_is_sent(self):
        self.record = os.path.join(self.dir.name, "nowhere", "build.json")
        unit = FakeUnit(self.dir.name, self.current_element)
        end = unit.run(self.plan())
        self.assertEqual(end[0], "stop")
        self.assertIn("no build record", end[1])
        self.assertIn("Nothing was sent", end[1])
        self.assertEqual(len(unit.log), 1)


class FoundCurrentTests(DrawnPlanTests):
    """The image the chip runs now, found from the read instead of asked (#603): the owner's image, the remembered
    file, or a .dfu in the work folder that verifies and matches the read byte for byte. It's the way back, so a read
    that matches none of them refuses."""

    def found_plan(self, remembered=""):
        path = os.path.join(self.dir.name, "plan.json")
        drawn_plan.begin(path, current="", upper=self.upper, owner=self.owner, record=self.record,
                         work=self.dir.name, remembered=remembered)
        return path

    def test_a_dfu_in_the_work_folder_that_matches_the_read_is_the_one_it_runs(self):
        unit = FakeUnit(self.dir.name, self.current_element)
        self.assertEqual(unit.run(self.found_plan()), ("done",))
        said = [a[2] for a in unit.log if a[:2] == ("skip", "current_found")]
        self.assertEqual(len(said), 1)
        self.assertIn(self.current, said[0])
        self.assertEqual(unit.writes, ["upper", "app"])

    def test_the_owners_image_on_the_chip_is_found_and_the_app_area_isnt_written(self):
        unit = FakeUnit(self.dir.name, self.owner_element)
        self.assertEqual(unit.run(self.found_plan()), ("done",))
        self.assertEqual(unit.writes, ["upper"])

    def test_the_remembered_file_outside_the_work_folder_is_a_candidate(self):
        os.makedirs(os.path.join(self.dir.name, "elsewhere"))
        remembered = os.path.join(self.dir.name, "elsewhere", "slot16.dfu")
        os.rename(self.current, remembered)
        unit = FakeUnit(self.dir.name, self.current_element)
        self.assertEqual(unit.run(self.found_plan(remembered)), ("done",))
        self.assertIn(remembered, [a[2] for a in unit.log if a[:2] == ("skip", "current_found")][0])

    def test_a_verified_write_leaves_no_record_of_an_interrupted_one(self):
        unit = FakeUnit(self.dir.name, self.current_element)
        self.assertEqual(unit.run(self.found_plan()), ("done",))
        self.assertFalse(os.path.exists(os.path.join(self.dir.name, "app-write.json")))

    def test_a_record_of_a_cut_write_on_another_unit_refuses(self):
        half = bytearray(b"\xff" * len(self.owner_element))
        half[:len(half) // 2] = self.owner_element[:len(half) // 2]
        with open(os.path.join(self.dir.name, "app-write.json"), "w") as f:
            json.dump({"file": os.path.realpath(self.owner), "sha256": drawn_plan.sha256_of(self.owner),
                       "upper": self.upper, "serial": "123456789ABC", "started": "earlier", "run": "x"}, f)
        unit = FakeUnit(self.dir.name, bytes(half))
        end = unit.run(self.found_plan())
        self.assertEqual(end[0], "stop")
        self.assertIn("interrupted write", end[1])
        self.assertEqual(unit.writes, [])

    def test_a_garbage_dfu_in_the_work_folder_is_passed_over(self):
        self.write("aaa-garbage.dfu", b"not a dfu at all")
        self.write("aab-empty.dfu", b"")
        unit = FakeUnit(self.dir.name, self.current_element)
        self.assertEqual(unit.run(self.found_plan()), ("done",))

    def test_a_read_that_matches_no_file_refuses_before_any_write(self):
        other = bytearray(self.current_element)
        other[0x100] ^= 1
        unit = FakeUnit(self.dir.name, bytes(other))
        end = unit.run(self.found_plan())
        self.assertEqual(end[0], "stop")
        self.assertIn("matches none", end[1])
        self.assertIn("--current", end[1])
        self.assertEqual(unit.writes, [])


class FindRecordTests(unittest.TestCase):
    """`drawn_plan.py find-record UPPER.dfu OWNER.dfu` (#593): the record each kit tool left beside its .dfu, so the owner
    types no fourth path. Exactly one record, or ask."""

    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.upper = os.path.join(self.dir.name, "wd-upper-drawing.dfu")
        self.owner = os.path.join(self.dir.name, "owner", "wd-owner.dfu")
        os.makedirs(os.path.dirname(self.owner))

    def leave(self, dfu, content):
        path = os.path.splitext(dfu)[0] + ".build.json"
        with open(path, "w") as f:
            f.write(content)
        return path

    def find(self):
        import contextlib, io
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = drawn_plan.main(["find-record", self.upper, self.owner])
        self.assertEqual(code, 0)
        return out.getvalue().rstrip("\n").split("\t")

    def test_one_record_beside_either_file_is_the_one(self):
        self.assertEqual(self.find_with(upper='{"x": 1}'), ["one", os.path.splitext(self.upper)[0] + ".build.json"])
        self.setUp()
        self.assertEqual(self.find_with(owner='{"x": 1}'), ["one", os.path.splitext(self.owner)[0] + ".build.json"])

    def find_with(self, upper=None, owner=None):
        if upper is not None:
            self.leave(self.upper, upper)
        if owner is not None:
            self.leave(self.owner, owner)
        return self.find()

    def test_the_same_record_beside_both_is_one(self):
        self.assertEqual(self.find_with(upper='{"x": 1}', owner='{"x": 1}')[0], "one")

    def test_none_or_two_different_asks(self):
        self.assertEqual(self.find()[0], "ask")
        kind, why = self.find_with(upper='{"x": 1}', owner='{"x": 2}')
        self.assertEqual(kind, "ask")
        self.assertIn("differ", why)


class FindFilesTests(unittest.TestCase):
    """`drawn_plan.py find-files WORK UPPER OWNER` (#603): block B and the owner's image, found instead of asked. The
    newest build in WORK that the kit tools left with a record beside each file (the normal rewrite is "rebuild, then
    flash"); else the remembered pair when both are still there with one record; else ask. Last run's record comes
    back too when it's another build, for the word screen."""

    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.work = os.path.join(self.dir.name, "work")
        os.makedirs(self.work)

    def pair(self, folder, tag="1", record=None, built=None):
        """A B .dfu and an owner's image .dfu in FOLDER, each with the build record copy the kit leaves beside it."""
        os.makedirs(folder, exist_ok=True)
        upper, owner = (os.path.join(folder, f"wd-{name}-{tag}.dfu") for name in ("upper-drawing", "owner"))
        with open(upper, "wb") as f:
            f.write(build_upper_dfu.dfuse(good_block()))
        with open(owner, "wb") as f:
            f.write(dfuse_file(stock_like_element()))
        for dfu in (upper, owner):
            with open(build_record.carried(dfu), "w") as f:
                f.write(record if record is not None else json.dumps({"build": tag, "commit": f"c{tag}",
                                                                      **({"built": built} if built else {})}))
        return upper, owner

    def find(self, upper="", owner=""):
        import contextlib, io
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = drawn_plan.main(["find-files", self.work, upper, owner])
        self.assertEqual(code, 0)
        return out.getvalue().rstrip("\n").split("\t")

    def test_the_one_kit_pair_in_work_is_found(self):
        upper, owner = self.pair(self.work)
        self.assertEqual(self.find(), ["one", upper, owner, build_record.carried(upper), ""])

    def test_the_newest_build_in_work_wins_over_the_remembered_pair(self):
        # The CoS's call: a silent pick of the older pair is a wrong write nobody catches by hash.
        new_upper, new_owner = self.pair(self.work, "new", built=2000)
        old_upper, old_owner = self.pair(os.path.join(self.dir.name, "elsewhere"), "old", built=1000)
        self.assertEqual(self.find(old_upper, old_owner),
                         ["one", new_upper, new_owner, build_record.carried(new_upper), build_record.carried(old_upper)])

    def test_the_remembered_pair_is_used_when_work_has_no_build(self):
        upper, owner = self.pair(os.path.join(self.dir.name, "elsewhere"), "old")
        self.assertEqual(self.find(upper, owner), ["one", upper, owner, build_record.carried(upper), ""])

    def test_of_two_builds_in_work_the_newest_wins(self):
        self.pair(self.work, "1", built=1000)
        upper, owner = self.pair(self.work, "2", built=2000)
        self.assertEqual(self.find()[:3], ["one", upper, owner])

    def test_two_builds_from_the_same_moment_ask(self):
        self.pair(self.work, "1", built=1000)
        self.pair(self.work, "2", built=1000)
        self.assertEqual(self.find()[0], "ask")

    def test_a_remembered_pair_that_is_gone_falls_back_to_work(self):
        upper, owner = self.pair(self.work)
        gone = os.path.join(self.dir.name, "gone.dfu")
        self.assertEqual(self.find(gone, gone)[:3], ["one", upper, owner])

    def test_a_remembered_pair_from_two_builds_isnt_used(self):
        upper, _ = self.pair(os.path.join(self.dir.name, "a"), "a")
        _, owner = self.pair(os.path.join(self.dir.name, "b"), "b")
        self.assertEqual(self.find(upper, owner)[0], "ask")

    def test_no_build_anywhere_asks(self):
        kind, why = self.find()
        self.assertEqual(kind, "ask")

    def test_a_dfu_with_no_record_beside_it_isnt_a_candidate(self):
        upper, owner = self.pair(self.work)
        with open(os.path.join(self.work, "wd-upper-rewrite-abc.dfu"), "wb") as f:
            f.write(build_upper_dfu.dfuse(good_block()))
        self.assertEqual(self.find()[:3], ["one", upper, owner])


class DevicesCommandTests(unittest.TestCase):
    """`drawn_plan.py devices LISTING`, for the stock wizard's look() (#567): the same judgment the drawn plan makes,
    so the shell no longer counts devices itself."""

    def judge(self, *devices):
        with tempfile.TemporaryDirectory() as folder:
            path = os.path.join(folder, "listing.txt")
            with open(path, "w") as f:
                f.write(listing(*devices))
            import contextlib, io
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                code = drawn_plan.main(["devices", path])
            return code, out.getvalue().rstrip("\n").split("\t")

    def test_one_display_chip_gives_its_path(self):
        self.assertEqual(self.judge(("2-1.2", DISPLAY_LAYOUT)), (0, ["one", "2-1.2"]))

    def test_two_devices_or_none_stop(self):
        self.assertEqual(self.judge()[1][0], "stop")
        self.assertEqual(self.judge(("2-1.2", DISPLAY_LAYOUT), ("2-1.3", DISPLAY_LAYOUT))[1][0], "stop")

    def test_the_top_panel_chip_stops(self):
        code, (kind, why) = self.judge(("2-1.2", TOP_PANEL_LAYOUT))
        self.assertEqual(kind, "stop")
        self.assertIn("top panel chip", why)

    def test_another_layout_stops(self):
        # Both wizards' look (#603): the stock wizard's look refuses it too.
        code, (kind, why) = self.judge(("2-1.2", "@Internal Flash  /0x08000000/12*016Kg"))
        self.assertEqual(kind, "stop")
        self.assertIn("isn't the display chip's", why)


class FreshnessTests(DrawnPlanTests):
    """A plan file never lets stale facts authorize a write (#567): each write rests on its own read, made in this run
    after update mode was entered."""

    def test_a_plan_file_left_from_a_completed_run_asks_for_everything_again(self):
        path = self.plan()
        self.assertEqual(FakeUnit(self.dir.name, self.current_element).run(path), ("done",))
        # The same file, begun again for a new run.
        drawn_plan.begin(path, current=self.current, upper=self.upper, owner=self.owner, record=self.record,
                         work=self.dir.name)
        self.assertEqual(drawn_plan.next_action(path)[:1], ("update-mode",))

    def test_facts_from_another_run_kept_in_the_file_authorize_nothing(self):
        # A completed run's facts left in the file under a new run id: the reads come again before any write.
        path = self.plan()
        self.assertEqual(FakeUnit(self.dir.name, self.current_element).run(path), ("done",))
        plan = drawn_plan.load(path)
        plan["run"] = "another-run"
        drawn_plan.save(path, plan)
        unit = FakeUnit(self.dir.name, self.current_element)
        unit.run(path)
        kinds = self.kinds(unit)
        self.assertLess(kinds.index("read upper"), kinds.index("write upper"))
        self.assertLess(kinds.index("read app"), kinds.index("write app"))
        self.assertEqual(kinds[0], "update-mode")

    def test_a_read_made_before_update_mode_is_read_again(self):
        path = self.plan()
        upper = self.write("old-upper.bin", b"\xff" * UPPER_SIZE)
        drawn_plan.record(path, "upper_read", upper)   # before update mode
        drawn_plan.record(path, "update_mode", "ok")
        unit = FakeUnit(self.dir.name, self.current_element)
        unit.run(path)
        reads = [a[4] for a in unit.log if a[0] == "read"]
        self.assertIn("upper_read", reads)
        self.assertLess(self.kinds(unit).index("read upper"), self.kinds(unit).index("write upper"))


if __name__ == "__main__":
    unittest.main()
