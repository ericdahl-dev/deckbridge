"""The deck panel trusts exactly the release keys the updater app trusts (#690, ADR 0012): the panel's list in
lib/release_keys/release_keys.h and the app's in ReleaseKeys.swift must hold the same (id, public key) pairs, so a
release the app accepts is one the panel accepts too. Both hold the owner's primary and backup keys (#689)."""
import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
PANEL = ROOT / "tools/deck-panel/lib/release_keys/release_keys.h"
APP = ROOT / "Packages/FirmwareUpdaterKit/Sources/FirmwareRelease/ReleaseKeys.swift"
PAIR = re.compile(r'\(\s*"(primary|backup)"\s*,\s*"([0-9a-f]{64})"\s*\)|\{\s*"(primary|backup)"\s*,\s*"([0-9a-f]{64})"\s*\}')


def pairs(path):
    found = []
    for match in PAIR.finditer(path.read_text()):
        id_, key = (match.group(1), match.group(2)) if match.group(1) else (match.group(3), match.group(4))
        found.append((id_, key))
    return sorted(found)


class ReleaseKeys(unittest.TestCase):
    def test_the_panel_and_the_app_trust_the_same_keys(self):
        self.assertEqual(pairs(PANEL), pairs(APP))

    def test_the_pattern_reads_both_spellings(self):
        # So an entry can't hide from the comparison by its form.
        self.assertEqual(pairs_of('("primary", "' + "ab" * 32 + '")'), [("primary", "ab" * 32)])
        self.assertEqual(pairs_of('{"backup", "' + "cd" * 32 + '"}'), [("backup", "cd" * 32)])


def pairs_of(text):
    import tempfile
    with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as f:
        f.write(text)
    return pairs(pathlib.Path(f.name))


if __name__ == "__main__":
    unittest.main()
