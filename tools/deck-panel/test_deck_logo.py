#!/usr/bin/env python3
"""Tests for deck_logo.py (#651): the waiting screen's logo is design/icon/icon-1-deck-ring.svg, drawn from the SVG's
own numbers, and src/deck_logo.c is what the generator makes from it now.
Run: python3 -I tools/deck-panel/test_deck_logo.py. After an icon change: python3 -I tools/deck-panel/deck_logo.py"""
import importlib.util, os, re, sys, tempfile, unittest

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
SVG = os.path.join(HERE, "..", "..", "design", "icon", "icon-1-deck-ring.svg")
C_FILE = os.path.join(HERE, "src", "deck_logo.c")
SMALL_C_FILE = os.path.join(HERE, "src", "deck_logo_small.c")


def load_generator():
    spec = importlib.util.spec_from_file_location("deck_logo", os.path.join(HERE, "deck_logo.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


gen = load_generator()
LOGO = gen.render(SVG)
SMALL = gen.render(SVG, 92, 99)

# The icon's colors as LVGL stores them in RGB565 (lv_color_hex: the top 5, 6, 5 bits), worked out by hand.
GRAY_ARC, GOLD_ARC, COPPER_ARC, TEAL_ARC = 0x6B8E, 0xEE6C, 0xC3A9, 0x6493
NEEDLE_AND_HUB, INNER_DISC, HOLE, BLACK = 0xD6BA, 0x18E3, 0x10A2, 0x0000


def at(logo, radius, degrees):
    """The pixel `radius` SVG units from the middle, at `degrees` (0 is right, 90 is down: the SVG's y is down)."""
    import math
    x = logo.width / 2 + radius * logo.scale_x * math.cos(math.radians(degrees))
    y = logo.height / 2 + radius * logo.scale_y * math.sin(math.radians(degrees))
    return logo.pixels[int(y) * logo.width + int(x)]


class DeckLogoTests(unittest.TestCase):
    def test_the_committed_image_is_what_the_svg_makes(self):
        with open(C_FILE) as f:
            committed = f.read()
        self.assertEqual(committed, gen.c_source(LOGO),
                         "src/deck_logo.c is stale: run python3 -I tools/deck-panel/deck_logo.py")

    def test_it_is_184_wide_198_high_opaque_rgb565_in_flash(self):
        # 198 high: the most the waiting column has left over two headline and three detail lines (deck_view.cpp).
        self.assertEqual((LOGO.width, LOGO.height), (184, 198))
        self.assertEqual(len(LOGO.pixels), 184 * 198)
        with open(C_FILE) as f:
            text = f.read()
        self.assertIn(".cf = LV_COLOR_FORMAT_RGB565,", text)
        self.assertIn(".magic = LV_IMAGE_HEADER_MAGIC,", text)
        self.assertIn(".w = 184,", text)
        self.assertIn(".h = 198,", text)
        self.assertIn(".stride = 368,", text)
        self.assertIn(".data_size = 72864,", text)
        self.assertIn("static const uint8_t deck_logo_map[72864]", text)
        self.assertIn("const lv_image_dsc_t deck_logo = {", text)
        self.assertEqual(len(re.findall(r"0x[0-9a-f]{2},", text)), 72864)

    def test_the_whole_logo_fits_with_black_corners(self):
        # The needle's tip reaches 310 units out, past the arcs (300): the crop is the farthest shape.
        self.assertEqual(LOGO.pixels[0], BLACK)
        self.assertEqual(LOGO.pixels[-1], BLACK)
        w, h = LOGO.width, LOGO.height
        edge = [LOGO.pixels[i] for i in range(w)] + [LOGO.pixels[i * w] for i in range(h)]
        self.assertEqual(set(edge), {BLACK}, "a shape touches the top or left edge: it is cut off")
        self.assertAlmostEqual(LOGO.scale_x, 184 / 620, places=9)

    def test_the_committed_small_image_is_what_the_svg_makes(self):
        # The setup screen's (#677): half size, so the join instructions have the room.
        with open(SMALL_C_FILE) as f:
            committed = f.read()
        self.assertEqual(committed, gen.c_source(SMALL, "deck_logo_small"),
                         "src/deck_logo_small.c is stale: run python3 -I tools/deck-panel/deck_logo.py")

    def test_the_small_one_is_92_wide_99_high_under_its_own_name(self):
        # 92 x 1.0759 = 98.98: half the width, stretched the same.
        self.assertEqual((SMALL.width, SMALL.height), (92, 99))
        with open(SMALL_C_FILE) as f:
            text = f.read()
        self.assertIn(".w = 92,", text)
        self.assertIn(".h = 99,", text)
        self.assertIn(".stride = 184,", text)
        self.assertIn(".data_size = 18216,", text)
        self.assertIn("static const uint8_t deck_logo_small_map[18216]", text)
        self.assertIn("const lv_image_dsc_t deck_logo_small = {", text)

    def test_it_is_stretched_down_so_it_is_round_on_the_glass(self):
        # The panel's pixels are shorter than wide: Elecrow's active area is 156 x 87 mm for 800 x 480, so 0.195 mm
        # across and 0.18125 mm down. Round on the glass takes 0.195 / 0.18125 = 1.0759 rows per column, by hand.
        # The content's box, counting a pixel as the logo's at half the dimmest arc's brightness or more (gray,
        # 0x6C+0x72+0x77 = 341, so 170): the edge at half coverage, not the faint antialiased fringe.
        for logo in (LOGO, SMALL):
            def lit(x, y, logo=logo):
                p = logo.pixels[y * logo.width + x]
                return (p >> 11 << 3) + ((p >> 5 & 0x3F) << 2) + ((p & 0x1F) << 3) >= 170

            rows = [y for y in range(logo.height) if any(lit(x, y) for x in range(logo.width))]
            cols = [x for x in range(logo.width) if any(lit(x, y) for y in range(logo.height))]
            content_w, content_h = cols[-1] - cols[0] + 1, rows[-1] - rows[0] + 1
            self.assertLessEqual(abs(content_h - content_w * 1.0759), 1, (logo.width, content_w, content_h))

    def test_the_four_arcs_are_the_svgs_colors_clockwise_from_top_right(self):
        self.assertEqual(at(LOGO, 262, -30), GRAY_ARC)
        self.assertEqual(at(LOGO, 262, 45), GOLD_ARC)
        self.assertEqual(at(LOGO, 262, 135), COPPER_ARC)
        self.assertEqual(at(LOGO, 262, -135), TEAL_ARC)
        # The gaps between them, at the four compass points, are the background.
        for degrees in (0, 90, 180, -90):
            self.assertEqual(at(LOGO, 262, degrees), BLACK, degrees)

    def test_the_disc_needle_hub_and_hole(self):
        self.assertEqual(at(LOGO, 0, 0), HOLE)
        self.assertEqual(at(LOGO, 50, 90), NEEDLE_AND_HUB)  # hub
        self.assertEqual(at(LOGO, 150, 90), INNER_DISC)
        # The needle, turned 40 degrees clockwise from straight up: between the disc (206) and the arcs (224).
        self.assertEqual(at(LOGO, 215, -50), NEEDLE_AND_HUB)
        self.assertEqual(at(LOGO, 215, -90), BLACK)

    def test_edges_are_antialiased(self):
        self.assertGreater(len(set(LOGO.pixels)), 20)

    def test_the_numbers_come_from_the_svg(self):
        with open(SVG) as f:
            svg = f.read()
        changed = svg.replace("#ECCF65", "#FF0000").replace("rotate(40 512 512)", "rotate(130 512 512)")
        self.assertNotEqual(changed, svg)
        with tempfile.NamedTemporaryFile("w", suffix=".svg", delete=False) as f:
            f.write(changed)
        try:
            logo = gen.render(f.name)
        finally:
            os.unlink(f.name)
        self.assertEqual(at(logo, 262, 45), 0xF800)
        self.assertEqual(at(logo, 215, -50), BLACK)
        self.assertEqual(at(logo, 215, 40), NEEDLE_AND_HUB)


if __name__ == "__main__":
    unittest.main()
