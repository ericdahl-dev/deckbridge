#!/usr/bin/env python3
"""The checks the flash-day wizard's drawn path runs (#468), all on files: nothing here talks to the unit.

  python3 -I drawn_flash.py files UPPER.dfu OWNER.dfu
      Before either typed word: B's file is one element at 0x08080000 whose header checks out the way block A
      checks it, and the owner's image is a wd image at 0x08008000. So the two can't be swapped.
  python3 -I drawn_flash.py upper UPPER.dfu READ.bin
      Judges a read of all of 0x08080000-0x080FFFFF against B's file. Prints, as its first word:
        erased   nothing there yet: the gate before step 1;
        holds    exactly this B, then erased: step 1's read-back, or step 1 already done;
        replace  part of this B (a write cut off), or another B whose header and CRC check out (an older build),
                 then erased: step 1 rewrites it, behind its own typed word.
      Anything else is refused, with the first address that isn't this B.
  python3 -I drawn_flash.py rewrite UPPER.dfu READ.bin OUT.dfu
      Only when `upper` says replace: B's element followed by erased bytes to the end of what the upper flash holds,
      so the write's erase covers an older, longer B too.
  python3 -I drawn_flash.py app OWNER.dfu READ.bin
      Before step 2: "holds" when the app area already holds the owner's image exactly (then step 2 writes nothing),
      else "differs" with the first other address.
  python3 -I drawn_flash.py options READ.bin
      Judges a read of the option bytes (0x1FFFC000, 16 bytes) before step 1: read protection at level 0, sectors
      8-11 not write-protected, one bank. Anything else is refused.

Standard library only."""
import argparse, os, sys

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))  # -I leaves this folder off sys.path (#468)
import build_upper_dfu  # noqa: E402
import dfupatch  # noqa: E402

APP_BASE = 0x08008000


def upper_block(path):
    image = dfupatch.parse(dfupatch.read(path))
    if image.address != build_upper_dfu.UPPER_BASE:
        raise dfupatch.Refused(f"{path} writes at 0x{image.address:08X}; block B's file writes at "
                               f"0x{build_upper_dfu.UPPER_BASE:08X}. Is it the owner's image?")
    try:
        build_upper_dfu.check_block(image.element)
    except dfupatch.Refused as error:
        raise dfupatch.Refused(f"{path} isn't a block B A will take: {error}") from None
    return image.element


def owner_image(path):
    image = dfupatch.parse(dfupatch.read(path))
    if image.address != APP_BASE:
        raise dfupatch.Refused(f"{path} writes at 0x{image.address:08X}; the owner's image writes at "
                               f"0x{APP_BASE:08X}. Is it block B's file?")
    if dfupatch.chip(image.element) != "wd":
        raise dfupatch.Refused(f"{path} isn't a display chip (wd) image")
    return image.element


def files(args):
    block = upper_block(args.upper)
    image = owner_image(args.owner)
    print(f"ok: block B, {len(block)} bytes at 0x{build_upper_dfu.UPPER_BASE:08X}; "
          f"the owner's image, {len(image)} bytes at 0x{APP_BASE:08X}")


def judge(block, read):
    """What the upper flash holds, against this B: (its state line, where what's there ends). Refuses the rest."""
    size = build_upper_dfu.PROOF_SIZE
    if len(read) != size:
        raise dfupatch.Refused(f"the read is {len(read)} bytes, not all {size} of 0x08080000-0x080FFFFF")
    base = build_upper_dfu.UPPER_BASE
    # Where the read first leaves this B: a wrong byte, or where a cut-off write stops.
    first = next((i for i in range(len(block)) if read[i] != block[i]), None)
    if first is None:
        state, end = "holds (exactly this block B, then erased)", len(block)
    elif all(b == 0xFF for b in read[:len(block)]):
        state, end = "erased (nothing there yet)", 0
    elif all(b == 0xFF for b in read[first:len(block)]):
        state, end = "replace (part of this block B: a write cut off; rewrite it)", first
    else:
        length = other_block(read)
        if length is None:
            raise dfupatch.Refused(f"the upper flash is neither erased, this block B, nor a block B whose header and "
                                   f"CRC check out: the first byte that isn't this B is at 0x{base + first:08X}. "
                                   f"Stop; nothing is written over it")
        state, end = "replace (another block B, an older build; rewrite it)", length
    rest = next((i for i in range(end, size) if read[i] != 0xFF), None)
    if rest is not None:
        raise dfupatch.Refused(f"the upper flash holds something past where block B ends: the first other byte is "
                               f"at 0x{base + rest:08X}. Stop; nothing is written over it")
    return state, end


def upper(args):
    state, _ = judge(upper_block(args.upper), dfupatch.read(args.read))
    print(state)


def rewrite(args):
    """Step 1's file over part of a B or an older one: this B, then erased bytes to the end of what's there, so the
    write's erase covers all of it (a DfuSe write erases only the sectors its element covers)."""
    block = upper_block(args.upper)
    state, end = judge(block, dfupatch.read(args.read))
    if not state.startswith("replace"):
        raise dfupatch.Refused(f"nothing to rewrite: the upper flash is {state.split()[0]}")
    if dfupatch.inside(args.output, dfupatch.repository_root()):
        raise dfupatch.Refused("write the rewrite file outside the repository")
    element = block + b"\xff" * max(0, end - len(block))
    with open(args.output, "xb") as f:
        f.write(build_upper_dfu.dfuse(element))
    print(f"wrote {args.output}: block B, then erased to 0x{build_upper_dfu.UPPER_BASE + len(element):08X}")


