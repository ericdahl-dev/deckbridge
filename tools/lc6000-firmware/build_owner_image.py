#!/usr/bin/env python3
"""Build the drawn-display wd image for the owner's unit (#467): the stock 00.50 file, the hook patch, our block placed
in the image's padding, and both CRCs recomputed. The core voltage fix (#438) is opt-in.

  python3 -I build_owner_image.py STOCK.dfu BLOCK.bin OUT.dfu [--show-slot-16] [--vos-scale-1]

STOCK.dfu is the owner's own stock file (jc20_wd_update_00_50_3A7CE2CA.dfu); BLOCK.bin is
tools/lc6000-display-fw/build/arm/block.bin (`make -C tools/lc6000-display-fw arm`). OUT.dfu must be outside the
repository. Nothing here talks to the unit. Standard library only."""
import argparse, os, struct, sys

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))  # -I leaves this folder off sys.path (#468)
import build_record  # noqa: E402
import dfupatch  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
HOOK_PATCH = os.path.join(HERE, "patches", "wd-00.50-drawn-hook.patch")
VOS_PATCH = os.path.join(HERE, "patches", "wd-00.50-vos-scale-1.patch")
SLOT_16_PATCH = os.path.join(HERE, "patches", "wd-00.50-show-slot-16.patch")
MARKER = 0x31574644  # "DFW1": the block's last word, which the entries check (HOOK_MARKER)


def build(stock, block, vos=False, slot_16=False):
    """Returns the owner's image: hook patch (plus the VOS fix if asked), then our block in the padding."""
    size = dfupatch.PAD_END - dfupatch.PAD_START
    if len(block) != size:
        raise dfupatch.Refused(f"the block is {len(block)} bytes; a built block fills the {size}-byte padding")
    if struct.unpack_from("<I", block, size - 4)[0] != MARKER:
        raise dfupatch.Refused("the block doesn't end with our marker: the hook must never go out without its block")
    text = dfupatch.read(HOOK_PATCH, "r")
    if vos:
        text += "\n" + dfupatch.read(VOS_PATCH, "r")
    if slot_16:
        text += "\n" + dfupatch.read(SLOT_16_PATCH, "r")
    return dfupatch.place(dfupatch.patch(stock, text), block)


def main(argv=None):
    parser = argparse.ArgumentParser(description="Build the drawn-display wd image for the owner's unit.")
    parser.add_argument("stock")
    parser.add_argument("block")
    parser.add_argument("output")
    parser.add_argument("--vos-scale-1", action="store_true", help="also apply the core voltage fix (#438)")
    slot = parser.add_mutually_exclusive_group()
    slot.add_argument("--show-slot-16", dest="show_slot_16", action="store_true", default=None,
                      help="keep the slot 16 patch (#425); the owner's unit runs it now")
    slot.add_argument("--no-show-slot-16", dest="show_slot_16", action="store_false",
                      help="build without the slot 16 patch")
    args = parser.parse_args(argv)
    try:
        if args.show_slot_16 is None:
            raise dfupatch.Refused("choose slot 16: --show-slot-16 (your unit runs it now; image mode uploads 16 "
                                   "slots) or --no-show-slot-16. There is no default (#425, #467)")
        if dfupatch.inside(args.output, dfupatch.repository_root()):
            raise dfupatch.Refused("write the image outside the repository: built images are never committed")
        if os.path.exists(args.output):
            raise dfupatch.Refused(f"{args.output} already exists; not overwriting it")
        out = build(dfupatch.read(args.stock), dfupatch.read(args.block), vos=args.vos_scale_1, slot_16=args.show_slot_16)
        with open(args.output, "xb") as f:
            f.write(out)
    except (dfupatch.Refused, OSError) as error:
        print(f"refused: {error}", file=sys.stderr)
        return 1
    image = dfupatch.parse(out)
    crc = struct.unpack_from("<I", image.element, dfupatch.covered_length(image.element))[0]
    extra = " and the VOS Scale 1 fix" if args.vos_scale_1 else " (VOS fix not applied; --vos-scale-1 adds it)"
    if args.show_slot_16:
        extra += ", with slot 16"
    print(f"wrote {args.output}: hook patch{extra}, block at 0x{dfupatch.PAD_START:08X}, "
          f"new trailer CRC 0x{crc:08X}, DfuSe suffix CRC 0x{dfupatch.suffix_crc(out[:-4]):08X}")
    print(build_record.carry(args.block, args.output, "block_a"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
