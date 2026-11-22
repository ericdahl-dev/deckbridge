#include "dfw.h"

#include <string.h>

/// The protocol's numbers come from its one description, vectors/messages.json, through the generated protocol.h (#569).
#include "protocol.h"

/// inMusic's SysEx header from the host to the unit, then our command (#456).
static const uint8_t host_header[] = DFW_HEADER;
#define DFW_CMD DFW_COMMAND
/// The protocol version this code speaks.
#define DFW_VERSION DFW_PROTOCOL_VERSION
enum { OP_CAPABILITY = DFW_OP_CAPABILITY, OP_BEGIN = DFW_OP_BEGIN, OP_END = DFW_OP_END, OP_DECK = DFW_OP_DECK,
       OP_TEXT = DFW_OP_TEXT, OP_TEMPO = DFW_OP_TEMPO, OP_TIME = DFW_OP_TIME, OP_STATE = DFW_OP_STATE,
       OP_BEAT = DFW_OP_BEAT, OP_NEEDLE = DFW_OP_NEEDLE, OP_METER = DFW_OP_METER, OP_PHASE = DFW_OP_PHASE };
/// A text escape: the next byte plus 0x80 is the Windows-1252 code.
#define TEXT_ESCAPE 0x7F
/// The state flag a message must not set (it's malformed), and the ones the chip reads: Syndicate's feedback has
/// stopped; the deck is playing; a loop is on, which holds the time's warning (#524).
#define STATE_RESERVED DFW_FLAG_RESERVED
#define FLAG_STALE DFW_FLAG_STALE
#define FLAG_PLAYING DFW_FLAG_PLAYING
#define FLAG_LOOP DFW_FLAG_LOOP_ON
/// No drawn-display message for this long draws the waiting look (#464): three missed heartbeats. The last minute's
/// warning (#460, #524): steady red with WARNING_SECONDS or fewer left, blinking with BLINK_SECONDS or fewer, and each
/// half of the blink BLINK_HALF_MS.
#define SILENCE_MS DFW_SILENCE_MS
#define WARNING_SECONDS DFW_WARNING_SECONDS
#define BLINK_SECONDS DFW_BLINK_SECONDS
#define BLINK_HALF_MS DFW_BLINK_HALF_MS

void dfw_init(dfw_unit *unit, const dfw_port *port, dfw_pixel *frame, const dfw_drawing *drawing) {
    memset(unit, 0, sizeof *unit);
    unit->port = *port;
    unit->frame = frame;
    unit->drawing = drawing;
}

void dfw_set_frame(dfw_unit *unit, dfw_pixel *frame) { unit->frame = frame; }

void dfw_message(dfw_unit *unit, const uint8_t *bytes, size_t length) {
    uint8_t next = (uint8_t)((unit->head + 1) % DFW_INBOX);
    if (length > DFW_MESSAGE_MAX || next == unit->tail) return;
    dfw_slot *slot = &unit->inbox[unit->head];
    memcpy(slot->bytes, bytes, length);
    slot->length = (uint8_t)length;
    unit->head = next;
}

/// Each op's one exact length, counting the op itself; 0 for an op this version doesn't take.
static uint8_t op_length(uint8_t op) {
    switch (op) {
    case OP_CAPABILITY: return DFW_OP_CAPABILITY_LENGTH;
    case OP_BEGIN: return DFW_OP_BEGIN_LENGTH;
    case OP_END: return DFW_OP_END_LENGTH;
    case OP_STATE: return DFW_OP_STATE_LENGTH;
    case OP_BEAT: return DFW_OP_BEAT_LENGTH;
    case OP_NEEDLE: return DFW_OP_NEEDLE_LENGTH;
    case OP_TEMPO: return DFW_OP_TEMPO_LENGTH;
    case OP_METER: return DFW_OP_METER_LENGTH;
    case OP_PHASE: return DFW_OP_PHASE_LENGTH;
    case OP_TIME: return DFW_OP_TIME_LENGTH;
    case OP_DECK: return DFW_OP_DECK_LENGTH;
    default: return 0;   // text (framed by len) and any op this version doesn't take
    }
}

/// A color channel sent as two 7-bit bytes, high then low; -1 if it's over 255.
static int channel(const uint8_t *two) { return two[0] > 1 ? -1 : (two[0] << 7) | two[1]; }

/// Whether an op's arguments are in range: versions are never 0, a deck is 1-4 with channels up to 255 and a known
/// player, and a state's reserved bit is clear.
static int in_range(uint8_t op, const uint8_t *args) {
    switch (op) {
    case OP_CAPABILITY: case OP_BEGIN: case OP_END:
        return args[0] != 0;
    case OP_DECK:
        return args[0] >= 1 && args[0] <= 4 && channel(args + 1) >= 0 && channel(args + 3) >= 0 &&
               channel(args + 5) >= 0 && args[7] <= 5;
    case OP_STATE:
        return !(args[0] & STATE_RESERVED);
    case OP_BEAT:
        return args[0] <= 4;
    case OP_NEEDLE: case OP_TEMPO: case OP_METER: case OP_PHASE: case OP_TIME:
        return 1;   // any 7-bit bytes are an angle, a tempo, a level and a peak, a phase, or two times
    default:
        return 0;
    }
}

