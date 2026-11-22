// The drawn display's picture (#457): design B as JogDisplayRenderer draws it, into a back buffer. No allocation, no
// libc beyond memcpy/memset, float math only (the chip is a Cortex-M4F).
#ifndef DFW_DRAW_H
#define DFW_DRAW_H
#include "dfw.h"

/// Writes all DFW_SIZE × DFW_SIZE pixels for the unit's deck in front, upright, top row first, as 0x00RRGGBB. A number
/// outside 1-4 or an unknown player still draws a whole frame.
void dfw_draw(dfw_pixel *frame, const dfw_unit *unit);

/// sRGB channel values 0-255 linearized (WCAG), for the deck number's ink (#542 follow-up); the tests check it.
extern const float dfw_linear_channel[256];

/// The drawing's table, for dfw_init: the Mac tests and the drawing block name it, never the hook block (#501).
extern const dfw_drawing dfw_drawn;

#endif
