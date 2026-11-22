#!/usr/bin/env python3
"""Block B's header (#501, #572), the one Python description of it: arm/upper.h is the C one, and
arm/test/test_upper_header.py pins the two together. Every tool and test that reads, builds or seals B's header
imports this.

All fields are little-endian 32-bit words:

  +0  marker   "DFWB"
  +4  version  VERSION; changes whenever this header or the entry table changes
  +8  length   all of B in bytes, header included
  +12 crc      CRC-32 (zlib's) of B from +16 (the layout on) up to length
  +16 layout   the dfw_unit layout B was built for (#516), which only block A can judge
  +20 draw     B's draw entry, Thumb code inside B
  +24 band     B's band entry (#524), Thumb code inside B

Standard library only."""
import collections, struct, zlib

BASE = 0x08080000
LIMIT = 0x80000  # sectors 8-11
MARKER = 0x42574644  # "DFWB"
VERSION = 4
HEADER = 28
MARKER_AT, VERSION_AT, LENGTH_AT, CRC_AT, LAYOUT_AT, DRAW_AT, BAND_AT = range(0, HEADER, 4)
CRC_FROM = LAYOUT_AT

Header = collections.namedtuple("Header", "marker version length crc layout draw band")


class Refused(ValueError):
    """B's header doesn't check out; the message says which part, in plain words."""


def parse(block):
    """The header's fields as they are, checked or not."""
    if len(block) < HEADER:
        raise Refused(f"block B is {len(block)} bytes, shorter than its {HEADER}-byte header")
    return Header(*struct.unpack_from("<7I", block))


def crc(block, length):
    return zlib.crc32(bytes(block[CRC_FROM:length]))


def seal(block):
    """B with its length and CRC filled in from its bytes (after the link)."""
    data = bytearray(block)
    if parse(data).marker != MARKER:
        raise Refused("this isn't block B: no \"DFWB\" header at its start")
    if len(data) > LIMIT:
        raise Refused(f"block B is {len(data)} bytes, over the upper flash's {LIMIT}")
    struct.pack_into("<I", data, LENGTH_AT, len(data))
    struct.pack_into("<I", data, CRC_AT, crc(data, len(data)))
    return bytes(data)


def build(body, layout, draw, band):
    """A sealed B: this header, then `body`."""
    return seal(struct.pack("<7I", MARKER, VERSION, 0, 0, layout, draw, band) + bytes(body))


def check(block, layout=None):
    """The header, if B checks out the way block A checks it on the chip (arm/upper.c); else Refused. Without a
    `layout` the layout word isn't judged: only block A, built from the same src/dfw.h, can (#516)."""
    h = parse(block)
    if h.marker != MARKER:
        raise Refused("the block doesn't start with B's marker \"DFWB\": it isn't block B")
    if h.version != VERSION:
        raise Refused(f"the block is header version {h.version}, and block A takes version {VERSION}")
    if not HEADER <= h.length <= LIMIT:
        raise Refused(f"the block's length, {h.length}, is outside {HEADER}-{LIMIT}")
    if h.length > len(block):
        raise Refused(f"the block says it is {h.length} bytes, and only {len(block)} are here")
    if crc(block, h.length) != h.crc:
        raise Refused("the block's CRC doesn't match its bytes")
    if layout is not None and h.layout != layout:
        raise Refused(f"the block was built for dfw_unit layout 0x{h.layout:08X}, and block A has 0x{layout:08X}")
    for name, entry in (("draw", h.draw), ("band", h.band)):
        if not (entry & 1 and BASE + HEADER <= entry < BASE + h.length):
            raise Refused(f"the block's {name} entry, 0x{entry:08X}, isn't Thumb code inside it")
    return h
