// The drawn jog display (#455): message bytes in, a drawn frame out. Called only from the stock image's hook: one
// call per display message, and a periodic draw tick. No allocation; the frame is a fixed back buffer
// the caller hands in.
#ifndef DFW_H
#define DFW_H
#include <stddef.h>
#include <stdint.h>

#define DFW_SIZE 198

/// One pixel of the back buffer. The panel's own format is the hook's business (#466/#467), not this code's.
typedef uint32_t dfw_pixel;

/// Where frames and replies go: the panel on the unit, a recording stub in the tests.
typedef struct {
    void (*present)(void *ctx, const dfw_pixel *frame);
    /// A reply to the host, F0 through F7 (on the unit: the stock ack sender, on WD's cable).
    void (*send)(void *ctx, const uint8_t *bytes, size_t length);
    void *ctx;
} dfw_port;

/// The protocol's caps come from its one description (#569), through the generated protocol.h: DFW_TEXT_MAX, the most
/// a text message carries (96 bytes of characters after escapes, #458); DFW_TEXT_FIELDS, title, artist, key and the
/// untitled words; DFW_MESSAGE_MAX, the longest message kept (text's 108 bytes with room to spare; longer is dropped).
#include "protocol.h"
/// Messages waiting for the next tick. The hook copies them in as the stock parser dispatches them (main loop, #466),
/// never keeping a pointer into the stock SysEx buffer; the tick acts on them.
#define DFW_INBOX 16

typedef struct {
    uint8_t length;
    uint8_t bytes[DFW_MESSAGE_MAX];
} dfw_slot;

struct dfw_unit;
/// The drawing, as a table of entry points: the protocol calls it only through this, so it can live in its own
/// block (#501). The hook passes NULL until it has a drawing it trusts; then nothing is drawn and the capability ask
/// gets no answer.
typedef struct {
    /// Writes all DFW_SIZE x DFW_SIZE pixels for the unit's deck in front.
    void (*draw)(dfw_pixel *frame, const struct dfw_unit *unit);
} dfw_drawing;

/// The deck in front, as the deck message gave it.
typedef struct { uint8_t number, r, g, b, player; } dfw_deck_state;

/// The phase message's reserved value (#462): not measured (not playing, no master clock, none since load).
#define DFW_PHASE_UNKNOWN DFW_PHASE_UNKNOWN_VALUE

typedef struct dfw_unit {
    dfw_port port;
    const dfw_drawing *drawing;
    volatile uint8_t head, tail;
    dfw_slot inbox[DFW_INBOX];
    uint8_t drawn;
    dfw_deck_state deck;
    /// The state message's flags: bit 0 loaded, 1 playing, 2 play pending, 3 cue held, 4 loop on, 5 feedback stale.
    uint8_t flags;
    /// The master clock's beat, 1-4, or 0 with none (#459); the deck's needle, 0-16383 for a turn from 12 o'clock.
    uint8_t beat;
    uint16_t needle;
    /// The deck's mixer channel (#461): its level and the peak being held, 0-127.
    uint8_t level, peak;
    /// Whether a needle message has come since begin: until one does, no marker is drawn.
    uint8_t needle_heard;
    /// Whether a meter message has come since begin: until one does, no meter is drawn.
    uint8_t meter_heard;
    /// The texts as Windows-1252 codes (0x81 the box), and the tempo in tenths of a BPM, 0 for none (#458).
    uint8_t text[DFW_TEXT_FIELDS][DFW_TEXT_MAX];
    uint8_t text_length[DFW_TEXT_FIELDS];
    uint16_t tempo;
    /// Whether a text message has come since the deck last changed: until one has, no words are drawn (#458).
    uint8_t text_heard;
    /// The deck's track time (#460): elapsed and the track's length in whole seconds, 0-16383; a length of 0 is
    /// unknown. Whether a time message has come since the deck last changed: until one has, none is drawn.
    uint16_t elapsed, track_length;
    uint8_t time_heard;
    /// When the time last changed, on the tick's clock: the last minute's warning blinks from it.
    uint32_t time_at;
    /// How the time looks now (dfw_time_look), worked out at each tick so a flip of the blink draws a frame.
    uint8_t time_look;
    /// How far the deck is from the master clock's beat (#462), in 1/16384 beats, -8191 to 8191; negative is behind,
    /// 0 in phase, DFW_PHASE_UNKNOWN not measured.
    int16_t phase;
    /// When the last of our messages came, and whether 3 s have passed since (the waiting look).
    uint32_t heard;
    /// The clock at the tick that is drawing, for anything drawn over time.
    uint32_t now_ms;
    uint8_t silent;
    uint8_t dirty;
    /// The back buffer, DFW_SIZE * DFW_SIZE pixels, owned by the caller: on the unit it lives in SDRAM (#466).
    dfw_pixel *frame;
} dfw_unit;

