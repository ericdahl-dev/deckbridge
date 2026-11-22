// The frame's arrival in the layer, composed natively (#568): what A's present (arm/adapter.c's layer_present) does on
// the unit, through the layer seam and src/panel_geometry.h, for the tests and frame-dump. On the unit that copy is A's
// own code and stays as flashed; this mirrors it, it doesn't replace it.
#ifndef PRESENT_H
#define PRESENT_H
#include "panel_geometry.h"

/// The whole 198 square, every present, changed or not, turned 180 degrees and packed, row by row of the panel as A's
/// loop runs: 39,204 writes.
void present_through_layer(const dfw_layer *layer, const dfw_pixel *frame);

#endif