/// Decodes a text message's characters into Windows-1252 codes; -1 if any is malformed: a code below 0x20, an escape
/// with nothing after it, or one of Windows-1252's undefined codes other than 0x81 (the box).
static int decode_text(const uint8_t *chars, size_t count, uint8_t *codes) {
    int n = 0;
    for (size_t i = 0; i < count; i++) {
        uint8_t code = chars[i];
        if (code == TEXT_ESCAPE) {
            if (++i == count) return -1;
            code = (uint8_t)(0x80 | chars[i]);
            if (code == 0x8D || code == 0x8F || code == 0x90 || code == 0x9D) return -1;
        } else if (code < 0x20) {
            return -1;
        }
        codes[n++] = code;
    }
    return n;
}

static void act(dfw_unit *unit, const uint8_t *bytes, size_t length, uint32_t now_ms) {
    size_t header = sizeof host_header;
    // header, cmd, two length bytes, the op and its args, F7
    if (length < header + 5 || memcmp(bytes, host_header, header) != 0 || bytes[header] != DFW_CMD) return;
    if (bytes[length - 1] != 0xF7) return;
    for (size_t i = 1; i < length - 1; i++) if (bytes[i] & 0x80) return;
    size_t declared = ((size_t)bytes[header + 1] << 7) | bytes[header + 2];
    const uint8_t *body = bytes + header + 3;
    uint8_t op = body[0];
    if (length != header + 4 + declared) return;
    const uint8_t *args = body + 1;
    // Text alone has no one length: its field and up to DFW_TEXT_MAX bytes of characters.
    uint8_t codes[DFW_TEXT_MAX];
    int code_count = 0;
    if (op == OP_TEXT) {
        if (declared < 2 || declared > 2 + DFW_TEXT_MAX || args[0] >= DFW_TEXT_FIELDS) return;
        code_count = decode_text(args + 1, declared - 2, codes);
        if (code_count < 0) return;
    } else if (declared == 0 || declared != op_length(op) || !in_range(op, args)) {
        return;
    }
    // One of ours: it counts as hearing from the host, and ends any silence.
    unit->heard = now_ms;
    if (unit->silent) {
        unit->silent = 0;
        unit->dirty = 1;
    }
    switch (op) {
    case OP_CAPABILITY:
        // No back buffer or no drawing means we can't draw: no answer, so the app falls back to images.
        if (unit->frame && unit->drawing) {
            // The reply header (as the unit's acks), then the version both sides speak.
            const uint8_t answer[] = { 0xF0, 0x00, 0x02, 0x0B, 0x01, 0x10, DFW_CMD, 0x00, 0x02, OP_CAPABILITY,
                                       args[0] < DFW_VERSION ? args[0] : DFW_VERSION, 0xF7 };
            unit->port.send(unit->port.ctx, answer, sizeof answer);
        }
        break;
    case OP_BEGIN:
        unit->drawn = 1;
        break;
    case OP_END:
        // Back to image mode: nothing waiting is drawn, and the deck is forgotten, so a later begin waits for a
        // new one rather than redrawing this.
        unit->drawn = 0;
        unit->dirty = 0;
        unit->deck = (dfw_deck_state){ 0, 0, 0, 0, 0 };
        unit->flags = 0;
        unit->beat = 0;
        unit->needle = 0;
        unit->needle_heard = 0;
        unit->level = 0;
        unit->peak = 0;
        unit->meter_heard = 0;
        unit->elapsed = 0;
        unit->track_length = 0;
        unit->time_heard = 0;
        unit->phase = DFW_PHASE_UNKNOWN;
        break;
    case OP_DECK: {
        if (!unit->drawn) break;
        dfw_deck_state deck = { args[0], (uint8_t)channel(args + 1), (uint8_t)channel(args + 3),
                                (uint8_t)channel(args + 5), args[7] };
        // The heartbeat's deck, unchanged, changes nothing: its flags stay and nothing is redrawn (#459).
        if (memcmp(&deck, &unit->deck, sizeof deck) == 0) break;
        unit->deck = deck;
        // A new deck's play flags wait for its own state message (#464); only feedback stale carries over. Its text
        // and tempo wait for their own messages too (#458), and its phase is unknown until its own comes (#462).
        unit->flags &= FLAG_STALE;
        memset(unit->text_length, 0, sizeof unit->text_length);
        unit->tempo = 0;
        unit->text_heard = 0;
        // The time too (#460): the host sends the new deck's right after.
        unit->elapsed = 0;
        unit->track_length = 0;
        unit->time_heard = 0;
        unit->phase = DFW_PHASE_UNKNOWN;
        unit->dirty = 1;
        break;
    }
    case OP_TEXT:
        if (!unit->drawn) break;
        // The first since the deck changed lets the words show, even an empty one (an empty deck's title).
        if (!unit->text_heard) {
            unit->text_heard = 1;
            unit->dirty = 1;
        }
        // Unchanged (the heartbeat's), it changes nothing.
        if (unit->text_length[args[0]] == code_count &&
            memcmp(unit->text[args[0]], codes, (size_t)code_count) == 0) break;
        memcpy(unit->text[args[0]], codes, (size_t)code_count);
        unit->text_length[args[0]] = (uint8_t)code_count;
        unit->dirty = 1;
        break;
    case OP_TEMPO: {
        uint16_t tempo = (uint16_t)((args[0] << 7) | args[1]);
        if (!unit->drawn || unit->tempo == tempo) break;
        unit->tempo = tempo;
        unit->dirty = 1;
        break;
    }
    case OP_PHASE: {
        // 14-bit two's complement: 8192 and up are behind.
        int raw = (args[0] << 7) | args[1];
        int16_t phase = (int16_t)(raw >= 8192 ? raw - 16384 : raw);
        if (!unit->drawn || unit->phase == phase) break;
        unit->phase = phase;
        unit->dirty = 1;
        break;
    }
    case OP_STATE:
        if (!unit->drawn || unit->flags == args[0]) break;
        unit->flags = args[0];
        unit->dirty = 1;
        break;
    case OP_BEAT:
        if (!unit->drawn || unit->beat == args[0]) break;
        unit->beat = args[0];
        unit->dirty = 1;
        break;
    case OP_METER:
        // The first one draws the meter, whatever its values; after that, only a change.
        if (!unit->drawn || (unit->meter_heard && unit->level == args[0] && unit->peak == args[1])) break;
        unit->level = args[0];
        unit->peak = args[1];
        unit->meter_heard = 1;
        unit->dirty = 1;
        break;
    case OP_TIME: {
        uint16_t elapsed = (uint16_t)((args[0] << 7) | args[1]), length = (uint16_t)((args[2] << 7) | args[3]);
        // The first one since the deck changed draws the time, whatever it is; after that, only a change.
        if (!unit->drawn || (unit->time_heard && unit->elapsed == elapsed && unit->track_length == length)) break;
        unit->elapsed = elapsed;
        unit->track_length = length;
        unit->time_heard = 1;
        // The blink's phase starts again, red, on the frame the time changes.
        unit->time_at = now_ms;
        unit->dirty = 1;
        break;
    }
    case OP_NEEDLE: {
        uint16_t angle = (uint16_t)((args[0] << 7) | args[1]);
        // The first one draws the marker, whatever its angle; after that, only a change.
        if (!unit->drawn || (unit->needle_heard && unit->needle == angle)) break;
        unit->needle = angle;
        unit->needle_heard = 1;
        unit->dirty = 1;
        break;
    }
    default:
        break;
    }
}

