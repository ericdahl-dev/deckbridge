#!/usr/bin/env python3
"""Patch an LC6000 PRIME firmware image (wd or tp) inside its DfuSe file, and fix its checksums.

  python3 -I dfupatch.py verify IN.dfu
  python3 -I dfupatch.py apply IN.dfu PATCH.txt OUT.dfu
  python3 -I dfupatch.py place IN.dfu BLOCK.bin OUT.dfu

Standard library only. See README.md in this folder."""
import argparse, os, struct, sys, zlib
from dataclasses import dataclass

PREFIX_SIZE = 11
TARGET_PREFIX_SIZE = 274
ELEMENT_HEADER_SIZE = 8
SUFFIX_SIZE = 16

TRAILER_SIZE = 32
TRAILER_MAGIC = 0xDEADBEEF
END_TOKEN = b"EndOfFlashToken\x00"

# wd 00.50's own padding: 0xFF from the end of its data to the trailer, inside the CRC range (#466). Our block goes
# here, so the hook's stubs are always present with the hook and are covered by the image's own CRC.
PAD_START, PAD_END = 0x0807DC00, 0x0807FFE0
# Our block's two fixed entries, which the drawn-display hook patch calls (#467). The linker script puts them here.
HOOK_COMMAND_ENTRY, HOOK_RENDER_ENTRY = 0x0807DC00, 0x0807DC40


def thumb_bl(at, target):
    """The 4-byte Thumb-2 `bl target` placed at `at` (ARMv7-M encoding T1), little-endian halfwords."""
    if at % 2 or target % 2:
        raise Refused("a Thumb BL needs even addresses for both the call and its target")
    offset = target - (at + 4)
    if not -(1 << 24) <= offset < (1 << 24):
        raise Refused(f"0x{target:08X} is out of a BL's reach from 0x{at:08X} (+/-16 MB)")
    s = (offset >> 24) & 1
    j1 = (1 - ((offset >> 23) & 1)) ^ s
    j2 = (1 - ((offset >> 22) & 1)) ^ s
    first = 0xF000 | (s << 10) | ((offset >> 12) & 0x3FF)
    second = 0xD000 | (j1 << 13) | (j2 << 11) | ((offset >> 1) & 0x7FF)
    return struct.pack("<HH", first, second)


class Refused(Exception):
    """The input or the patch isn't one this tool can handle safely."""


@dataclass
class DfuSeImage:
    address: int
    element: bytes
    head: bytes  # everything before the element bytes, kept verbatim
    suffix_head: bytes  # the suffix minus its CRC, kept verbatim


def suffix_crc(data):
    return zlib.crc32(data) ^ 0xFFFFFFFF


_REVERSED_BYTES = bytes(int(f"{b:08b}"[::-1], 2) for b in range(256))


def stm32_crc(data, crc=0xFFFFFFFF):
    """The STM32 hardware CRC unit: CRC-32 poly 0x04C11DB7, from 0xFFFFFFFF, little-endian 32-bit words,
    no reflection, no final XOR. Computed with zlib's reflected CRC-32 on the bit-reversed big-endian bytes (#567):
    the same CRC mirrored, about 100 times faster than bit by bit in Python, which matters for 480 KB images."""
    if len(data) % 4:
        raise ValueError("the STM32 CRC unit takes whole 32-bit words")
    big_endian = bytearray(len(data))
    for i in range(4):
        big_endian[i::4] = data[3 - i::4]
    mirrored = zlib.crc32(bytes(big_endian).translate(_REVERSED_BYTES), _reverse32(crc) ^ 0xFFFFFFFF) ^ 0xFFFFFFFF
    return _reverse32(mirrored)


def _reverse32(value):
    return int(f"{value:032b}"[::-1], 2)


def chip(element):
    """Which chip's image this is, from its trailer: "wd" has the 0xDEADBEEF magic, a length and a CRC; "tp" has
    only the end token, the one thing its startup stage checks (#434). Refuses an image without the token."""
    size = len(element)
    if size < TRAILER_SIZE or size % 4 or element[-16:] != END_TOKEN:
        raise Refused("the image doesn't end with the 32-byte EndOfFlashToken trailer")
    return "wd" if struct.unpack_from("<I", element, size - 28)[0] == TRAILER_MAGIC else "tp"


