"""Make the folder for an unsigned draft firmware release (#703), from a deck panel tag's build.

CI runs this on a `deck-panel-v<VERSION>` tag, after building the panel image. It never sees a key: the draft is
signed later on the maintainer's Mac by sign_release.sh (ADR 0012, docs/FIRMWARE-RELEASE-SIGNING.md).

    python3 -I Packages/FirmwareUpdaterKit/scripts/release_draft.py --tag deck-panel-v1.1.0 \\
        --version-file tools/deck-panel/VERSION --image firmware.bin --sha 1d0683f --out draft

With --blocks <make arm's output> --blocks-wd 00.50 --blocks-tp 00.31, the drawn display's own blocks A and B and their
build record ride in the same release (#707), staged and checked by stage_lc6000_blocks.py (#696).
"""
import argparse
import importlib.util
import json
import pathlib
import shutil
import sys
import tempfile

PREFIX = "deck-panel-v"
DEFAULT_CATALOG = pathlib.Path(__file__).resolve().parent.parent / "Sources/FirmwareCatalog/Catalog"


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--tag", required=True)
    parser.add_argument("--version-file", type=pathlib.Path, required=True)
    parser.add_argument("--image", type=pathlib.Path, required=True)
    parser.add_argument("--sha", required=True)
    # The build's bootloader and partition table (#687), both or neither: add_panel_image.py checks them.
    parser.add_argument("--bootloader", type=pathlib.Path)
    parser.add_argument("--partitions", type=pathlib.Path)
    # The drawn display's blocks (#707): `make arm`'s output folder and the stock versions their set is for. They ride in
    # the deck panel release; stage_lc6000_blocks.py (#696) checks them.
    parser.add_argument("--blocks", type=pathlib.Path)
    parser.add_argument("--blocks-wd")
    parser.add_argument("--blocks-tp")
    parser.add_argument("--catalog", type=pathlib.Path, default=DEFAULT_CATALOG)
    parser.add_argument("--out", type=pathlib.Path, required=True)
    args = parser.parse_args(argv)

    version = args.version_file.read_text().strip()
    if args.tag != PREFIX + version:
        print(f"refused: tag {args.tag} doesn't match the panel's VERSION {version} ({PREFIX}{version})", file=sys.stderr)
        return 1
    with tempfile.TemporaryDirectory() as work:
        staged = pathlib.Path(work) / "Catalog"
        shutil.copytree(args.catalog, staged, ignore=shutil.ignore_patterns("panel", "blocks", ".DS_Store"))
        boot = [arg for name, path in (("--bootloader", args.bootloader), ("--partitions", args.partitions)) if path
                for arg in (name, str(path))]
        added = add_panel_image().main(["--catalog", str(staged), "--image", str(args.image),
                                        "--version", version, "--sha", args.sha, *boot])
        if added != 0:
            return added
        if args.blocks:
            staged_blocks = load("stage_lc6000_blocks").main(["--catalog", str(staged), "--build", str(args.blocks),
                                                              "--wd", args.blocks_wd or "", "--tp", args.blocks_tp or ""])
            if staged_blocks != 0:
                return staged_blocks
        catalog = json.loads((staged / "catalog.json").read_text())
        # The repo's own entry for this build (nested name, as the app carries it): what the signing step's pull
        # request records, printed in case that isn't made.
        # Only version, SHA and image: the repo keeps it as history and carries none of its files.
        newest = catalog["panel"][-1]
        print("record: " + json.dumps({key: newest[key] for key in ("version", "sha", "image")}))
        args.out.mkdir()
        for entry in catalog["panel"]:
            for key in ("image", "bootloader", "partitions"):
                if key in entry:
                    entry[key] = flat(staged, entry[key], args.out)
        for patch_set in catalog["lc6000"]:
            for entry in patch_set["entries"]:
                entry["file"] = flat(staged, entry["file"], args.out)
                if "record" in entry:  # blocks A and B name one build record: copied once
                    entry["record"] = flat(staged, entry["record"], args.out, shared=True)
        (args.out / "catalog.json").write_text(json.dumps(catalog, indent=2) + "\n")
    return 0


def flat(staged, name, out, shared=False):
    """A file's flat name in the draft (a release asset's name can't hold a "/"), copying it there if it's carried.
    A panel build listed without its image is history: it keeps a name but has no file."""
    base = pathlib.PurePosixPath(name).name
    source = staged / name
    if source.exists():
        if (out / base).exists():
            if shared and (out / base).read_bytes() == source.read_bytes():
                return base
            raise SystemExit(f"refused: two files would both be {base} in the draft")
        shutil.copyfile(source, out / base)
    return base


def add_panel_image():
    """The catalog build step (#686)."""
    return load("add_panel_image")


def load(name):
    """A step beside this file, by name (python -I doesn't put this folder on the path)."""
    path = pathlib.Path(__file__).with_name(name + ".py")
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
