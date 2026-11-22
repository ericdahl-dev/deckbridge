#!/usr/bin/env python3
"""Checks an app icon set and a built app bundle (#733): every macOS size is in the set at the right pixel size, and
the built app names its icon and carries it. Exits 1 and prints each problem.
Run: python3 -I scripts/check_app_icon.py --iconset Path/AppIcon.appiconset --app Path/Name.app"""
import argparse, json, os, plistlib, struct, sys

REQUIRED = [(size, scale) for size in (16, 32, 128, 256, 512) for scale in (1, 2)]


def png_width(path):
    with open(path, "rb") as f:
        head = f.read(24)
    return struct.unpack(">I", head[16:20])[0]


def iconset_problems(d):
    if not os.path.isfile(os.path.join(d, "Contents.json")):
        return [f"no icon set at {d}"]
    with open(os.path.join(d, "Contents.json")) as f:
        images = json.load(f)["images"]
    problems, listed = [], set()
    for i in images:
        if not i.get("filename"):
            continue
        size, scale = int(i["size"].split("x")[0]), int(i["scale"].rstrip("x"))
        listed.add((size, scale))
        path = os.path.join(d, i["filename"])
        if not os.path.isfile(path):
            problems.append(f"no file {i['filename']} for {size}x{size}@{scale}x")
        elif (px := png_width(path)) != size * scale:
            problems.append(f"{i['filename']} is {px} px, needs {size * scale}")
    return problems + [f"missing {s}x{s}@{k}x" for s, k in REQUIRED if (s, k) not in listed]


def app_problems(app):
    with open(os.path.join(app, "Contents", "Info.plist"), "rb") as f:
        info = plistlib.load(f)
    if not (info.get("CFBundleIconFile") or info.get("CFBundleIconName")):
        return ["Info.plist names no icon"]
    resources = os.path.join(app, "Contents", "Resources")
    problems = []
    if icns := info.get("CFBundleIconFile"):
        icns = icns if icns.endswith(".icns") else icns + ".icns"
        if not os.path.isfile(os.path.join(resources, icns)):
            problems.append(f"no Resources/{icns}")
    if info.get("CFBundleIconName") and not os.path.isfile(os.path.join(resources, "Assets.car")):
        problems.append("no Resources/Assets.car")
    return problems


def main(argv):
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--iconset")
    p.add_argument("--app")
    a = p.parse_args(argv)
    problems = (iconset_problems(a.iconset) if a.iconset else []) + (app_problems(a.app) if a.app else [])
    for problem in problems:
        print(problem, file=sys.stderr)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
