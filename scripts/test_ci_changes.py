#!/usr/bin/env python3
"""Tests for scripts/ci_changes.py: which changes need CI's Mac jobs (Kit tests, App build).
Run: python3 -I scripts/test_ci_changes.py"""
import os, subprocess, sys, unittest

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ci_changes


class NeedsMacTests(unittest.TestCase):
    def test_a_website_only_change_skips_the_mac_jobs(self):
        self.assertFalse(ci_changes.needs_mac(["website/site.css", "website/index.html"]))

    def test_no_known_changes_run_the_mac_jobs(self):
        # an empty diff means CI couldn't tell (a new branch, a force push): run everything
        self.assertTrue(ci_changes.needs_mac([]))

    def test_any_app_change_runs_the_mac_jobs(self):
        self.assertTrue(ci_changes.needs_mac(["website/site.css", "Packages/ControllerBridgeKit/Package.swift"]))
        self.assertTrue(ci_changes.needs_mac(["App/BridgeModel.swift"]))

    def test_site_scripts_and_markdown_docs_skip_the_mac_jobs(self):
        self.assertFalse(ci_changes.needs_mac([
            "scripts/check_site.py", "scripts/test_check_site.py", "scripts/site-preview.sh",
            "scripts/test_analytics.mjs", "scripts/test_capture.mjs",
            "README.md", "CHANGELOG.md", "docs/research/controllers.md"]))

    def test_the_domain_docs_and_their_check_skip_the_mac_jobs(self):
        self.assertFalse(ci_changes.needs_mac([
            "GLOSSARY.md", "docs/adr/0001-native-swift-menu-bar-app.md",
            "scripts/check_domain_docs.py", "scripts/test_check_domain_docs.py"]))

    def test_the_lc6000_firmware_tool_skips_the_mac_jobs(self):
        # tools/lc6000-firmware (#430): Python with its own tests, run by the Site check job
        self.assertFalse(ci_changes.needs_mac([
            "tools/lc6000-firmware/build_owner_image.py", "tools/lc6000-firmware/test_dfupatch.py",
            "tools/lc6000-firmware/.gitignore"]))

    def test_the_drawn_display_firmware_skips_the_mac_jobs(self):
        # tools/lc6000-display-fw (#457): C with its own tests, run by the Display firmware job on Linux
        self.assertFalse(ci_changes.needs_mac([
            "tools/lc6000-display-fw/src/dfw.c", "tools/lc6000-display-fw/test/test_modes.c",
            "tools/lc6000-display-fw/Makefile", "tools/lc6000-display-fw/README.md"]))

    def test_the_shared_message_vectors_run_the_mac_jobs(self):
        # the vectors file (#456) is walked by the Kit tests too, so a change to it alone must still run them
        self.assertTrue(ci_changes.needs_mac(["tools/lc6000-display-fw/vectors/messages.json"]))

    def test_the_drawn_display_reference_images_run_the_mac_jobs(self):
        # the reference images (#464) are checked against the Swift renderer by the Kit tests too
        self.assertTrue(ci_changes.needs_mac(["tools/lc6000-display-fw/test/ref/stale.ppm"]))
        self.assertTrue(ci_changes.needs_mac(["tools/lc6000-display-fw/test/ref/make_refs.sh"]))

    def test_the_lc6000_patch_descriptions_run_the_mac_jobs(self):
        # the firmware updater's catalog (#686) carries copies of them, and its Kit tests check the copies match
        self.assertTrue(ci_changes.needs_mac(["tools/lc6000-firmware/patches/wd-00.50-show-slot-16.patch"]))

    def test_the_build_record_reader_and_what_it_imports_run_the_mac_jobs(self):
        # the updater's block staging step (#696), tested in the Kit job, reads make arm's record through these
        for path in ["tools/lc6000-firmware/build_record.py", "tools/lc6000-firmware/dfupatch.py",
                     "tools/lc6000-firmware/drawn_flash.py", "tools/lc6000-firmware/build_upper_dfu.py",
                     "tools/lc6000-display-fw/arm/upper_header.py"]:
            self.assertTrue(ci_changes.needs_mac([path]), path)
        self.assertFalse(ci_changes.needs_mac(["tools/lc6000-firmware/build_owner_image.py"]))

    def test_the_deck_panel_firmware_skips_the_mac_jobs(self):
        # tools/deck-panel (#615): PlatformIO with its own tests, run by the Deck panel job on Linux
        self.assertFalse(ci_changes.needs_mac([
            "tools/deck-panel/src/main.cpp", "tools/deck-panel/lib/test_pattern/test_pattern.cpp",
            "tools/deck-panel/platformio.ini", "tools/deck-panel/README.md"]))

    def test_the_display_feed_examples_run_the_mac_jobs(self):
        # the feed's example messages (#490) are walked by the Kit tests too
        self.assertTrue(ci_changes.needs_mac(["tools/deck-panel/feed/examples.json"]))

    def test_workflow_and_release_script_changes_run_the_mac_jobs(self):
        for path in [".github/workflows/ci.yml", "scripts/ci_profile.py", "scripts/smoke.sh", "project.yml",
                     ".github/pull_request_template.md"]:
            self.assertTrue(ci_changes.needs_mac([path]), path)


