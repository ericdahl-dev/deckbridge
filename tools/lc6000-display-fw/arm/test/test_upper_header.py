#!/usr/bin/env python3
"""Block B's header, pinned across its two languages (#572): what Python's upper_header seals, block A's own C check
(upper_check) accepts, and what C's upper_build writes, Python's check reads back the same. Each field broken refuses
in both. Runs from `make test` with the pin tool it builds:

  python3 -I arm/test/test_upper_header.py build/upper-pin

Standard library only."""
import os, re, subprocess, sys, tempfile, unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.realpath(__file__)), ".."))  # -I leaves arm/ off sys.path
import upper_header  # noqa: E402

PIN = None
LAYOUT, DRAW, BAND = 0x1A2B3C4D, 0x0808001D, 0x0808001F


def pin(*args, stdin=None):
    return subprocess.run([PIN, *map(str, args)], input=stdin, capture_output=True, check=True).stdout.decode().split()


def c_check(block, layout=LAYOUT):
    """What block A's upper_check says of this B: (draw, band), or None."""
    with tempfile.NamedTemporaryFile() as f:
        f.write(block)
        f.flush()
        out = pin("check", layout, f.name)
    return (int(out[1]), int(out[2])) if out[0] == "ok" else None


def c_build(body, layout=LAYOUT, draw=DRAW, band=BAND):
    """B with this body after its header, written by C's upper_build."""
    return subprocess.run([PIN, "build", str(layout), str(draw), str(band)], input=body, capture_output=True,
                          check=True).stdout


def broken(block):
    """The block with each header field in turn made wrong, and B's own CRC kept right where the field is under it."""
    def word(b, at, value):
        b = bytearray(b)
        b[at:at + 4] = value.to_bytes(4, "little")
        return bytes(b)
    h = upper_header.parse(block)
    yield "marker", word(block, upper_header.MARKER_AT, h.marker ^ 1)
    yield "version", word(block, upper_header.VERSION_AT, h.version + 1)
    yield "length short", word(block, upper_header.LENGTH_AT, upper_header.HEADER - 1)
    yield "length over", word(block, upper_header.LENGTH_AT, upper_header.LIMIT + 1)
    yield "crc", word(block, upper_header.CRC_AT, h.crc ^ 1)
    yield "draw even", upper_header.seal(word(block, upper_header.DRAW_AT, h.draw & ~1))
    yield "draw outside", upper_header.seal(word(block, upper_header.DRAW_AT, upper_header.BASE + len(block) + 1))
    yield "band in header", upper_header.seal(word(block, upper_header.BAND_AT, upper_header.BASE + 1))


class PinTests(unittest.TestCase):
    def test_the_constants_are_cs(self):
        marker, version, header, limit, base = map(int, pin("consts"))
        self.assertEqual((upper_header.MARKER, upper_header.VERSION, upper_header.HEADER, upper_header.LIMIT,
                          upper_header.BASE), (marker, version, header, limit, base))

    def test_what_python_seals_c_accepts(self):
        block = upper_header.build(b"123456789", LAYOUT, DRAW, BAND)
        self.assertEqual(c_check(block), (DRAW, BAND))
        self.assertEqual(upper_header.check(block, LAYOUT), upper_header.parse(block))

    def test_what_c_builds_python_reads_the_same(self):
        block = c_build(b"123456789")
        self.assertEqual(block, upper_header.build(b"123456789", LAYOUT, DRAW, BAND))
        h = upper_header.check(block, LAYOUT)
        self.assertEqual((h.layout, h.draw, h.band, h.length), (LAYOUT, DRAW, BAND, len(block)))

    def test_a_known_crc(self):
        # Worked out apart (Python's zlib.crc32 of b"\x4d\x3c\x2b\x1a\x1d\x00\x08\x08\x1f\x00\x08\x08123456789"):
        # the block test_hook.c has carried since #501.
        self.assertEqual(upper_header.parse(upper_header.build(b"123456789", LAYOUT, DRAW, BAND)).crc, 0x6ACCA34B)

    def test_each_broken_field_refuses_in_both(self):
        good = upper_header.build(b"123456789" * 4, LAYOUT, DRAW, BAND)
        for name, block in broken(good):
            with self.subTest(name):
                self.assertIsNone(c_check(block))
                with self.assertRaises(upper_header.Refused):
                    upper_header.check(block, LAYOUT)

    def test_another_layout_refuses_in_both_and_without_a_layout_python_skips_it(self):
        block = upper_header.build(b"123456789", LAYOUT + 1, DRAW, BAND)
        self.assertIsNone(c_check(block))
        with self.assertRaises(upper_header.Refused):
            upper_header.check(block, LAYOUT)
        # The kit can't know A's layout from B alone (#516): it checks the rest.
        self.assertEqual(upper_header.check(block).layout, LAYOUT + 1)


TOOLS = os.path.normpath(os.path.join(os.path.dirname(os.path.realpath(__file__)), "..", "..", ".."))
# The header's two descriptions, C's one CRC, and this pin (which names what a copy looks like).
OWNERS = {"lc6000-display-fw/arm/upper.h", "lc6000-display-fw/arm/upper_header.py", "lc6000-display-fw/arm/upper_crc.h",
          "lc6000-display-fw/arm/test/test_upper_header.py"}
# What a copy looks like: B's marker as a number, a CRC table, a CRC-32 in a file about block B, or a CRC written
# into B by hand.
COPY = [re.compile(r"0x42574644"), re.compile(r"nibbles\["), re.compile(r"put_word\(upper \+ 12\b")]
CRC = re.compile(r"zlib\.crc32\(")
ABOUT_B = re.compile(r"upper", re.I)


def copies():
    found = set()
    for root, dirs, names in os.walk(TOOLS):
        dirs[:] = [d for d in dirs if d not in ("build", "__pycache__", ".venv")]
        for name in names:
            if not name.endswith((".py", ".c", ".h", ".sh")):
                continue
            path = os.path.join(root, name)
            rel = os.path.relpath(path, TOOLS)
            with open(path, encoding="utf-8", errors="replace") as f:
                text = f.read()
            if any(p.search(text) for p in COPY) or (CRC.search(text) and ABOUT_B.search(text)):
                found.add(rel)
    return found - OWNERS


class OneDescriptionTests(unittest.TestCase):
    def test_no_tool_or_test_carries_its_own_header_or_crc(self):
        self.assertEqual(copies(), set())


if __name__ == "__main__":
    PIN = os.path.abspath(sys.argv.pop(1))
    unittest.main()
