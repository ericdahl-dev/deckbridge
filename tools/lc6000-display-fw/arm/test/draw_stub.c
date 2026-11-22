// Test builds only (ARM_DRAW=stub): an empty drawing, so the block tests can build our hook and protocol for the
// padding while the real drawing doesn't fit there (#501). Never in a block meant for the unit.
#include "draw.h"

void dfw_draw(dfw_pixel *frame, const dfw_unit *unit) {
    (void)frame;
    (void)unit;
}

const dfw_drawing dfw_drawn = { dfw_draw };