class NeedsDeckPanelTests(unittest.TestCase):
    """The Deck panel job (#615) runs only for a change to the panel's firmware, or to CI itself."""

    def test_a_deck_panel_change_runs_it(self):
        self.assertTrue(ci_changes.needs_deck_panel(["App/BridgeModel.swift", "tools/deck-panel/src/main.cpp"]))
        self.assertTrue(ci_changes.needs_deck_panel(["tools/deck-panel/feed/examples.json"]))

    def test_other_changes_skip_it(self):
        self.assertFalse(ci_changes.needs_deck_panel(["App/BridgeModel.swift", "website/index.html", "README.md"]))
        self.assertFalse(ci_changes.needs_deck_panel(["tools/lc6000-display-fw/src/dfw.c"]))

    def test_the_icon_svg_the_logo_is_made_from_runs_it(self):
        # the panel's logo (#651) is generated from it, and test_deck_logo.py fails when they drift (#669)
        self.assertTrue(ci_changes.needs_deck_panel(["design/icon/icon-1-deck-ring.svg"]))
        self.assertFalse(ci_changes.needs_deck_panel(["design/icon/menubar-deck-ring-16.svg"]))

    def test_a_change_to_the_ci_workflow_runs_it(self):
        self.assertTrue(ci_changes.needs_deck_panel([".github/workflows/ci.yml"]))

    def test_no_known_changes_run_it(self):
        self.assertTrue(ci_changes.needs_deck_panel([]))


class DiffBaseTests(unittest.TestCase):
    """What the change is measured against (#546): each event says it differently, and a merge queue run has its own."""

    def test_a_pull_request_against_its_base(self):
        self.assertEqual(ci_changes.diff_base("pull_request", {"pull_request": {"base": {"sha": "aaa"}}}), "aaa")

    def test_a_merge_queue_entry_against_the_queue_base(self):
        self.assertEqual(ci_changes.diff_base("merge_group", {"merge_group": {"base_sha": "bbb", "head_sha": "ccc"}}),
                         "bbb")

    def test_a_push_against_the_commit_before(self):
        self.assertEqual(ci_changes.diff_base("push", {"before": "ddd"}), "ddd")

    def test_anything_else_or_missing_is_unknown(self):
        # an unknown base lists nothing, and nothing runs everything
        self.assertEqual(ci_changes.diff_base("workflow_dispatch", {}), "")
        self.assertEqual(ci_changes.diff_base("merge_group", {}), "")


class WorkflowTests(unittest.TestCase):
    """The CI workflow runs for a merge queue entry, and every required check reports for it (#546): a required check
    that never reports would hold the queue."""

    @classmethod
    def setUpClass(cls):
        root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        with open(os.path.join(root, ".github", "workflows", "ci.yml")) as f:
            cls.ci = f.read()

    def job(self, name):
        start = self.ci.index(f"    name: {name}\n")
        start = self.ci.rindex("\n  ", 0, start)
        end = self.ci.find("\n  ", start + 3)
        while end != -1 and self.ci[end + 3] == " ":
            end = self.ci.find("\n  ", end + 3)
        return self.ci[start:end if end != -1 else len(self.ci)]

    def test_the_arm_toolchain_download_fails_fast_and_retries_once(self):
        """The apt download of gcc-arm-none-eabi stalled twice until the job's 15 minutes ran out (#640): a stalled
        transfer must fail within minutes and be tried once more, inside the job's timeout."""
        step = self.job("Display firmware")
        install = step[step.index("Arm toolchain and emulator"):]
        self.assertIn("Acquire::http::Timeout=", install)
        self.assertIn("Acquire::Retries=", install)
        self.assertRegex(install, r"for attempt in 1 2; do\s+timeout \d+ sudo apt-get")
        self.assertIn("install -y --no-install-recommends", install)

    def test_it_runs_on_merge_group(self):
        on = self.ci[self.ci.index("\non:\n"):self.ci.index("\npermissions:")]
        self.assertIn("\n  merge_group:", on)

    def test_only_pull_requests_cancel_runs_in_progress(self):
        self.assertIn("cancel-in-progress: ${{ github.event_name == 'pull_request' }}", self.ci)

    def test_the_changes_job_asks_ci_changes_for_its_base(self):
        changes = self.job("Changes")
        self.assertIn('python3 -I scripts/ci_changes.py --base "$GITHUB_EVENT_NAME" "$GITHUB_EVENT_PATH"', changes)
        self.assertNotIn("github.event.before", changes)

    def test_every_required_job_runs_or_reports_for_any_event(self):
        for name in ("Kit tests", "App build (Release, ad-hoc)", "Display firmware"):
            with self.subTest(name):
                conditions = [line.strip() for line in self.job(name).splitlines() if line.strip().startswith("if:")]
                # Only the changes gate: a job it skips reports skipped, which the ruleset counts as passed.
                self.assertTrue(all(c == "if: needs.changes.outputs.mac == 'true'" for c in conditions), conditions)

    def test_the_deck_panel_job_runs_only_when_the_panel_changes(self):
        conditions = [line.strip() for line in self.job("Deck panel").splitlines() if line.strip().startswith("if:")]
        self.assertEqual(conditions, ["if: needs.changes.outputs.deck_panel == 'true'"])


class OutputTests(unittest.TestCase):
    def run_script(self, stdin):
        script = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ci_changes.py")
        return subprocess.run([sys.executable, "-I", script], input=stdin, capture_output=True, text=True, check=True).stdout

    def test_it_prints_one_github_output_line_per_gate(self):
        self.assertEqual(self.run_script("website/site.css\n\nREADME.md\n"), "mac=false\ndeck_panel=false\n")
        self.assertEqual(self.run_script("App/UDP.swift\n"), "mac=true\ndeck_panel=false\n")
        self.assertEqual(self.run_script("tools/deck-panel/src/main.cpp\n"), "mac=false\ndeck_panel=true\n")
        self.assertEqual(self.run_script(""), "mac=true\ndeck_panel=true\n")


if __name__ == "__main__":
    unittest.main()
