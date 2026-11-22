// The host's messages, framed for the chip's tests (#573): tests drive the unit through these, as the host does, rather
// than setting dfw_unit's fields. Each is copied in with dfw_message; the next dfw_tick acts on them.
#ifndef TEST_MESSAGES_H
#define TEST_MESSAGES_H
#include "dfw.h"

void send_begin(dfw_unit *unit);
void send_end(dfw_unit *unit);
void send_deck(dfw_unit *unit, uint8_t number, uint8_t r, uint8_t g, uint8_t b, uint8_t player);
void send_state(dfw_unit *unit, uint8_t flags);
void send_beat(dfw_unit *unit, uint8_t beat);
void send_needle(dfw_unit *unit, uint16_t angle);
void send_meter(dfw_unit *unit, uint8_t level, uint8_t peak);
void send_time(dfw_unit *unit, uint16_t elapsed, uint16_t length);
void send_tempo(dfw_unit *unit, uint16_t tenths);
void send_phase(dfw_unit *unit, int16_t phase);
/// A text field from Windows-1252 codes, escaping 0x80 and up as the host does.
void send_text(dfw_unit *unit, uint8_t field, const uint8_t *codes, size_t count);

#endif
