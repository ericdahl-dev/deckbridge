#!/usr/bin/env python3
"""Writes src/deck_logo.c, the waiting screen's logo (#651): design/icon/icon-1-deck-ring.svg without its tile, as the
app (JogLogo.swift) and the jog display draw it, here an opaque RGB565 image on the waiting screen's black, stretched
down to undo the panel's short pixels so it is round on the glass.

The shapes and their numbers are read from the SVG, not copied: the inner disc, the four arcs, the turned needle, the
hub and the hole, painted in the SVG's order. Each pixel is the average of 4x4 samples, so edges are smooth. Only
+ - * / and comparisons decide a sample (the needle's turn rounded to 12 places), so the bytes are the same on any
machine and test_deck_logo.py can check that the committed file is what the SVG makes now.

RGB565 like LVGL's lv_color_hex (each channel's top bits), low byte first. Opaque, so LVGL copies it: no alpha, no
layer, no decoder buffer. After an icon change, run: python3 -I tools/deck-panel/deck_logo.py"""
import math
import os
import re
import xml.etree.ElementTree as ET

HERE = os.path.dirname(os.path.abspath(__file__))
SVG = os.path.join(HERE, "..", "..", "design", "icon", "icon-1-deck-ring.svg")
OUT = os.path.join(HERE, "src", "deck_logo.c")
SMALL_OUT = os.path.join(HERE, "src", "deck_logo_small.c")
# The panel's pixels are shorter than wide. Elecrow's spec for the CrowPanel Advance 7.0-HMI gives the active area as
# 156 x 87 mm for 800 x 480 (https://www.elecrow.com/crowpanel-advance-7-0-hmi-esp32-ai-display-800x480-artificial-
# intelligent-ips-touch-screen-support-meshtastic-and-arduino-lvgl-micropython.html): 0.195 mm across, 0.18125 mm
# down. So a round logo takes 1.0759 rows for every column.
PIXEL_MM_ACROSS = 156 / 800
PIXEL_MM_DOWN = 87 / 480
STRETCH = PIXEL_MM_ACROSS / PIXEL_MM_DOWN
# px. 198 high is the most the waiting column leaves over two headline and three detail lines (deck_view.cpp); 184
# across times the stretch is 197.96, so the whole logo fits in it.
WIDTH, HEIGHT = 184, 198
# The setup screen's (#677): half the width, stretched the same (92 x 1.0759 = 98.98), so its longer text has room.
SMALL_WIDTH, SMALL_HEIGHT = 92, 99
SAMPLES = 4  # per side, per pixel
BACKGROUND = 0x000000  # the waiting page has no style of its own on the black screen


class Logo:
    def __init__(self, width, height, scale_x, scale_y, pixels):
        self.width, self.height = width, height  # px
        self.scale_x, self.scale_y = scale_x, scale_y  # px per SVG unit, across and down
        self.pixels = pixels  # RGB565, row by row from the top left


def _color(text):
    if not re.fullmatch(r"#[0-9A-Fa-f]{6}", text or ""):
        raise ValueError("expected a #RRGGBB color, got %r" % text)
    return int(text[1:], 16)


def _circle(el):
    cx, cy, r = (float(el.get(k)) for k in ("cx", "cy", "r"))
    r2 = r * r
    return (cx, cy), r, lambda u, v: (u - cx) * (u - cx) + (v - cy) * (v - cy) <= r2


def _arc(el, middle):
    # "M x,y A r,r 0 0 1 x,y": a clockwise arc under 180 degrees, stroked with butt ends, so the band between the
    # radii inside the wedge from one end to the other.
    nums = [float(n) for n in re.findall(r"-?\d+(?:\.\d+)?", el.get("d"))]
    if not re.fullmatch(r"\s*M[^A]+A[^A]+", el.get("d")) or len(nums) != 9 or nums[5:7] != [0.0, 1.0]:
        raise ValueError("expected one small clockwise arc: %r" % el.get("d"))
    x0, y0, r, _, _, _, _, x1, y1 = nums
    half = float(el.get("stroke-width")) / 2
    cx, cy = middle
    ax, ay, bx, by = x0 - cx, y0 - cy, x1 - cx, y1 - cy
    inner2, outer2 = (r - half) * (r - half), (r + half) * (r + half)

    def inside(u, v):
        px, py = u - cx, v - cy
        d2 = px * px + py * py
        # Clockwise on screen (y down) from a to b: p is clockwise of a and b is clockwise of p.
        return inner2 <= d2 <= outer2 and ax * py - ay * px >= 0 and px * by - py * bx >= 0

    return r + half, inside


