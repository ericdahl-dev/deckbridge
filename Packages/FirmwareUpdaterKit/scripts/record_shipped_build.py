"""Record the deck panel builds a published release shipped in the repo's catalog (#703).

sign_release.sh runs this after publishing, then opens a pull request with the change, so the next release (and the
app built from the repo) still lists every build shipped. Exit 3: nothing new to record.

    python3 -I record_shipped_build.py --draft <published catalog.json> --catalog <repo Catalog/catalog.json>
"""
import argparse
import json
import pathlib
import sys


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--draft", type=pathlib.Path, required=True)
    parser.add_argument("--catalog", type=pathlib.Path, required=True)
    args = parser.parse_args(argv)

    draft = json.loads(args.draft.read_text())
    catalog = json.loads(args.catalog.read_text())
    known = {entry["sha"] for entry in catalog["panel"]}
    new = [entry for entry in draft["panel"] if entry["sha"] not in known]
    if not new:
        print("nothing new to record")
        return 3
    for entry in new:
        # The repo carries images under panel/ (add_panel_image.py); the release has them flat.
        catalog["panel"].append({"version": entry["version"], "sha": entry["sha"],
                                 "image": "panel/" + pathlib.PurePosixPath(entry["image"]).name})
        print(f"recorded {entry['version']} ({entry['sha']})")
    args.catalog.write_text(json.dumps(catalog, indent=2) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
