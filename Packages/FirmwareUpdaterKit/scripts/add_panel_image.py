"""Put a deck panel firmware image into the firmware updater's built-in catalog (#686).

The image is an input file, built elsewhere (the panel's own PlatformIO build, or a release); this step never
builds or flashes anything. It copies the image to <catalog>/panel/ and lists it in <catalog>/catalog.json with
its version and the build SHA the panel prints at boot. Commit the catalog.json change with the release; the
images themselves stay out of git (see .gitignore), so a build from the repo carries none. In a tree where this
has run, the package test theBuiltInCatalogFromTheRepoCarriesNoPanelImage fails, as it should: it pins the repo.

    python3 -I Packages/FirmwareUpdaterKit/scripts/add_panel_image.py --image firmware.bin --version 1.0.0 --sha 1d0683f
"""
import argparse
import json
import pathlib
import re
import shutil
import sys

ESP_IMAGE_MAGIC = 0xE9  # the first byte of every ESP32 app image (esp_image_header_t.magic)

DEFAULT_CATALOG = pathlib.Path(__file__).resolve().parent.parent / "Sources/FirmwareCatalog/Catalog"


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--catalog", type=pathlib.Path, default=DEFAULT_CATALOG)
    parser.add_argument("--image", type=pathlib.Path, required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--sha", required=True)
    args = parser.parse_args(argv)
    catalog_file = args.catalog / "catalog.json"
    catalog = json.loads(catalog_file.read_text())

    problem = refusal(args, catalog)
    if problem:
        print(f"refused: {problem}", file=sys.stderr)
        return 1

    name = f"panel/deck-panel-{args.version}-{args.sha}.bin"
    (args.catalog / "panel").mkdir(exist_ok=True)
    shutil.copyfile(args.image, args.catalog / name)
    catalog["panel"].append({"version": args.version, "sha": args.sha, "image": name})
    catalog_file.write_text(json.dumps(catalog, indent=2) + "\n")
    print(f"added {name}")
    return 0


def refusal(args, catalog):
    """Why this image can't go in, or None."""
    if args.sha.endswith("-dirty"):
        return f"{args.sha} is a -dirty build (uncommitted changes); ship a clean build"
    if not re.fullmatch(r"[0-9a-f]{7,40}", args.sha):
        return f"{args.sha!r} is not a 7-40 character lowercase hex SHA"
    if not re.fullmatch(r"\d+(\.\d+)*", args.version):
        return f"{args.version!r} is not a dotted version such as 1.0.0"
    for entry in catalog["panel"]:
        if entry["sha"] == args.sha or entry["version"] == args.version:
            return f"{entry['version']} ({entry['sha']}) is already listed"
    head = args.image.read_bytes()[:1]
    if head != bytes([ESP_IMAGE_MAGIC]):
        return f"{args.image} is not an ESP32 app image (first byte {head.hex() or 'missing'}, not e9)"
    return None


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