def _needle(el):
    x, y, w, h = (float(el.get(k)) for k in ("x", "y", "width", "height"))
    rx = float(el.get("rx"))
    ry = float(el.get("ry", rx))
    if rx != ry:
        raise ValueError("expected round corners")
    m = re.fullmatch(r"rotate\(\s*(-?[\d.]+)\s+(-?[\d.]+)\s+(-?[\d.]+)\s*\)", el.get("transform", "rotate(0 0 0)"))
    if not m:
        raise ValueError("expected rotate(a cx cy): %r" % el.get("transform"))
    degrees, ox, oy = (float(g) for g in m.groups())
    c = round(math.cos(math.radians(degrees)), 12)
    s = round(math.sin(math.radians(degrees)), 12)
    mx, my = x + w / 2, y + h / 2  # the rectangle's own middle, before the turn
    qx0, qy0 = w / 2 - rx, h / 2 - rx
    r2 = rx * rx

    def inside(u, v):
        # Undo the turn about (ox, oy), then the rounded rectangle's distance test.
        du, dv = u - ox, v - oy
        lx = ox + c * du + s * dv
        ly = oy - s * du + c * dv
        qx = max(abs(lx - mx) - qx0, 0.0)
        qy = max(abs(ly - my) - qy0, 0.0)
        return qx * qx + qy * qy <= r2

    # The farthest point from the turn's center: a corner circle's center plus its radius (a turn keeps distances).
    corners = [(mx + sx * qx0, my + sy * qy0) for sx in (-1, 1) for sy in (-1, 1)]
    reach = max(math.sqrt((px - ox) ** 2 + (py - oy) ** 2) for px, py in corners) + rx
    return (ox, oy), reach, inside


def _shapes(svg_path):
    """The logo's shapes in paint order: (color, how far from the middle it reaches, inside(u, v)), and the middle."""
    root = ET.parse(svg_path).getroot()
    ns = root.tag[: root.tag.index("}") + 1] if root.tag.startswith("{") else ""
    middle = None
    shapes = []
    for el in root:
        tag = el.tag[len(ns):]
        if tag == "rect" and (el.get("fill", "").startswith("url(") or el.get("fill") == "none"):
            continue  # the tile and its border
        if tag == "circle":
            center, reach, inside = _circle(el)
            middle = middle or center
            if center != middle:
                raise ValueError("expected the circles on one middle")
            shapes.append((_color(el.get("fill")), reach, inside))
        elif tag == "path":
            reach, inside = _arc(el, middle)
            shapes.append((_color(el.get("stroke")), reach, inside))
        elif tag == "rect":
            center, reach, inside = _needle(el)
            if center != middle:
                raise ValueError("expected the needle to turn about the middle")
            shapes.append((_color(el.get("fill")), reach, inside))
    if middle is None or not shapes:
        raise ValueError("no logo shapes in %s" % svg_path)
    return middle, shapes


def _rgb565(color):
    r, g, b = color >> 16, color >> 8 & 0xFF, color & 0xFF
    return (r & 0xF8) << 8 | (g & 0xFC) << 3 | b >> 3


def render(svg_path=SVG, width=WIDTH, height=HEIGHT, stretch=STRETCH):
    (cx, cy), shapes = _shapes(svg_path)
    extent = max(reach for _, reach, _ in shapes)
    scale_x = width / (2 * extent)
    scale_y = scale_x * stretch
    if 2 * extent * scale_y > height:
        raise ValueError("the stretched logo is %.2f px high, more than %d" % (2 * extent * scale_y, height))
    units_x, units_y = 1 / scale_x, 1 / scale_y  # SVG units per pixel
    top_down = list(reversed(shapes))
    n2 = SAMPLES * SAMPLES
    offsets = [(k + 0.5) / SAMPLES for k in range(SAMPLES)]
    pixels = []
    for py in range(height):
        for px in range(width):
            r = g = b = 0
            for oy in offsets:
                v = cy + (py + oy - height / 2) * units_y
                for ox in offsets:
                    u = cx + (px + ox - width / 2) * units_x
                    color = BACKGROUND
                    for shape_color, _, inside in top_down:
                        if inside(u, v):
                            color = shape_color
                            break
                    r += color >> 16
                    g += color >> 8 & 0xFF
                    b += color & 0xFF
            pixels.append(_rgb565((r + n2 // 2) // n2 << 16 | (g + n2 // 2) // n2 << 8 | (b + n2 // 2) // n2))
    return Logo(width, height, scale_x, scale_y, pixels)


def c_source(logo, name="deck_logo"):
    data = []
    for p in logo.pixels:
        data += [p & 0xFF, p >> 8]
    rows = ["    " + " ".join("0x%02x," % b for b in data[i:i + 16]) for i in range(0, len(data), 16)]
    return """\
// Generated by tools/deck-panel/deck_logo.py from design/icon/icon-1-deck-ring.svg (#651). Don't edit: change the icon
// and run python3 -I tools/deck-panel/deck_logo.py; test_deck_logo.py fails while this is stale.
// The logo without its tile, %(w)dx%(h)d (stretched down for the panel's short pixels, so round on the glass), opaque
// RGB565 on black, low byte first. Const, so it stays in flash.
#include <lvgl.h>

static const uint8_t %(name)s_map[%(n)d] __attribute__((aligned(4))) = {
%(rows)s
};

const lv_image_dsc_t %(name)s = {
    .header = {
        .magic = LV_IMAGE_HEADER_MAGIC,
        .cf = LV_COLOR_FORMAT_RGB565,
        .flags = 0,
        .w = %(w)d,
        .h = %(h)d,
        .stride = %(stride)d,
    },
    .data_size = %(n)d,
    .data = %(name)s_map,
};
""" % {"w": logo.width, "h": logo.height, "stride": logo.width * 2, "n": len(data), "rows": "\n".join(rows),
       "name": name}


if __name__ == "__main__":
    for out, logo, name in ((OUT, render(), "deck_logo"),
                            (SMALL_OUT, render(SVG, SMALL_WIDTH, SMALL_HEIGHT), "deck_logo_small")):
        with open(out, "w") as f:
            f.write(c_source(logo, name))
        print("wrote %s" % os.path.relpath(out))
