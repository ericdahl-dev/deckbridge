#include "messages.h"
#include "protocol.h"

static void send(dfw_unit *unit, uint8_t op, const uint8_t *args, size_t count) {
    static const uint8_t header[] = DFW_HEADER;
    uint8_t bytes[DFW_MESSAGE_MAX];
    size_t n = 0;
    for (size_t i = 0; i < sizeof header; i++) bytes[n++] = header[i];
    size_t length = count + 1;
    bytes[n++] = DFW_COMMAND;
    bytes[n++] = (uint8_t)(length >> 7);
    bytes[n++] = (uint8_t)(length & 0x7F);
    bytes[n++] = op;
    for (size_t i = 0; i < count; i++) bytes[n++] = args[i];
    bytes[n++] = 0xF7;
    dfw_message(unit, bytes, n);
}

static void word(uint8_t *out, unsigned value) {
    out[0] = (uint8_t)((value >> 7) & 0x7F);
    out[1] = (uint8_t)(value & 0x7F);
}

void send_begin(dfw_unit *unit) { const uint8_t a[] = { DFW_PROTOCOL_VERSION }; send(unit, DFW_OP_BEGIN, a, 1); }
void send_end(dfw_unit *unit) { const uint8_t a[] = { DFW_PROTOCOL_VERSION }; send(unit, DFW_OP_END, a, 1); }

void send_deck(dfw_unit *unit, uint8_t number, uint8_t r, uint8_t g, uint8_t b, uint8_t player) {
    uint8_t a[8] = { number };
    word(a + 1, r);
    word(a + 3, g);
    word(a + 5, b);
    a[7] = player;
    send(unit, DFW_OP_DECK, a, 8);
}

void send_state(dfw_unit *unit, uint8_t flags) { send(unit, DFW_OP_STATE, &flags, 1); }
void send_beat(dfw_unit *unit, uint8_t beat) { send(unit, DFW_OP_BEAT, &beat, 1); }

void send_needle(dfw_unit *unit, uint16_t angle) {
    uint8_t a[2];
    word(a, angle);
    send(unit, DFW_OP_NEEDLE, a, 2);
}

void send_meter(dfw_unit *unit, uint8_t level, uint8_t peak) {
    const uint8_t a[] = { level, peak };
    send(unit, DFW_OP_METER, a, 2);
}

void send_time(dfw_unit *unit, uint16_t elapsed, uint16_t length) {
    uint8_t a[4];
    word(a, elapsed);
    word(a + 2, length);
    send(unit, DFW_OP_TIME, a, 4);
}

void send_tempo(dfw_unit *unit, uint16_t tenths) {
    uint8_t a[2];
    word(a, tenths);
    send(unit, DFW_OP_TEMPO, a, 2);
}

void send_phase(dfw_unit *unit, int16_t phase) {
    uint8_t a[2];
    word(a, (unsigned)phase & 0x3FFFu);
    send(unit, DFW_OP_PHASE, a, 2);
}

void send_text(dfw_unit *unit, uint8_t field, const uint8_t *codes, size_t count) {
    uint8_t a[1 + 2 * DFW_TEXT_MAX];
    size_t n = 0;
    a[n++] = field;
    for (size_t i = 0; i < count && n + 2 <= sizeof a; i++) {
        if (codes[i] >= 0x80) {
            a[n++] = 0x7F;
            a[n++] = (uint8_t)(codes[i] - 0x80);
        } else {
            a[n++] = codes[i];
        }
    }
    send(unit, DFW_OP_TEXT, a, n);
}
