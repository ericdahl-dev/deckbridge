#!/bin/sh
# Regenerates every drawn display reference image (#457, #571) from the Swift renderer, JogDisplayRenderer, never from
# the C code under test, from the one list: manifest.json beside this script, which the Kit's
# DisplayFirmwareReferenceTests also checks every entry of. To add or change a reference, edit the manifest and run this.
# Run from anywhere: sh tools/lc6000-display-fw/test/ref/make_refs.sh
set -eu
here=$(cd "$(dirname "$0")" && pwd)
kit="$here/../../../../Packages/ControllerBridgeKit"
swift build --package-path "$kit" --product jog-reference >&2
bin=$(swift build --package-path "$kit" --show-bin-path)/jog-reference
"$bin" "$here/manifest.json" "$here"
# PNGs for people to look at (the PR, the README); the tests read the PPMs.
sips -s format png -Z 396 "$here/text-ten.ppm" --out "$here/text-ten-preview.png" >/dev/null
sips -s format png -Z 396 "$here/stale.ppm" --out "$here/stale-preview.png" >/dev/null
# The phase rule (#462): a PNG of the five phase references, the rule of each at 4×.
python3 -I - "$here" <<'PY'
import sys
here = sys.argv[1]
names = ["0", "-164", "164", "-1638", "8191"]
x0, y0, w, h, k = 30, 119, 138, 16, 4
rows = []
for name in names:
    data = open(f"{here}/deck4-blue-empty-phase{name}.ppm", "rb").read()
    pixels = data[data.index(b"255\n") + 4:]
    for y in range(y0, y0 + h):
        line = b"".join(pixels[(y * 198 + x) * 3:(y * 198 + x) * 3 + 3] * k for x in range(x0, x0 + w))
        rows += [line] * k
    rows += [b"\x40\x40\x40" * (w * k)] * 2
open(f"{here}/phase-preview.ppm", "wb").write(b"P6\n%d %d\n255\n" % (w * k, len(rows)) + b"".join(rows))
PY
sips -s format png "$here/phase-preview.ppm" --out "$here/phase-preview.png" >/dev/null
rm "$here/phase-preview.ppm"
