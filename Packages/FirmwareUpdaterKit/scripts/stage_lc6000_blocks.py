"""Put the drawn jog display's own block A and block B into the firmware updater's catalog (#696).

The blocks are this repo's own code, as `make -C tools/lc6000-display-fw arm` built them, with the build record it
wrote beside them (tools/lc6000-firmware/build_record.py). Never Denon's bytes: the catalog only takes blocks shaped
like ours, and the release build makes these from the same commit. This step never builds or flashes anything, and
nothing here talks to a unit. It copies block.bin, upper.bin and build.json to <catalog>/blocks/ and lists the two
blocks in the patch set for the given stock versions. The blocks stay out of git (see .gitignore).

    python3 -I Packages/FirmwareUpdaterKit/scripts/stage_lc6000_blocks.py --build tools/lc6000-display-fw/build/arm \\
        --wd 00.50 --tp 00.31
"""
import argparse
import hashlib
import importlib.util
import json
import pathlib
import re
import shutil
import sys

HERE = pathlib.Path(__file__).resolve().parent
DEFAULT_CATALOG = HERE.parent / "Sources/FirmwareCatalog/Catalog"
BUILD_RECORD = HERE.parents[2] / "tools/lc6000-firmware/build_record.py"
FILES = {"a": ("block.bin", "blocks/block-a.bin"), "b": ("upper.bin", "blocks/block-b.bin")}
RECORD = "blocks/build.json"


def build_record():
    """tools/lc6000-firmware/build_record.py, the one reader of `make arm`'s record."""
    spec = importlib.util.spec_from_file_location("build_record", BUILD_RECORD)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--catalog", type=pathlib.Path, default=DEFAULT_CATALOG)
    parser.add_argument("--build", type=pathlib.Path, required=True, help="make arm's output folder")
    parser.add_argument("--wd", required=True)
    parser.add_argument("--tp", required=True)
    args = parser.parse_args(argv)
    catalog_file = args.catalog / "catalog.json"
    catalog = json.loads(catalog_file.read_text())

    problem, target = refusal(args, catalog)
    if problem:
        print(f"refused: {problem}", file=sys.stderr)
        return 1

    (args.catalog / "blocks").mkdir()
    for part, (built, name) in FILES.items():
        shutil.copyfile(args.build / built, args.catalog / name)
        target["entries"].append({"kind": "block", "chip": "wd", "part": part, "file": name, "record": RECORD})
    shutil.copyfile(args.build / "build.json", args.catalog / RECORD)
    catalog_file.write_text(json.dumps(catalog, indent=2) + "\n")
    print(f"added blocks A and B to wd {args.wd} / tp {args.tp}")
    return 0


def refusal(args, catalog):
    """Why these blocks can't go in, or None; and the patch set they go in."""
    records = build_record()
    try:
        record = records.load(str(args.build / "build.json"))
    except records.dfupatch.Refused as why:
        return f"no usable build record: {why}", None
    commit = record.get("commit", "unknown")
    if commit.endswith("+changes"):
        return f"the blocks were built from uncommitted changes ({commit}); build from a clean commit", None
    if not re.fullmatch(r"[0-9a-f]{7,40}", commit):
        return f"the build record's commit is {commit!r}: build inside a clean git checkout", None
    for part, (built, _) in FILES.items():
        named = record["block_a" if part == "a" else "block_b"]
        data = (args.build / built).read_bytes()
        if len(data) != named["length"] or hashlib.sha1(data).hexdigest() != named["sha1"]:
            return f"{built} isn't the block its build record names: A and B are from different builds", None
    if record["block_a"]["draw"] != "1":
        return f"block A was built with ARM_DRAW={record['block_a']['draw']}: it doesn't draw", None
    if record["block_a"]["proven"] != "1":
        return f"block A was built with ARM_UPPER_PROVEN={record['block_a']['proven']}: it never reads block B", None
    target = next((s for s in catalog["lc6000"] if s["wd"] == args.wd and s["tp"] == args.tp), None)
    if target is None:
        return f"the catalog has no patch set for wd {args.wd} / tp {args.tp}", None
    if any(entry["kind"] == "block" for entry in target["entries"]) or (args.catalog / "blocks").exists():
        return "the catalog already carries blocks", None
    return None, target


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