def covered_length(element):
    """The number of bytes the wd trailer CRC covers, once the trailer is known good. Refuses anything else."""
    size = len(element)
    if chip(element) != "wd":
        raise Refused("this is a tp image: it has no CRC trailer")
    _, covered, stored = struct.unpack_from("<III", element, size - 28)
    if covered != size - 20:
        raise Refused("the wd trailer's length field isn't the image size less 20")
    if stm32_crc(element[:covered]) != stored:
        raise Refused("the input's trailer CRC doesn't match its image: refusing to build on it")
    return covered


def build(image, element):
    """Serializes the DfuSe file around a new element of the same size, with a fresh suffix CRC."""
    data = image.head + element + image.suffix_head
    return data + struct.pack("<I", suffix_crc(data))


def parse_patch(patch_text):
    """A patch description: one `ADDRESS OLD-HEX NEW-HEX` per line, `#` starts a comment.
    Returns (address, old bytes, new bytes) tuples."""
    edits = []
    for number, line in enumerate(patch_text.splitlines(), 1):
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        try:
            address, old, new = line.split()
            edit = (int(address, 16), bytes.fromhex(old), bytes.fromhex(new))
        except ValueError:
            raise Refused(f"patch line {number} isn't `ADDRESS OLD-HEX NEW-HEX`: {line!r}") from None
        if not edit[1] or len(edit[1]) != len(edit[2]):
            raise Refused(f"patch line {number}: old and new bytes must have the same, non-zero length")
        edits.append(edit)
    return edits


def apply_edits(element, address, edits):
    """Writes each edit into the element after checking its old bytes. Never touches the trailer."""
    trailer_start = address + len(element) - TRAILER_SIZE
    taken = []
    for at, old, new in edits:
        end = at + len(old)
        if at < address or end > address + len(element):
            raise Refused(f"patch at 0x{at:08X} is outside the image (0x{address:08X}-0x{address + len(element):08X})")
        if end > trailer_start:
            raise Refused(f"patch at 0x{at:08X} reaches into the trailer at 0x{trailer_start:08X}; the tool writes it")
        if any(at < other_end and other_at < end for other_at, other_end in taken):
            raise Refused(f"patch at 0x{at:08X} overlaps another patch line")
        taken.append((at, end))
        offset = at - address
        if element[offset:offset + len(old)] != old:
            found = element[offset:offset + len(old)].hex()
            raise Refused(f"old bytes at 0x{at:08X} are {found}, not {old.hex()}: wrong image or wrong patch")
        element[offset:offset + len(new)] = new


def patch(data, patch_text):
    """Applies a patch description to a DfuSe file and returns the new file. A wd image gets its trailer CRC
    recomputed; a tp image has none, and keeps its trailer as it is. Both get a fresh DfuSe suffix CRC."""
    image = parse(data)
    covered = covered_length(image.element) if chip(image.element) == "wd" else None
    element = bytearray(image.element)
    apply_edits(element, image.address, parse_patch(patch_text))
    if covered is not None:
        struct.pack_into("<I", element, covered, stm32_crc(bytes(element[:covered])))
    return build(image, bytes(element))


def place(data, block):
    """Writes a raw block at the start of the wd image's padding (PAD_START) and returns the new file, with the
    trailer CRC and the DfuSe suffix CRC recomputed. Refuses unless every byte it writes over is still 0xFF."""
    image = parse(data)
    if chip(image.element) != "wd":
        raise Refused("place needs a wd image: the block goes into the wd padding, under its CRC")
    covered = covered_length(image.element)
    if not block:
        raise Refused("the block is empty")
    if not (image.address <= PAD_START and PAD_END <= image.address + len(image.element) - TRAILER_SIZE):
        raise Refused(f"this image doesn't hold the padding 0x{PAD_START:08X}-0x{PAD_END - 1:08X}")
    if len(block) > PAD_END - PAD_START:
        raise Refused(f"the block is {len(block)} bytes, too big for the {PAD_END - PAD_START}-byte padding")
    start = PAD_START - image.address
    element = bytearray(image.element)
    if any(b != 0xFF for b in element[start:start + len(block)]):
        raise Refused(f"the padding at 0x{PAD_START:08X} isn't all 0xFF: wrong image, or a block is already there")
    element[start:start + len(block)] = block
    struct.pack_into("<I", element, covered, stm32_crc(bytes(element[:covered])))
    return build(image, bytes(element))