int dfw_stale(const dfw_unit *unit) { return unit->silent || (unit->flags & FLAG_STALE); }

/// The warning while playing, not looping (a loop holds it), a track of known length with a minute or less left: steady red, then from 30 s left
/// red for the first half of each second from the last change, then white. With no new time it keeps alternating off the last change (a dropped
/// message never freezes it red). Unsigned subtraction, so the clock wrapping is no jump.
static uint8_t time_look(const dfw_unit *unit, uint32_t now_ms) {
    if (!unit->time_heard || unit->track_length == 0 || !(unit->flags & FLAG_PLAYING) || (unit->flags & FLAG_LOOP) || dfw_stale(unit) ||
        (int)unit->track_length - (int)unit->elapsed > WARNING_SECONDS) return DFW_TIME_NORMAL;
    if ((int)unit->track_length - (int)unit->elapsed > BLINK_SECONDS) return DFW_TIME_RED;
    return ((now_ms - unit->time_at) / BLINK_HALF_MS) % 2u == 0 ? DFW_TIME_RED : DFW_TIME_WHITE;
}

void dfw_tick(dfw_unit *unit, uint32_t now_ms) {
    while (unit->tail != unit->head) {
        dfw_slot *slot = &unit->inbox[unit->tail];
        act(unit, slot->bytes, slot->length, now_ms);
        unit->tail = (uint8_t)((unit->tail + 1) % DFW_INBOX);
    }
    // Unsigned subtraction, so the clock wrapping isn't silence.
    if (unit->drawn && !unit->silent && now_ms - unit->heard >= SILENCE_MS) {
        unit->silent = 1;
        unit->dirty = 1;
    }
    // A flip of the warning's blink is a change too.
    uint8_t look = time_look(unit, now_ms);
    if (look != unit->time_look) {
        unit->time_look = look;
        unit->dirty = 1;
    }
    // Only drawn mode draws, and only once a deck is known.
    if (!unit->dirty || !unit->frame || !unit->drawing || !unit->drawn || unit->deck.number == 0) return;
    unit->dirty = 0;
    unit->now_ms = now_ms;
    unit->drawing->draw(unit->frame, unit);
    unit->port.present(unit->port.ctx, unit->frame);
}
