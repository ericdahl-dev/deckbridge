#!/usr/bin/env python3
"""Checks the built updater's name (#763): "DeckBridge Firmware Updater" is the .app file, CFBundleName (the app menu,
About and Quit), CFBundleDisplayName (the Dock) and the binary. Exits 1 and prints each problem.
Run: python3 -I scripts/check_updater_name.py "Path/DeckBridge Firmware Updater.app\""""
import os, plistlib, sys

NAME = "DeckBridge Firmware Updater"


def problems(app):
    found = []
    file = os.path.basename(os.path.normpath(app))
    if file != f"{NAME}.app":
        found.append(f'the app is "{file}", needs "{NAME}.app"')
    with open(os.path.join(app, "Contents", "Info.plist"), "rb") as f:
        info = plistlib.load(f)
    for key in ("CFBundleName", "CFBundleDisplayName"):
        if info.get(key) != NAME:
            found.append(f'{key} is "{info.get(key)}", needs "{NAME}"')
    binary = info.get("CFBundleExecutable", "")
    if not os.path.isfile(os.path.join(app, "Contents", "MacOS", binary)):
        found.append(f'no binary "{binary}" in Contents/MacOS')
    return found


if __name__ == "__main__":
    found = problems(sys.argv[1])
    print("\n".join(found))
    sys.exit(1 if found else 0)
