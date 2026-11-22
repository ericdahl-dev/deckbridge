#!/usr/bin/env python3
"""Tests for scripts/check_domain_docs.py on tiny repos written to a temporary folder.
Run: python3 -I scripts/test_check_domain_docs.py"""
import os, sys, tempfile, unittest

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import check_domain_docs

GLOSSARY = """# DeckBridge

The bridge.

## Language

**Deck layer**:
One of a controller's decks.
_Avoid_: bank

**Resend**:
Asking Syndicate for its state again.
"""

ADR = "# The bridge talks OSC\n\n2026-11-16. We use OSC, not MIDI, because of the 14-bit jog (#30).\n"


class CheckDomainDocsTests(unittest.TestCase):
    def repo(self, files):
        root = tempfile.mkdtemp()
        for name, text in files.items():
            path = os.path.join(root, name)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w") as f:
                f.write(text)
        return root

    def good(self, **changes):
        files = {
            "GLOSSARY.md": GLOSSARY,
            "App/Bridge.swift": "// the deck layer in front; a resend after wake\n",
            "docs/adr/0001-osc-only.md": ADR,
        }
        files.update(changes)
        return {k: v for k, v in files.items() if v is not None}

    def test_good_docs_pass(self):
        self.assertEqual(check_domain_docs.problems(self.repo(self.good())), [])

    def test_a_term_used_nowhere_else_is_stale(self):
        root = self.repo(self.good(**{"App/Bridge.swift": "// the deck layer in front\n"}))
        self.assertEqual(check_domain_docs.problems(root), ['GLOSSARY.md: "Resend" isn\'t used anywhere in the code or docs'])

    def test_the_glossary_and_build_output_dont_count_as_use(self):
        root = self.repo(self.good(**{"App/Bridge.swift": "// the deck layer\n", "build/out.txt": "resend\n",
                                      ".git/HEAD": "resend\n"}))
        self.assertEqual(check_domain_docs.problems(root), ['GLOSSARY.md: "Resend" isn\'t used anywhere in the code or docs'])

    def test_the_glossary_must_exist_and_define_terms(self):
        self.assertEqual(check_domain_docs.problems(self.repo(self.good(**{"GLOSSARY.md": None}))), ["GLOSSARY.md: missing"])
        self.assertEqual(check_domain_docs.problems(self.repo(self.good(**{"GLOSSARY.md": "# DeckBridge\n"}))),
                         ["GLOSSARY.md: defines no terms (**Term**: lines)"])

    def test_an_adr_needs_a_title_a_date_and_an_issue(self):
        root = self.repo(self.good(**{"docs/adr/0001-osc-only.md": "We use OSC.\n"}))
        self.assertEqual(check_domain_docs.problems(root), [
            "docs/adr/0001-osc-only.md: doesn't start with a # title",
            "docs/adr/0001-osc-only.md: has no date (YYYY-MM-DD)",
            "docs/adr/0001-osc-only.md: links no issue (#N)",
        ])

    def test_adrs_are_numbered_from_0001_without_gaps(self):
        root = self.repo(self.good(**{"docs/adr/0003-later.md": ADR}))
        self.assertEqual(check_domain_docs.problems(root), ["docs/adr: numbers skip 0002"])
        root = self.repo(self.good(**{"docs/adr/osc.md": ADR}))
        self.assertEqual(check_domain_docs.problems(root), ["docs/adr/osc.md: isn't named NNNN-slug.md"])


class CIRunsTheCheckTests(unittest.TestCase):
    def test_ci_runs_the_domain_docs_check_and_its_tests(self):
        ci = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".github", "workflows", "ci.yml")
        with open(ci, encoding="utf-8") as f:
            text = f.read()
        self.assertIn("python3 -I scripts/test_check_domain_docs.py", text)
        self.assertIn("python3 -I scripts/check_domain_docs.py", text)


if __name__ == "__main__":
    unittest.main()