def parse(data):
    """Reads a one-target, one-element DfuSe file. Refuses anything else."""
    if len(data) < PREFIX_SIZE + TARGET_PREFIX_SIZE + ELEMENT_HEADER_SIZE + SUFFIX_SIZE or data[:5] != b"DfuSe":
        raise Refused("not a DfuSe file")
    if suffix_crc(data[:-4]) != struct.unpack_from("<I", data, len(data) - 4)[0]:
        raise Refused("the DfuSe suffix CRC doesn't match the file")
    suffix = data[-SUFFIX_SIZE:]
    if suffix[8:11] != b"UFD" or suffix[11] != SUFFIX_SIZE:
        raise Refused("the DfuSe suffix isn't the 16-byte UFD suffix")
    version, image_size, targets = struct.unpack_from("<BIB", data, 5)
    if version != 1:
        raise Refused(f"DfuSe format version {version}, expected 1")
    if targets != 1:
        raise Refused(f"{targets} targets, expected exactly one target")
    if image_size != len(data):  # ST's tool counts the whole file, suffix included
        raise Refused("the DfuSe image size doesn't match the file length")
    if data[PREFIX_SIZE:PREFIX_SIZE + 6] != b"Target":
        raise Refused("no Target prefix where one target should start")
    target_size, elements = struct.unpack_from("<II", data, PREFIX_SIZE + 266)
    if elements != 1:
        raise Refused(f"{elements} elements, expected exactly one element")
    start = PREFIX_SIZE + TARGET_PREFIX_SIZE
    address, size = struct.unpack_from("<II", data, start)
    if target_size != ELEMENT_HEADER_SIZE + size or start + ELEMENT_HEADER_SIZE + size != len(data) - SUFFIX_SIZE:
        raise Refused("the element size doesn't match the target and file sizes")
    body = start + ELEMENT_HEADER_SIZE
    return DfuSeImage(address, bytes(data[body:body + size]), bytes(data[:body]), bytes(suffix[:-4]))


def repository_root():
    """The git working tree this tool lives in, or its own folder when it has been copied out of one."""
    here = os.path.dirname(os.path.realpath(__file__))
    path = here
    while True:
        if os.path.exists(os.path.join(path, ".git")):
            return path
        parent = os.path.dirname(path)
        if parent == path:
            return here
        path = parent


def inside(path, root):
    path, root = os.path.realpath(path), os.path.realpath(root)
    return os.path.commonpath([path, root]) == root


def read(path, mode="rb"):
    with open(path, mode) as f:
        return f.read()


def verify(args):
    data = read(args.input)
    image = parse(data)
    kind = chip(image.element)
    if patch(data, "") != data:
        raise Refused("a no-op patch didn't reproduce the input bit for bit")
    if kind == "tp":
        print("ok: tp image, EndOfFlashToken present; it has no checksum (its startup stage checks only the token); "
              "a no-op patch reproduces the file bit for bit")
        return
    covered = covered_length(image.element)
    crc = struct.unpack_from("<I", image.element, covered)[0]
    print(f"ok: trailer CRC 0x{crc:08X} over {covered:#x} bytes; a no-op patch reproduces the file bit for bit")


def bl_target(at, code):
    """The target of a 4-byte Thumb-2 `bl` at `at`, or None if `code` isn't one (the inverse of thumb_bl)."""
    if len(code) != 4:
        return None
    first, second = struct.unpack("<HH", code)
    if first & 0xF800 != 0xF000 or second & 0xD000 != 0xD000:
        return None
    s = (first >> 10) & 1
    i1 = 1 - (((second >> 13) & 1) ^ s)
    i2 = 1 - (((second >> 11) & 1) ^ s)
    offset = (s << 24) | (i1 << 23) | (i2 << 22) | ((first & 0x3FF) << 12) | ((second & 0x7FF) << 1)
    if s:
        offset -= 1 << 25
    return at + 4 + offset


