// The panel (#568), defined once: layer 2 is 320 x 240 RGB565 at a stride of 320; our 198 frame sits where stock draws
// an uploaded slot, at (61, 21), turned 180 degrees (uploads show rotated unless pre-rotated, #121, and dfw draws
// upright), so frame (x, y) lands at panel (61 + 197 - x, 21 + 197 - y). Used by B's band, A's present (adapter.c),
// frame-dump and the tests. Freestanding: no libc.
#ifndef DFW_PANEL_GEOMETRY_H
#define DFW_PANEL_GEOMETRY_H
#include <stdint.h>

#include "dfw.h"

#define DFW_LAYER_W 320
#define DFW_LAYER_H 240
/// Pixels from one row of the layer to the next.
#define DFW_LAYER_STRIDE DFW_LAYER_W
#define DFW_FRAME_X ((DFW_LAYER_W - DFW_SIZE) / 2)
#define DFW_FRAME_Y ((DFW_LAYER_H - DFW_SIZE) / 2)

/// Whether frame pixel (x, y) is inside the 198 square: the frame's own, which the present copies.
static inline int dfw_in_frame(int x, int y) { return x >= 0 && x < DFW_SIZE && y >= 0 && y < DFW_SIZE; }

/// Frame (x, y) to its index in the layer, turned 180 degrees; -1 off the layer.
static inline int dfw_panel_index(int x, int y) {
    int px = DFW_FRAME_X + DFW_SIZE - 1 - x, py = DFW_FRAME_Y + DFW_SIZE - 1 - y;
    if (px < 0 || px >= DFW_LAYER_W || py < 0 || py >= DFW_LAYER_H) return -1;
    return py * DFW_LAYER_STRIDE + px;
}

/// The inverse: the layer's pixel `index` to its frame (x, y), turned back (below 0 or past 197 outside the square).
static inline void dfw_panel_to_frame(int index, int *x, int *y) {
    *x = DFW_FRAME_X + DFW_SIZE - 1 - index % DFW_LAYER_STRIDE;
    *y = DFW_FRAME_Y + DFW_SIZE - 1 - index / DFW_LAYER_STRIDE;
}

/// A 0x00RRGGBB pixel as the layer's RGB565: each channel's top 5, 6 and 5 bits.
static inline uint16_t dfw_rgb565(dfw_pixel p) {
    return (uint16_t)(((p >> 8) & 0xF800u) | ((p >> 5) & 0x07E0u) | ((p >> 3) & 0x001Fu));
}

/// The layer seam (#568): every write that reaches the panel goes through one of these, a pixel at a time by its index
/// (y * DFW_LAYER_STRIDE + x), as RGB565. Its adapters: the real layer (dfw_draw_band, B's band entry, the only code
/// that touches the layer's pointer), a recording one for the tests (test/layer_record.c), and frame-dump's.
typedef struct {
    uint16_t (*read)(void *ctx, int index);
    void (*write)(void *ctx, int index, uint16_t rgb565);
    void *ctx;
} dfw_layer;

#endif
