"""Check that the blocks staged in the updater's catalog are this repo's build, byte for byte (#696).

Run after stage_lc6000_blocks.py, against a second, fresh `make arm` of the same commit with the same toolchain
(arm/README.md: builds are reproducible per toolchain version). Anything staged as a block that this commit doesn't
build, a Denon image above all, fails here. Nothing here builds, flashes or talks to a unit.

    python3 -I Packages/FirmwareUpdaterKit/scripts/check_staged_blocks.py --catalog CATALOG --build REBUILD_DIR
"""
import argparse
import pathlib
import sys

PAIRS = [("blocks/block-a.bin", "block.bin"), ("blocks/block-b.bin", "upper.bin")]


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--catalog", type=pathlib.Path, required=True)
    parser.add_argument("--build", type=pathlib.Path, required=True, help="a fresh make arm output folder")
    args = parser.parse_args(argv)
    for staged, built in PAIRS:
        try:
            ok = (args.catalog / staged).read_bytes() == (args.build / built).read_bytes()
        except OSError as e:
            print(f"refused: {e.filename} can't be read ({e.strerror})", file=sys.stderr)
            return 1
        if not ok:
            print(f"refused: {pathlib.Path(staged).name} isn't what this commit builds ({args.build / built} differs)",
                  file=sys.stderr)
            return 1
    print("the staged blocks are this commit's build, byte for byte")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
