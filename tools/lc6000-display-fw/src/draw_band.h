// The progress ring in the panel's band outside the frame (#524): r 103-107 round the frame's center, a 0x4A4A4A track
// and the fill clockwise from 12 o'clock, as JogDisplayRenderer.drawnImage draws it.
#ifndef DFW_DRAW_BAND_H
#define DFW_DRAW_BAND_H
#include "dfw.h"
#include "panel_geometry.h"

/// Receives one pixel of the ring: x, y in the 198 frame's own coordinates (they may be below 0 or past 197), and its
/// final color over what lies under it there (the frame's ground inside the 198 square, the panel's black outside).
typedef void (*dfw_put)(void *ctx, int x, int y, dfw_pixel color);

/// Puts every pixel the ring covers, once each, and nothing else. None with no time, an unknown length, the display
/// stale, or not drawing. Pure: the unit in, the puts out, no state of its own (#515 compares it Arm against native).
void dfw_band_pixels(const dfw_unit *unit, dfw_put put, void *ctx);

/// Block B's band entry (#524): the ring's pixels outside the 198 square into layer 2 (320 x 240 RGB565, stride 320),
/// turned as the frame is: frame (x, y) lands at panel (61 + 197 - x, 21 + 197 - y). Each pixel of the band's
/// annulus outside the square is visited once and gets its final value, black where the ring doesn't reach, written
/// only if the layer doesn't hold it already (#468: the layer is visible, so a clear-then-draw showed). A ring that
/// goes (a deck change, an unknown length) leaves nothing behind; an unchanged one writes nothing. Pixels inside the
/// square are the frame's, drawn by dfw_draw, and never touched.
void dfw_draw_band(uint16_t *layer, const dfw_unit *unit);

/// The band through the layer seam (panel_geometry.h): dfw_draw_band over the real layer, the tests and frame-dump over
/// their own adapters.
void dfw_band_layer(const dfw_unit *unit, const dfw_layer *layer);


#endif
