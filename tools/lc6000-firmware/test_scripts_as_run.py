"""Every script the flash-day wizard, the README's checklist and the display firmware's build run, run exactly as they
run it (#468): `python3 -I <path>`, from a folder that isn't the script's. Since Python 3.11, -I also leaves the
script's own folder off sys.path, so a script that imports a sibling must put its folder there itself. `unittest
discover` adds the folder, which is how this went unseen.
Run from the repo root: python3 -I -m unittest discover tools/lc6000-firmware"""
import os, subprocess, sys, tempfile, unittest

HERE = os.path.dirname(os.path.realpath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))

# Each script, and an invocation that imports everything it needs and sends nothing. (The display firmware's
# upper_seal.py, which make runs the same way, imports only the standard library.)
SCRIPTS = [
    ("tools/lc6000-firmware/dfupatch.py", ["--help"]),
    ("tools/lc6000-firmware/build_upper_dfu.py", ["--help"]),
    ("tools/lc6000-firmware/build_owner_image.py", ["--help"]),
    ("tools/lc6000-firmware/drawn_flash.py", ["--help"]),
    ("tools/lc6000-firmware/drawn_flash.py", ["no-probe-risk"]),
    ("tools/lc6000-firmware/drawn_plan.py", []),   # usage on stderr, exit 2: it imported everything
]


class ScriptsAsRunTests(unittest.TestCase):
    def test_each_script_starts_under_python_dash_I_from_another_folder(self):
        with tempfile.TemporaryDirectory() as elsewhere:
            for script, arguments in SCRIPTS:
                with self.subTest(script=script, arguments=arguments):
                    result = subprocess.run([sys.executable, "-I", os.path.join(ROOT, script), *arguments],
                                            cwd=elsewhere, capture_output=True, text=True)
                    self.assertNotIn("ModuleNotFoundError", result.stderr)
                    self.assertNotIn("Traceback", result.stderr)

    def test_the_wizard_runs_its_python_this_way(self):
        # So the test above covers what the wizard really does.
        with open(os.path.join(HERE, "flash-day.sh")) as f:
            wizard = f.read()
        self.assertIn('dfupatch() { python3 -I "$HERE/dfupatch.py" "$@"; }', wizard)
        self.assertIn('plan() { python3 -I "$HERE/drawn_plan.py" "$@"; }', wizard)


if __name__ == "__main__":
    unittest.main()
