// The recording adapter of the layer seam (#568): a 320 x 240 layer in memory, and per present how many times each
// pixel was written and whether one write made it black and a later one lit it again (the shimmer of 2026-11-19).
#ifndef LAYER_RECORD_H
#define LAYER_RECORD_H
#include <stdint.h>

#include "draw_band.h"

typedef struct {
    uint16_t pixels[DFW_LAYER_W * DFW_LAYER_H];
    uint8_t writes[DFW_LAYER_W * DFW_LAYER_H];
    uint8_t blacked[DFW_LAYER_W * DFW_LAYER_H];
    /// This present: all writes, those that lit a pixel this present made black, those inside the frame's square, and
    /// those that wrote the value the pixel already held.
    int total, dark_then_lit, in_square, unchanged;
} layer_recorder;

/// Every pixel set to `value`, as a layer holds what was drawn before; the counts start again.
void recorder_fill(layer_recorder *r, uint16_t value);
/// A new present: the counts start again; the pixels stay (the layer is the memory).
void recorder_next_present(layer_recorder *r);
/// The seam's adapter over this recorder.
dfw_layer recorder_layer(layer_recorder *r);
/// The most writes any one pixel had this present.
int recorder_most_writes(const layer_recorder *r);

#endif
