"""Pins the labels docs/APP_REVIEW.md quotes to the strings the app really shows (#29), so a renamed button can't
leave App Review following words that no longer exist. Each pair is what the notes say and where the app says it.
    python3 -I scripts/test_app_review.py
"""
import os, unittest

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")

# (what APP_REVIEW.md quotes, the source file, the literal there)
LABELS = [
    ('"Demo controller: Off"', "App/StatusPanel.swift", 'Button("Demo controller: \\(status.demo ? "On" : "Off")")'),
    ('"Demo controller: On"', "App/StatusPanel.swift", 'Button("Demo controller: \\(status.demo ? "On" : "Off")")'),
    ('"Diagnostics…"', "App/StatusPanel.swift", '"Diagnostics…"'),
    ('"Settings…"', "App/StatusPanel.swift", '"Settings…"'),
    ('"Controller not found?"', "Packages/ControllerBridgeKit/Sources/ControllerBridgePresentation/ProfilePicker.swift",
     '"Controller not found?"'),
    ('"Demo controller" chosen', "Packages/ControllerBridgeKit/Sources/ControllerBridgeCapture/DemoCapture.swift",
     'deviceName = "Demo controller"'),
    ("click Start", "App/CaptureView.swift", '"Start"'),
    ("Click Next", "App/CaptureView.swift", '"Next"'),
    ("or Redo or Skip", "App/CaptureView.swift", '"Redo"'),
    ("or Redo or Skip", "App/CaptureView.swift", '"Skip"'),
    ("offers Save…", "App/CaptureView.swift", '"Save…"'),
    ('"Email to DeckBridge"', "App/CaptureView.swift", '"Email to DeckBridge"'),
    ('the "Jog display" tab', "Packages/ControllerBridgeKit/Sources/ControllerBridgePresentation/DiagnosticsPresentation.swift",
     '"Jog display"'),
    ('"Demo Track"', "Packages/ControllerBridgeKit/Sources/ControllerBridgeCore/Demo.swift", '.string("Demo Track")'),
]


def read(path):
    with open(os.path.join(ROOT, path), encoding="utf-8") as f:
        return f.read()


class AppReviewLabelTests(unittest.TestCase):
    def test_every_quoted_label_is_in_the_notes_and_in_the_app(self):
        notes = read("docs/APP_REVIEW.md")
        for quoted, path, literal in LABELS:
            with self.subTest(label=quoted):
                self.assertIn(quoted, notes, f"APP_REVIEW.md no longer says {quoted}")
                self.assertIn(literal, read(path), f"{path} no longer has {literal}")

    def test_the_settings_tabs_named_are_the_app_s(self):
        notes = read("docs/APP_REVIEW.md")
        self.assertIn("Controller, Decks, Syndicate and General", notes)
        tabs = read("Packages/ControllerBridgeKit/Sources/ControllerBridgeCore/SettingsTabs.swift")
        for tab in ["Controller", "Decks", "Syndicate", "General"]:
            self.assertIn(f'"{tab}"', tabs)


class AppReviewDisclaimerTests(unittest.TestCase):
    def test_the_disclaimer_names_the_company_as_the_user_decided(self):
        # The user's decision (#29): Syndicate's maker is "Untitled Audio Syndicate Ltd." in the not-affiliated line.
        self.assertIn("isn't affiliated with or endorsed by Untitled Audio Syndicate Ltd. or Denon DJ.",
                      read("docs/APP_REVIEW.md"))


if __name__ == "__main__":
    unittest.main()
