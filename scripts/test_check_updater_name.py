#!/usr/bin/env python3
"""Tests for scripts/check_updater_name.py: the built updater is "DeckBridge Firmware Updater" wherever the owner sees
its name: the .app file, the app menu, About and Quit (CFBundleName) and the Dock (CFBundleDisplayName) (#763).
Run: python3 -I scripts/test_check_updater_name.py"""
import os, plistlib, subprocess, sys, tempfile, unittest

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import check_updater_name

NAME = "DeckBridge Firmware Updater"
SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "check_updater_name.py")


def app(root, file=NAME, bundle=NAME, display=NAME, executable=NAME):
    """A built app bundle: its file name, the two Info.plist names and its binary."""
    path = os.path.join(root, f"{file}.app")
    os.makedirs(os.path.join(path, "Contents", "MacOS"))
    with open(os.path.join(path, "Contents", "Info.plist"), "wb") as f:
        plistlib.dump({"CFBundleName": bundle, "CFBundleDisplayName": display, "CFBundleExecutable": executable}, f)
    open(os.path.join(path, "Contents", "MacOS", executable), "w").close()
    return path


class CheckUpdaterNameTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()

    def tearDown(self):
        self.tmp.cleanup()

    def test_the_named_app_passes(self):
        self.assertEqual(check_updater_name.problems(app(self.tmp.name)), [])

    def test_the_old_short_menu_name_is_a_problem(self):
        self.assertEqual(check_updater_name.problems(app(self.tmp.name, bundle="Firmware Updater")),
                         ['CFBundleName is "Firmware Updater", needs "DeckBridge Firmware Updater"'])

    def test_the_old_file_name_is_a_problem(self):
        self.assertEqual(check_updater_name.problems(app(self.tmp.name, file="FirmwareUpdater")),
                         ['the app is "FirmwareUpdater.app", needs "DeckBridge Firmware Updater.app"'])

    def test_a_dock_name_that_differs_is_a_problem(self):
        self.assertEqual(check_updater_name.problems(app(self.tmp.name, display="Updater")),
                         ['CFBundleDisplayName is "Updater", needs "DeckBridge Firmware Updater"'])

    def test_a_binary_the_plist_names_but_the_app_lacks_is_a_problem(self):
        path = app(self.tmp.name)
        os.remove(os.path.join(path, "Contents", "MacOS", NAME))
        self.assertEqual(check_updater_name.problems(path), [f'no binary "{NAME}" in Contents/MacOS'])

    def test_the_command_exits_1_and_prints_each_problem(self):
        path = app(self.tmp.name, bundle="Firmware Updater", display="Updater")
        run = subprocess.run([sys.executable, "-I", SCRIPT, path], capture_output=True, text=True)
        self.assertEqual(run.returncode, 1)
        self.assertEqual(run.stdout.splitlines(), [
            'CFBundleName is "Firmware Updater", needs "DeckBridge Firmware Updater"',
            'CFBundleDisplayName is "Updater", needs "DeckBridge Firmware Updater"',
        ])


if __name__ == "__main__":
    unittest.main()
