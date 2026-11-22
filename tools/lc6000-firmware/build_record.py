#!/usr/bin/env python3
"""How blocks A and B were built, recorded by `make arm` and read by the kit (#572), so the owner is never asked.

  python3 -I build_record.py write BLOCK.bin UPPER.bin --draw ARM_DRAW --proven ARM_UPPER_PROVEN RECORD.json
  python3 -I build_record.py check RECORD.json OWNER.dfu UPPER.dfu

`check` trusts the record only for the bytes it names: the sha1 of block A found inside the owner's image and the
sha1 of block B inside its .dfu must both be the record's, which also shows A and B are from the same build. Then
A must have been built to draw (ARM_DRAW=1) and to read B (ARM_UPPER_PROVEN=1). A record that is missing, unreadable
or for other bytes refuses; nothing is assumed and no one is asked.

The record holds only build facts: it lives next to the blocks, never on the unit. Recording the flags on the unit
itself, readable from a read, would take new header fields: that waits for #570's two-block flash.

Nothing here talks to the unit. Standard library only."""
import argparse, collections, hashlib, json, os, sys

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))  # -I leaves this folder off sys.path (#468)
import dfupatch  # noqa: E402
import drawn_flash  # noqa: E402
upper_header = drawn_flash.build_upper_dfu.upper_header

VERSION = 1
Judged = collections.namedtuple("Judged", "draw proven a_sha1 b_sha1")


def sha1(data):
    return hashlib.sha1(data).hexdigest()


def record_of(a, b, draw, proven):
    """The record for these two built blocks and the flags they were built with."""
    header = upper_header.parse(b)
    return {
        "record": VERSION,
        "block_a": {"sha1": sha1(a), "length": len(a), "draw": str(draw), "proven": str(proven)},
        "block_b": {"sha1": sha1(b), "length": len(b), "layout": header.layout, "header_version": header.version},
    }


def load(path):
    """The record at `path`, every field there; else Refused."""
    if not os.path.isfile(path):
        raise dfupatch.Refused(f"no build record at {path}: build both blocks with `make -C tools/lc6000-display-fw "
                               "arm` and use the build.json written next to them")
    try:
        with open(path, encoding="utf-8") as f:
            record = json.load(f)
        a, b = record["block_a"], record["block_b"]
        fields = (record["record"], a["sha1"], a["length"], a["draw"], a["proven"], b["sha1"], b["length"])
    except (OSError, ValueError, KeyError, TypeError) as e:
        raise dfupatch.Refused(f"the build record at {path} can't be read ({type(e).__name__}): build again")
    if fields[0] != VERSION or not all(isinstance(x, str) for x in (a["sha1"], a["draw"], a["proven"], b["sha1"])) \
            or not all(isinstance(x, int) for x in (a["length"], b["length"])):
        raise dfupatch.Refused(f"the build record at {path} isn't one this kit reads (record {VERSION}): build again")
    return record


def judge(record_path, owner_path, upper_path):
    """The record, once it names exactly the A inside the owner's image and the B inside UPPER, and says A draws and
    reads B. Refused otherwise."""
    record = load(record_path)
    a, b = record["block_a"], record["block_b"]
    element = drawn_flash.owner_image(owner_path)
    start = dfupatch.PAD_START - drawn_flash.APP_BASE
    found_a = element[start:start + a["length"]]
    if a["length"] != dfupatch.PAD_END - dfupatch.PAD_START or sha1(found_a) != a["sha1"]:
        raise dfupatch.Refused(f"block A in the owner's image ({owner_path}) isn't the one the build record names: "
                               "they're from different builds. Rebuild the owner's image from this build's block.bin")
    found_b = drawn_flash.upper_block(upper_path)
    if len(found_b) != b["length"] or sha1(found_b) != b["sha1"]:
        raise dfupatch.Refused(f"block B in {upper_path} isn't the one the build record names: A and B are from "
                               "different builds, and together they'd stay silent (#516)")
    if a["draw"] != "1":
        raise dfupatch.Refused(f"block A was built with ARM_DRAW={a['draw']}: it doesn't draw")
    if a["proven"] != "1":
        raise dfupatch.Refused(f"block A was built with ARM_UPPER_PROVEN={a['proven']}: it never reads block B")
    return Judged(a["draw"], a["proven"], a["sha1"], b["sha1"])


