// The drawn display's live elements (#459): the lit master beat and the marker, drawn over design B.
#ifndef DFW_DRAW_LIVE_H
#define DFW_DRAW_LIVE_H
#include "dfw.h"

/// Draws the unit's live elements over a frame dfw_draw has drawn: the master beat's section lit, as
/// JogDisplayRenderer's ring(litBeat:) does. Nothing while the display is stale.
void dfw_draw_live(dfw_pixel *frame, const dfw_unit *unit);

/// The time left (#460), "-m:ss", centered under key/BPM in GeistMono-SemiBold 21 (#524): the text white, or the last
/// minute's warning red (its own glyphs: light text is drawn heavier). In draw.c, with the header's glyphs.
void dfw_draw_time_text(dfw_pixel *frame, const char *text, int warning_red);

#endif
