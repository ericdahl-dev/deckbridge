#include "present.h"

void present_through_layer(const dfw_layer *layer, const dfw_pixel *frame) {
    // A's order: the panel's rows from the frame's top-left at (61, 21), each from the frame's last pixel backwards.
    for (int py = 0; py < DFW_SIZE; py++)
        for (int px = 0; px < DFW_SIZE; px++) {
            int x = DFW_SIZE - 1 - px, y = DFW_SIZE - 1 - py;
            layer->write(layer->ctx, dfw_panel_index(x, y), dfw_rgb565(frame[y * DFW_SIZE + x]));
        }
}
