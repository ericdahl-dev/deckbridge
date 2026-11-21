"""Make the folder for an unsigned draft firmware release (#703), from a deck panel tag's build.

CI runs this on a `deck-panel-v<VERSION>` tag, after building the panel image. It never sees a key: the draft is
signed later on the maintainer's Mac by sign_release.sh (ADR 0012, docs/FIRMWARE-RELEASE-SIGNING.md).

    python3 -I Packages/FirmwareUpdaterKit/scripts/release_draft.py --tag deck-panel-v1.1.0 \\
        --version-file tools/deck-panel/VERSION --image firmware.bin --sha 1d0683f --out draft
"""
import argparse
import pathlib
import sys

PREFIX = "deck-panel-v"
DEFAULT_CATALOG = pathlib.Path(__file__).resolve().parent.parent / "Sources/FirmwareCatalog/Catalog"


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--tag", required=True)
    parser.add_argument("--version-file", type=pathlib.Path, required=True)
    parser.add_argument("--image", type=pathlib.Path, required=True)
    parser.add_argument("--sha", required=True)
    parser.add_argument("--catalog", type=pathlib.Path, default=DEFAULT_CATALOG)
    parser.add_argument("--out", type=pathlib.Path, required=True)
    args = parser.parse_args(argv)

    version = args.version_file.read_text().strip()
    if args.tag != PREFIX + version:
        print(f"refused: tag {args.tag} doesn't match the panel's VERSION {version} ({PREFIX}{version})", file=sys.stderr)
        return 1
    args.out.mkdir()
    (args.out / "catalog.json").write_text("{}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
