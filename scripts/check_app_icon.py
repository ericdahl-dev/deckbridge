#!/usr/bin/env python3
"""Checks an app icon set and a built app bundle (#733): every macOS size is in the set at the right pixel size, and
the built app names its icon and carries it. With --badge, the updater's badge is that color (#763). Exits 1 and
prints each problem.
Run: python3 -I scripts/check_app_icon.py --iconset Path/AppIcon.appiconset [--badge 62929E] --app Path/Name.app"""
import argparse, json, os, plistlib, struct, sys, zlib

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


# Inside the updater's badge (design/icon/updater-download.svg: center 752,752, r 134), left of its white arrow.
BADGE_POINT = (652, 752)


def png_pixel(path, x, y):
    """The RGB at x, y of an 8-bit RGBA, non-interlaced PNG (what render_app_icon.swift writes)."""
    with open(path, "rb") as f:
        data = f.read()
    at, idat, width = 8, b"", 0
    while at < len(data):
        n, kind = struct.unpack(">I4s", data[at:at + 8])
        body = data[at + 8:at + 8 + n]
        if kind == b"IHDR":
            width, _, depth, color, _, _, interlace = struct.unpack(">IIBBBBB", body)
            if (depth, color, interlace) != (8, 6, 0):
                raise ValueError(f"{path}: not 8-bit RGBA non-interlaced")
        elif kind == b"IDAT":
            idat += body
        at += 12 + n
    raw, stride, prior = zlib.decompress(idat), 4 * width, bytearray(4 * width)
    for row in range(y + 1):
        kind, line = raw[row * (stride + 1)], bytearray(raw[row * (stride + 1) + 1:(row + 1) * (stride + 1)])
        for i in range(stride):
            a = line[i - 4] if i >= 4 else 0
            b, c = prior[i], prior[i - 4] if i >= 4 else 0
            if kind == 1:
                line[i] = (line[i] + a) & 0xFF
            elif kind == 2:
                line[i] = (line[i] + b) & 0xFF
            elif kind == 3:
                line[i] = (line[i] + (a + b) // 2) & 0xFF
            elif kind == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[i] = (line[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 0xFF
        prior = line
    return tuple(prior[4 * x:4 * x + 3])


def badge_problems(iconset, color, tolerance=6):
    want = tuple(int(color[i:i + 2], 16) for i in (0, 2, 4))
    got = png_pixel(os.path.join(iconset, "icon_512x512@2x.png"), *BADGE_POINT)
    if all(abs(g - w) <= tolerance for g, w in zip(got, want)):
        return []
    return ["the badge is #%02X%02X%02X, needs #%s" % (*got, color.upper())]


def main(argv):
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--iconset")
    p.add_argument("--app")
    p.add_argument("--badge", help="the badge's color as RRGGBB, read from the set's 1024 px icon")
    a = p.parse_args(argv)
    problems = (iconset_problems(a.iconset) if a.iconset else []) + (app_problems(a.app) if a.app else [])
    if a.badge and a.iconset and not problems:
        problems += badge_problems(a.iconset, a.badge)
    for problem in problems:
        print(problem, file=sys.stderr)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