/// The track time's look (#460, #524, JogTrackTime): no warning; the warning's red (the first 500 ms of each second of
/// the blink, from when the time last changed); the blink's white half, text and fill, whatever the deck color.
enum { DFW_TIME_NORMAL = 0, DFW_TIME_RED = 1, DFW_TIME_WHITE = 2 };
/// dfw_unit's layout as one word (#516): block B, the drawing, reads A's dfw_unit, so B's header carries the layout
/// it was built for and block A calls B only when it matches A's own. Each field's offset has its own odd multiplier,
/// so a moved, resized or swapped field changes the word. A new field in dfw_unit or dfw_deck_state goes in here too.
#define DFW_LAYOUT ((uint32_t)( \
    1u * sizeof(dfw_unit) + 3u * sizeof(dfw_deck_state) + 5u * sizeof(dfw_slot) + 7u * sizeof(dfw_port) + \
    11u * sizeof(dfw_pixel) + 13u * DFW_SIZE + 17u * DFW_TEXT_MAX + 19u * DFW_TEXT_FIELDS + 23u * DFW_INBOX + \
    29u * offsetof(dfw_unit, port) + 31u * offsetof(dfw_unit, drawing) + 37u * offsetof(dfw_unit, head) + \
    41u * offsetof(dfw_unit, tail) + 43u * offsetof(dfw_unit, inbox) + 47u * offsetof(dfw_unit, drawn) + \
    53u * offsetof(dfw_unit, deck) + 59u * offsetof(dfw_unit, flags) + 61u * offsetof(dfw_unit, beat) + \
    67u * offsetof(dfw_unit, needle) + 71u * offsetof(dfw_unit, level) + 73u * offsetof(dfw_unit, peak) + \
    79u * offsetof(dfw_unit, needle_heard) + 83u * offsetof(dfw_unit, meter_heard) + \
    89u * offsetof(dfw_unit, text) + 97u * offsetof(dfw_unit, text_length) + 101u * offsetof(dfw_unit, tempo) + \
    103u * offsetof(dfw_unit, text_heard) + 163u * offsetof(dfw_unit, phase) + 107u * offsetof(dfw_unit, heard) + \
    167u * offsetof(dfw_unit, elapsed) + 173u * offsetof(dfw_unit, track_length) + \
    179u * offsetof(dfw_unit, time_heard) + 181u * offsetof(dfw_unit, time_at) + \
    191u * offsetof(dfw_unit, time_look) + \
    109u * offsetof(dfw_unit, now_ms) + 113u * offsetof(dfw_unit, silent) + 127u * offsetof(dfw_unit, dirty) + \
    131u * offsetof(dfw_unit, frame) + 137u * offsetof(dfw_deck_state, number) + \
    139u * offsetof(dfw_deck_state, r) + 149u * offsetof(dfw_deck_state, g) + \
    151u * offsetof(dfw_deck_state, b) + 157u * offsetof(dfw_deck_state, player)))

/// Starts the unit. `frame` may be NULL until the hook has one (see dfw_set_frame); `drawing` is NULL when there is
/// none to call.
void dfw_init(dfw_unit *unit, const dfw_port *port, dfw_pixel *frame, const dfw_drawing *drawing);
/// Hands in the back buffer. Until there is one, nothing is drawn and the capability ask gets no answer.
void dfw_set_frame(dfw_unit *unit, dfw_pixel *frame);
/// One whole display message, F0 through F7. Only copies it; the tick acts on it.
void dfw_message(dfw_unit *unit, const uint8_t *bytes, size_t length);
/// The draw tick: acts on the waiting messages, then presents a frame if something changed. `now_ms` is a
/// millisecond clock that may wrap (on the unit, the HAL tick).
void dfw_tick(dfw_unit *unit, uint32_t now_ms);
/// Whether the display shows the waiting look: the host says feedback stopped, or nothing came for 3 s.
int dfw_stale(const dfw_unit *unit);

#endif
