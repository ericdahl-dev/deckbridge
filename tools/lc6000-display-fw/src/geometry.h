// The drawing's geometry (#571), once: the square root, the clamp, an edge's coverage of a pixel and the blend, which
// draw.c, draw_live.c, draw_band.c and the table generators (gen/) all take. Float only, no libm, no double: the chip is
// a Cortex-M4F. Each is static inline, so every file gets its own copy, as the chip's blocks need (B never calls A).
#ifndef DFW_GEOMETRY_H
#define DFW_GEOMETRY_H
#include <stdint.h>

#include "dfw.h"

/// A square root by Newton's method from a bit-level first guess, as draw.c's. No libm on the chip.
static inline float root(float x) {
    if (x <= 0.0f) return 0.0f;
    union { float f; uint32_t u; } v = { x };
    v.u = (v.u >> 1) + 0x1FBD1DF5u;
    float r = v.f;
    for (int i = 0; i < 3; i++) r = 0.5f * (r + x / r);
    return r;
}

static inline float clamp01(float x) { return x < 0.0f ? 0.0f : x > 1.0f ? 1.0f : x; }

/// How much of a pixel lies inside a straight edge, from the signed distance of its center to the edge (positive
/// inside) and the edge's unit normal: the exact area of the pixel square on the inside, as draw.c's.
static inline float edge_cover(float distance, float nx, float ny) {
    float a = nx < 0.0f ? -nx : nx, b = ny < 0.0f ? -ny : ny;
    if (a < b) { float t = a; a = b; b = t; }
    float s = distance + (a + b) / 2.0f;
    if (s <= 0.0f) return 0.0f;
    if (s >= a + b) return 1.0f;
    if (b < 1e-6f) return clamp01(s / a);
    if (s < b) return s * s / (2.0f * a * b);
    if (s < a) return (s - b / 2.0f) / a;
    float t = a + b - s;
    return 1.0f - t * t / (2.0f * a * b);
}

/// `under` moved toward `over` by `cover` (0-1), per channel, rounded.
static inline dfw_pixel blend(dfw_pixel under, dfw_pixel over, float cover) {
    if (cover <= 0.0f) return under;
    if (cover >= 1.0f) return over;
    dfw_pixel out = 0;
    for (int shift = 0; shift <= 16; shift += 8) {
        float a = (float)(under >> shift & 0xFFu), b = (float)(over >> shift & 0xFFu);
        float c = a + (b - a) * cover + 0.5f;
        out |= (dfw_pixel)(c < 0.0f ? 0.0f : c > 255.0f ? 255.0f : c) << shift;
    }
    return out;
}

#endif
