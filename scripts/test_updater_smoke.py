#!/usr/bin/env python3
"""Tests for scripts/updater_smoke.sh, the firmware updater's launch smoke check (#734): run against a stand-in app
and a stand-in ioreg, so they need no Mac, no build and no device.
Run: python3 -I scripts/test_updater_smoke.py"""
import os, stat, subprocess, tempfile, time, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "updater_smoke.sh")
LINE = "first look: deck panel not found, LC6000 not found"

# What ioreg -p IOUSB -l prints for a USB device, cut down to the line the script reads.
KEYBOARD = '    |   "idVendor" = 1452\n'          # Apple: not ours
CH340 = '    |   "idVendor" = 6790\n'             # 0x1A86, the deck panel's USB serial chip
INMUSIC = '    |   "idVendor" = 5604\n'           # 0x15E4, the LC6000
ST_DFU = '    |   "idVendor" = 1155\n'            # 0x0483, an LC6000 chip in update mode
ESPRESSIF = '    |   "idVendor" = 12346\n'        # 0x303A, an ESP32-S3's own USB


def executable(path, text):
    with open(path, "w") as f:
        f.write(text)
    os.chmod(path, os.stat(path).st_mode | stat.S_IXUSR)


class UpdaterSmokeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = self.tmp.name
        self.bin = os.path.join(root, "bin")
        os.makedirs(self.bin)
        self.app = os.path.join(root, "DeckBridge Firmware Updater.app")  # #763's name, its binary too
        os.makedirs(os.path.join(self.app, "Contents", "MacOS"))
        self.log = os.path.join(root, "updater.log")
        self.ran = os.path.join(root, "ran")
        self.usb(KEYBOARD)

    def tearDown(self):
        self.tmp.cleanup()

    def usb(self, listing):
        executable(os.path.join(self.bin, "ioreg"), f"#!/bin/bash\nprintf '%s' '{listing}'\n")

    def stand_in(self, body):
        """The app's binary: notes its arguments, then does `body` with $LOG as the log file."""
        executable(os.path.join(self.app, "Contents", "MacOS", "DeckBridge Firmware Updater"),
                   f'#!/bin/bash\necho "$@" > "{self.ran}"\nLOG="{self.log}"\n{body}\n')

    def run_smoke(self, timeout="5"):
        env = {"PATH": self.bin + ":/usr/bin:/bin", "UPDATER_LOG": self.log, "UPDATER_SMOKE_TIMEOUT": timeout}
        return subprocess.run(["bash", SCRIPT, self.app], env=env, capture_output=True, text=True, timeout=30)

    def logs(self, line):
        return f'echo "2026-11-22T10:00:00Z {line}" >> "$LOG"'

    def test_passes_when_the_app_logs_nothing_found_and_quits(self):
        self.stand_in(self.logs(LINE))
        result = self.run_smoke()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        with open(self.ran) as f:
            self.assertEqual(f.read().split(), ["--smoke"])

    def test_reads_only_what_this_run_wrote(self):
        # An earlier run's line in the log doesn't count.
        with open(self.log, "w") as f:
            f.write(f"2026-11-21T10:00:00Z {LINE}\n")
        self.stand_in("exit 0")
        self.assertNotEqual(self.run_smoke().returncode, 0)

    def test_fails_when_the_app_does_not_quit(self):
        self.stand_in(self.logs(LINE) + "\nsleep 30")
        started = time.monotonic()
        result = self.run_smoke(timeout="2")
        self.assertNotEqual(result.returncode, 0)
        self.assertLess(time.monotonic() - started, 15)
        self.assertIn("didn't quit", result.stdout + result.stderr)

    def test_fails_when_the_app_exits_with_an_error(self):
        self.stand_in(self.logs(LINE) + "\nexit 3")
        self.assertNotEqual(self.run_smoke().returncode, 0)

    def test_fails_when_the_line_is_not_exactly_nothing_found(self):
        for line in ["first look: deck panel not found", "first look: deck panel found (build read), LC6000 not found",
                     LINE + ", and more"]:
            with self.subTest(line=line):
                if os.path.exists(self.log):
                    os.remove(self.log)
                self.stand_in(self.logs(line))
                self.assertNotEqual(self.run_smoke().returncode, 0)

    def test_fails_when_the_app_logged_a_device(self):
        # The finder logs a line for each device it looked at; with nothing plugged in there must be none.
        self.stand_in(self.logs("LC6000: MIDI ports present, firmware not checked") + "\n" + self.logs(LINE))
        self.assertNotEqual(self.run_smoke().returncode, 0)

    def test_refuses_with_a_deck_panel_or_lc6000_plugged_in_and_never_starts_the_app(self):
        for listing in [CH340, INMUSIC, ST_DFU, ESPRESSIF]:
            with self.subTest(listing=listing):
                self.usb(KEYBOARD + listing)
                self.stand_in(self.logs(LINE))
                result = self.run_smoke()
                self.assertEqual(result.returncode, 2)
                self.assertIn("nothing plugged in", result.stdout + result.stderr)
                self.assertFalse(os.path.exists(self.ran))

    def test_stops_when_there_is_no_app(self):
        result = subprocess.run(["bash", SCRIPT, os.path.join(self.tmp.name, "missing.app")],
                                env={"PATH": self.bin + ":/usr/bin:/bin", "UPDATER_LOG": self.log},
                                capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 2)


if __name__ == "__main__":
    unittest.main()
