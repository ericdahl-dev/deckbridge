// The panel's geometry (#568), defined once in src/panel_geometry.h: the 320 x 240 RGB565 layer, the frame at
// (61, 21) turned 180 degrees, and the pack. Every user (draw_band.c, frame-dump, A's adapter, the tests) takes it there.
#include "harness.h"
#include "panel_geometry.h"

static void the_panel_is_320_by_240_with_the_frame_at_61_21(void) {
    CHECK(DFW_LAYER_W == 320 && DFW_LAYER_H == 240 && DFW_LAYER_STRIDE == 320);
    CHECK(DFW_FRAME_X == 61 && DFW_FRAME_Y == 21);
}

/// Frame (x, y) lands at panel (61 + 197 - x, 21 + 197 - y): the frame's top-left corner at the panel's (258, 218).
static void the_frame_lands_turned_180_degrees(void) {
    CHECK(dfw_panel_index(0, 0) == 218 * 320 + 258);
    CHECK(dfw_panel_index(197, 197) == 21 * 320 + 61);
    CHECK(dfw_panel_index(99, -7) == 225 * 320 + 159);
    CHECK(dfw_panel_index(-62, 0) == -1 && dfw_panel_index(0, -22) == -1);
    CHECK(dfw_panel_index(258, 0) == 218 * 320 + 0 && dfw_panel_index(259, 0) == -1);
}

static void the_pack_keeps_the_top_5_6_5_bits(void) {
    CHECK(dfw_rgb565(0xFF0000u) == 0xF800u && dfw_rgb565(0x00FF00u) == 0x07E0u && dfw_rgb565(0x0000FFu) == 0x001Fu);
    CHECK(dfw_rgb565(0xEDEDEAu) == (uint16_t)((0xED >> 3) << 11 | (0xED >> 2) << 5 | (0xEA >> 3)));
}

static void the_square_is_the_frames(void) {
    CHECK(dfw_in_frame(0, 0) && dfw_in_frame(197, 197) && !dfw_in_frame(-1, 0) && !dfw_in_frame(198, 5));
}

/// The inverse: every panel pixel to its frame (x, y), and back to the same index through dfw_panel_index.
static void the_panel_maps_back_to_the_frame(void) {
    int off = 0;
    for (int i = 0; i < DFW_LAYER_W * DFW_LAYER_H; i++) {
        int x, y;
        dfw_panel_to_frame(i, &x, &y);
        off += dfw_panel_index(x, y) != i;
    }
    CHECK(off == 0);
    int x, y;
    dfw_panel_to_frame(218 * 320 + 258, &x, &y);
    CHECK(x == 0 && y == 0);
    dfw_panel_to_frame(0, &x, &y);
    CHECK(x == 258 && y == 218);
}

const test_case panel_tests[] = {
    { "the panel is 320 by 240 with the frame at 61, 21", the_panel_is_320_by_240_with_the_frame_at_61_21 },
    { "the frame lands turned 180 degrees", the_frame_lands_turned_180_degrees },
    { "the pack keeps the top 5, 6, 5 bits", the_pack_keeps_the_top_5_6_5_bits },
    { "the square is the frame's", the_square_is_the_frames },
    { "the panel maps back to the frame", the_panel_maps_back_to_the_frame },
    { 0, 0 },
};
