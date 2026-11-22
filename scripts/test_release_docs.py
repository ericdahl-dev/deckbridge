#!/usr/bin/env python3
"""Pins the v1.1 release checklist and the TestFlight What to Test it ships with. No network.
Run: python3 -I scripts/test_release_docs.py"""
import os, re, sys, unittest

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import testflight_distribute as td
import check_site

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")


def read(path):
    with open(os.path.join(ROOT, path), encoding="utf-8") as f:
        return f.read()


class ReleaseChecklist(unittest.TestCase):
    def test_steps_in_order(self):
        steps = re.findall(r"^## (\d+)\. (.+)$", read("docs/RELEASE-1.1.md"), re.M)
        self.assertEqual(steps, [
            ("1", "Hardware spike: upload timing"),
            ("2", "Jog display hardware checklist"),
            ("3", "Turn the jog display on by default"),
            ("4", "CHANGELOG"),
            ("5", "TestFlight What to Test"),
            ("6", "Internal build"),
            ("7", "External build and a short beta"),
            ("8", "App Store listing"),
            ("9", "Submit 1.1.0 to the App Store"),
            ("10", "Site"),
            ("11", "After the release"),
        ])

    def test_version_and_tags(self):
        doc = read("docs/RELEASE-1.1.md")
        self.assertIn('git tag -a v1.1.0 -m "Release 1.1.0"', doc)
        self.assertIn("[external]", doc)
        self.assertIn("## 1.1.0", doc)  # the ready-to-paste CHANGELOG block

    def test_changelog_block_is_what_changelog_has(self):
        # Step 4's block says it's what CHANGELOG.md has (#648): the two can't drift.
        doc = read("docs/RELEASE-1.1.md")
        step = doc[doc.index("## 4. CHANGELOG"):doc.index("## 5. ")]
        block = re.search(r"```markdown\n(.*?)```", step, re.S).group(1)
        changelog = read("CHANGELOG.md")
        entry = changelog[changelog.index("## 1.1.0"):changelog.index("## 1.0.2")]
        self.assertEqual(block.strip(), entry.strip())

    def test_hardware_checklist_extras(self):
        # #307: before the checklist, other host apps are quit; and host-mode layers and LEDs (#79, #120) are re-checked.
        # #306: the platter wins while a deck plays too.
        doc = read("docs/RELEASE-1.1.md")
        step = doc[doc.index("## 2. "):doc.index("## 3. ")]
        for phrase in ["Quit djay and Engine", "host mode", "#79", "#120", "ch16 note 55", "multi-channel", "while it plays"]:
            self.assertIn(phrase, step)

    def test_app_store_submission(self):
        doc = read("docs/RELEASE-1.1.md")
        submit = doc[doc.index("## 9. Submit"):doc.index("## 10.")]
        for phrase in ["Free", "#29", "docs/APP_REVIEW.md", "Data Not Collected", "the user submits"]:
            self.assertIn(phrase, submit)
        beta = doc[doc.index("## 7. External"):doc.index("## 8.")]
        self.assertIn("24–48 hours", beta)

    def test_site_step_links_the_held_pr(self):
        doc = read("docs/RELEASE-1.1.md")
        site = doc[doc.index("## 10. Site"):doc.index("## 11.")]
        # #647: #652 replaced #300 and carries #634 (the network and privacy copy); both go live on release day.
        self.assertIn("https://github.com/ericdahl-dev/deckbridge/pull/652", site)
        self.assertIn("https://github.com/ericdahl-dev/deckbridge/pull/634", site)
        self.assertNotIn("pull/300", site)


class Changelog(unittest.TestCase):
    def setUp(self):
        changelog = read("CHANGELOG.md")
        self.entry = changelog[changelog.index("## 1.1.0"):changelog.index("## 1.0.2")]

    def test_lists_what_main_gained_since_1_0_2(self):
        # #648: the audit on #647. Each user-facing change by its issue.
        for issue in ["#609", "#616", "#617", "#618", "#590", "#530", "#531", "#532", "#533", "#475", "#476", "#477",
                      "#478", "#479", "#540", "#470", "#420", "#552", "#422", "#429", "#604", "#456", "#625"]:
            self.assertIn(issue, self.entry)

    def test_owner_wording_for_firmware_and_the_feed(self):
        # The owner's decisions (#648): the Firmware setting stays visible; the feed is off by default, unencrypted.
        for phrase in ["leave it on Denon unless your unit runs custom firmware", "off by default", "unencrypted"]:
            self.assertIn(phrase, self.entry)

    def test_the_lab_is_never_offered(self):
        # The deck panel and the drawn display need hardware or firmware testers don't have: labeled, not available.
        lab = self.entry[self.entry.index("In the lab"):]
        for phrase in ["deck panel", "isn't offered for download", "never includes or distributes Denon's firmware"]:
            self.assertIn(phrase, lab)


class WhatToTest(unittest.TestCase):
    def setUp(self):
        self.text = td.what_to_test(read("docs/TESTFLIGHT.md"))

    def test_fits_app_store_connect(self):
        self.assertLessEqual(len(self.text), 4000)

    def test_is_for_1_1(self):
        self.assertTrue(self.text.startswith("DeckBridge 1.1.0"), self.text[:60])

    def test_names_what_to_try(self):
        for phrase in ["jog display", "Diagnostics › Jog display", "subscription", "Help add a controller"]:
            self.assertIn(phrase, self.text)

    def test_names_what_main_gained(self):
        # #648: what's new since the first What to Test, for testers to try.
        # The Needle Drop strip's fader is its plain touch since #729; Shift + the strip seeks.
        for phrase in ["Needle Drop strip moves the deck's channel fader", "Shift + the strip seeks", "Exact colors on the LC6000", "Key display",
                       "Display feed", "off by default", "unencrypted", "leave it on Denon"]:
            self.assertIn(phrase, self.text)

    def test_never_offers_the_lab(self):
        # The deck panel and custom firmware aren't something a tester can use.
        for phrase in ["deck panel", "Custom firmware", "reflash"]:
            self.assertNotIn(phrase, self.text)

    def test_never_offers_the_led_test(self):
        self.assertNotIn("Test LEDs", self.text)
        self.assertNotIn("LED test", self.text)



class NetworkClaims(unittest.TestCase):
    """The README and the App Review notes hold the site's rule (#632): a sentence saying nothing goes to the network
    names the display feed, which sends the deck in front to the address the DJ sets once it's on (ADR 0011)."""

    def test_every_claim_names_the_display_feed(self):
        for path in ["README.md", "docs/APP_REVIEW.md", "docs/HARDWARE-CHECK.md"]:
            with self.subTest(path):
                self.assertEqual(check_site.network_problems(path, read(path)), [])


if __name__ == "__main__":
    unittest.main()