def refuse_calls_into_empty_padding(image, edits):
    """A call into the padding while it's still 0xFF faults on the chip under a valid CRC, before any way back over
    USB (#434, #467): the hook must never go out without our block."""
    for at, _, new in edits:
        target = bl_target(at, new)
        if target is None or not PAD_START <= target < PAD_END:
            continue
        offset = target - image.address
        if image.element[offset:offset + 2] == b"\xff\xff":
            raise Refused(f"the call at 0x{at:08X} goes to 0x{target:08X} in empty padding: place our block "
                          "in the same image (build_owner_image.py), never the hook alone")


def apply(args):
    if inside(args.output, repository_root()):
        raise Refused("write the patched image outside the repository: patched images are never committed")
    if os.path.exists(args.output):
        raise Refused(f"{args.output} already exists; not overwriting it")
    patch_text = read(args.patch, "r")
    out = patch(read(args.input), patch_text)
    image = parse(out)
    refuse_calls_into_empty_padding(image, parse_patch(patch_text))
    with open(args.output, "xb") as f:
        f.write(out)
    if chip(image.element) == "tp":
        print(f"wrote {args.output}: tp image, trailer unchanged (no trailer CRC), "
              f"DfuSe suffix CRC 0x{suffix_crc(out[:-4]):08X}")
        return
    crc = struct.unpack_from("<I", image.element, covered_length(image.element))[0]
    print(f"wrote {args.output}: new trailer CRC 0x{crc:08X}, DfuSe suffix CRC 0x{suffix_crc(out[:-4]):08X}")


def place_command(args):
    if inside(args.output, repository_root()):
        raise Refused("write the image outside the repository: built images are never committed")
    if os.path.exists(args.output):
        raise Refused(f"{args.output} already exists; not overwriting it")
    block = read(args.block)
    out = place(read(args.input), block)
    image = parse(out)
    with open(args.output, "xb") as f:
        f.write(out)
    crc = struct.unpack_from("<I", image.element, covered_length(image.element))[0]
    print(f"wrote {args.output}: {len(block)} bytes at 0x{PAD_START:08X}, new trailer CRC 0x{crc:08X}, "
          f"DfuSe suffix CRC 0x{suffix_crc(out[:-4]):08X}")


def compare(args):
    """Checks a raw read-back of the app area (dfu-util -U) against the image in a DfuSe file."""
    image = parse(read(args.input))
    readback = read(args.readback)
    if len(readback) != len(image.element):
        raise Refused(f"the read-back is {len(readback):#x} bytes, the image is {len(image.element):#x}")
    differing = [offset for offset in range(len(readback)) if readback[offset] != image.element[offset]]
    if differing:
        count = len(differing)
        raise Refused(f"{count} byte{'' if count == 1 else 's'} differ{'s' if count == 1 else ''}, "
                      f"the first at 0x{image.address + differing[0]:08X}")
    print(f"match: {len(readback):#x} bytes at 0x{image.address:08X}")


def main(argv=None):
    parser = argparse.ArgumentParser(description="Patch an LC6000 PRIME wd or tp image in its DfuSe file.")
    commands = parser.add_subparsers(dest="command", required=True)
    check = commands.add_parser("verify", help="check a file's CRCs and that a no-op patch round-trips")
    check.add_argument("input")
    check.set_defaults(run=verify)
    write = commands.add_parser("apply", help="apply a patch description and write a new .dfu")
    write.add_argument("input")
    write.add_argument("patch")
    write.add_argument("output")
    write.set_defaults(run=apply)
    put = commands.add_parser("place", help="write a raw block into the wd padding at 0x0807DC00")
    put.add_argument("input")
    put.add_argument("block")
    put.add_argument("output")
    put.set_defaults(run=place_command)
    match = commands.add_parser("compare", help="check a raw read-back of the app area against a .dfu's image")
    match.add_argument("input")
    match.add_argument("readback")
    match.set_defaults(run=compare)
    args = parser.parse_args(argv)
    try:
        args.run(args)
    except (Refused, OSError) as error:
        print(f"refused: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