def other_block(read):
    """The length of a block B from any build (#516: every layout change makes a new one), if the read starts with
    one: B's marker, a length inside the upper flash, and zlib's CRC-32 from +16 matching. Its version may differ."""
    header = build_upper_dfu.upper_header.parse(read)
    if header.marker != build_upper_dfu.UPPER_MARKER or not 20 <= header.length <= len(read):
        return None
    return header.length if build_upper_dfu.upper_header.crc(read, header.length) == header.crc else None


def options(args):
    """The option bytes, bank 1 (0x1FFFC000, 16 bytes; RM0090's option byte table): read protection level 0, sectors
    8-11 not write-protected, one bank, and nWRP meaning write protection (SPRMOD 0)."""
    read = dfupatch.read(args.read)
    if len(read) != 16:
        raise dfupatch.Refused(f"the option byte read is {len(read)} bytes, not 16")
    rdp = read[1]
    if rdp != 0xAA:
        raise dfupatch.Refused(f"read protection is on (RDP 0x{rdp:02X}, not 0xAA, level 0). Stop: this isn't the chip "
                               f"the earlier reads saw")
    half = read[8] | read[9] << 8
    if half & 0x8000:
        raise dfupatch.Refused("SPRMOD is 1: the protection bits mean read-out protection, not what's writable. Stop")
    if half & 0x4000:
        raise dfupatch.Refused("the flash is set to two banks (DB1M 1), not the single bank B's addresses assume. Stop")
    locked = [sector for sector in range(8, 12) if not half >> sector & 1]
    if locked:
        raise dfupatch.Refused(f"write protection is on for sector{'s' if len(locked) > 1 else ''} "
                               f"{', '.join(map(str, locked))} (nWRP 0), where block B goes. Stop")
    print("ok (read protection off, level 0; sectors 8-11 writable; one bank)")


def app(args):
    """Before step 2 (#468): a read of the app area against the owner's image. "holds" when it's already there
    exactly (a rewrite of block B alone), so step 2 writes nothing; "differs" with the first other address."""
    image = owner_image(args.owner)
    read = dfupatch.read(args.read)
    if len(read) != len(image):
        raise dfupatch.Refused(f"the read is {len(read):#x} bytes, the owner's image {len(image):#x}")
    first = next((i for i in range(len(image)) if read[i] != image[i]), None)
    if first is None:
        print("holds (exactly the owner's image)")
    else:
        print(f"differs (the first other byte is at 0x{APP_BASE + first:08X})")


NO_PROBE = "NO PROBE"

NO_PROBE_RISK = f"""Without an ST-Link probe (#433), one failure has no way back over USB:
  If the new image starts but can't take the update-mode message, the jog display stays dark until a probe is
  connected. Denon's updater and this wizard both need that message to reach the display chip.
What makes that unlikely (from the code and the emulator, not yet from your unit):
  - Our code runs only after our own first message: with no host, the image behaves like stock.
  - Stock's own update-mode message is handled before our hook.
  - Every write is read back and compared before the power cycle.
Even then, the top panel and the rest of the unit keep working: only the jog display would be affected.
Type {NO_PROBE} to go on without a probe; anything else stops here."""


def no_probe_risk(_args):
    print(NO_PROBE_RISK)


def no_probe(args):
    """Goes on without a probe only on the whole phrase, typed (#468)."""
    if args.typed.strip() != NO_PROBE:
        raise dfupatch.Refused(f"you typed {args.typed.strip()!r}, not {NO_PROBE}: stopping before anything is sent")
    print(f"ok ({NO_PROBE}: going on without a probe)")


def main(argv=None):
    parser = argparse.ArgumentParser(description="Checks for the drawn flash: files and reads, never the unit.")
    commands = parser.add_subparsers(dest="command", required=True)
    pair = commands.add_parser("files", help="B's file at 0x08080000 and the owner's image at 0x08008000")
    pair.add_argument("upper")
    pair.add_argument("owner")
    pair.set_defaults(run=files)
    state = commands.add_parser("upper", help="judge a read of 0x08080000-0x080FFFFF against B's file")
    state.add_argument("upper")
    state.add_argument("read")
    state.set_defaults(run=upper)
    over = commands.add_parser("rewrite", help="step 1's file over part of a B or an older one")
    over.add_argument("upper")
    over.add_argument("read")
    over.add_argument("output")
    over.set_defaults(run=rewrite)
    bytes_ = commands.add_parser("options", help="judge a read of the option bytes at 0x1FFFC000 (16 bytes)")
    bytes_.add_argument("read")
    bytes_.set_defaults(run=options)
    app_state = commands.add_parser("app", help="judge a read of the app area against the owner's image")
    app_state.add_argument("owner")
    app_state.add_argument("read")
    app_state.set_defaults(run=app)
    risk = commands.add_parser("no-probe-risk", help="what flashing without an ST-Link risks, in plain words")
    risk.set_defaults(run=no_probe_risk)
    phrase = commands.add_parser("no-probe", help="goes on without a probe only on the typed phrase NO PROBE")
    phrase.add_argument("typed")
    phrase.set_defaults(run=no_probe)
    args = parser.parse_args(argv)
    try:
        args.run(args)
    except (dfupatch.Refused, OSError) as error:
        print(f"refused: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
