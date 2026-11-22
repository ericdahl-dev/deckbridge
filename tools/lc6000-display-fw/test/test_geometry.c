// The one C geometry module (#571): src/geometry.h's root, clamp01, edge_cover and blend, which draw.c, draw_live.c,
// draw_band.c and the table generators all take (their copies are gone).
#include "harness.h"
#include "geometry.h"

static void the_root_is_newtons_to_float_precision(void) {
    CHECK(root(0.0f) == 0.0f && root(-1.0f) == 0.0f);
    CHECK(root(4.0f) == 2.0f && root(10000.0f) == 100.0f);
    float r = root(2.0f);
    CHECK(r * r > 1.9999990f && r * r < 2.0000010f);
}

static void clamp01_keeps_0_to_1(void) {
    CHECK(clamp01(-0.5f) == 0.0f && clamp01(0.25f) == 0.25f && clamp01(1.5f) == 1.0f);
}

/// An edge's cover: half a pixel on the edge, all of it a half pixel in, none a half pixel out; a 45 degree edge ramps
/// over 1.41 px.
static void edge_cover_is_the_pixels_area_inside(void) {
    CHECK(edge_cover(0.0f, 1.0f, 0.0f) == 0.5f);
    CHECK(edge_cover(0.5f, 1.0f, 0.0f) == 1.0f && edge_cover(-0.5f, 1.0f, 0.0f) == 0.0f);
    CHECK(edge_cover(0.25f, 0.0f, 1.0f) == 0.75f);
    float n = 0.70710678f;
    CHECK(edge_cover(0.0f, n, n) > 0.4999f && edge_cover(0.0f, n, n) < 0.5001f);
    CHECK(edge_cover(0.7f, n, n) > 0.99f && edge_cover(0.71f, n, n) == 1.0f);
}

static void blend_moves_each_channel_and_rounds(void) {
    CHECK(blend(0x000000u, 0xFFFFFFu, 0.0f) == 0x000000u && blend(0x000000u, 0xFFFFFFu, 1.0f) == 0xFFFFFFu);
    CHECK(blend(0x000000u, 0xFF8000u, 0.5f) == 0x804000u);
    CHECK(blend(0x0B0B0Bu, 0x00FF48u, 0.25f) == 0x08481Au);
}

const test_case geometry_tests[] = {
    { "the root is Newton's to float precision", the_root_is_newtons_to_float_precision },
    { "clamp01 keeps 0 to 1", clamp01_keeps_0_to_1 },
    { "edge_cover is the pixel's area inside", edge_cover_is_the_pixels_area_inside },
    { "blend moves each channel and rounds", blend_moves_each_channel_and_rounds },
    { 0, 0 },
};