def carried(output):
    """Where a .dfu's copy of the record lives: its own name, .build.json for .dfu (wd-upper-drawing.build.json)."""
    return os.path.splitext(output)[0] + ".build.json"


def carry(block_path, output, side):
    """Copy `make arm`'s record from beside BLOCK to beside OUTPUT, only when it names BLOCK's very bytes (`side` is
    block_a or block_b), so the wizard finds it (#593). Never overwrites. Says what it did; refuses nothing: the .dfu
    is good without it, and the wizard then asks for the record."""
    source = os.path.join(os.path.dirname(os.path.abspath(block_path)), "build.json")
    try:
        record = load(source)
    except dfupatch.Refused as why:
        return f"no build record copied: {why}"
    if record[side]["sha1"] != sha1(dfupatch.read(block_path)):
        return f"no build record copied: {source} names another {'block A' if side == 'block_a' else 'block B'}"
    target = carried(output)
    try:
        with open(target, "x", encoding="utf-8") as f:
            json.dump(record, f, indent=2, sort_keys=True)
            f.write("\n")
    except FileExistsError:
        return f"no build record copied: {target} already exists; not overwriting it"
    return f"wrote {target}: the build record, for the wizard"


def commit():
    """The repository's commit as `make arm` builds it, "+changes" when the tree isn't clean; "unknown" outside git."""
    import subprocess
    here = os.path.dirname(os.path.realpath(__file__))
    try:
        head = subprocess.run(["git", "-C", here, "rev-parse", "--short=12", "HEAD"], capture_output=True, text=True,
                              timeout=10)
        dirty = subprocess.run(["git", "-C", here, "status", "--porcelain", "--untracked-files=no"],
                               capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return "unknown"
    if head.returncode != 0 or not head.stdout.strip():
        return "unknown"
    return head.stdout.strip() + ("+changes" if dirty.stdout.strip() else "")


def write(args):
    import time
    record = record_of(dfupatch.read(args.block), dfupatch.read(args.upper), args.draw, args.proven)
    # Which build this is, for the wizard's pick and its word screen (#603); the checks never read these.
    record["commit"], record["built"] = commit(), int(time.time())
    with open(args.output, "w", encoding="utf-8") as f:
        json.dump(record, f, indent=2, sort_keys=True)
        f.write("\n")


def check(args):
    judged = judge(args.record, args.owner, args.upper)
    print(f"ok: block A (ARM_DRAW={judged.draw}, ARM_UPPER_PROVEN={judged.proven}, sha1 {judged.a_sha1[:8]}) and "
          f"block B (sha1 {judged.b_sha1[:8]}) are from the same build")


def main(argv=None):
    parser = argparse.ArgumentParser(description="The blocks' build record: written by make, checked by the kit.")
    commands = parser.add_subparsers(dest="command", required=True)
    out = commands.add_parser("write", help="record how block.bin and upper.bin were built")
    out.add_argument("block")
    out.add_argument("upper")
    out.add_argument("--draw", required=True)
    out.add_argument("--proven", required=True)
    out.add_argument("output")
    out.set_defaults(run=write)
    judge_ = commands.add_parser("check", help="the record against the owner's image and B's file")
    judge_.add_argument("record")
    judge_.add_argument("owner")
    judge_.add_argument("upper")
    judge_.set_defaults(run=check)
    args = parser.parse_args(argv)
    try:
        args.run(args)
    except (dfupatch.Refused, OSError) as refused:
        print(f"refused: {refused}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
