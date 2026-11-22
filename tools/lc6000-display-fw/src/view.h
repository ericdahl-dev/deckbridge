// What a drawing needs to know about the unit (#573, #570): exactly the values the drawing code reads, as one const
// struct, filled from the unit by one function. The chip's tests read this, never dfw_unit's fields, so they test the
// interface, not the struct's layout.
//
// For now `dfw_view_of` lives with the tests (test/view.c), so neither block's bytes change. #570 makes it real: block A
// fills this same view and hands it to block B, which then reads nothing else of A's; the tests don't change again.
#ifndef DFW_VIEW_H
#define DFW_VIEW_H
#include "dfw.h"

typedef struct {
    /// Between begin and end.
    uint8_t drawn;
    /// The deck in front, as its deck message gave it; number 0 before one.
    dfw_deck_state deck;
    /// The state message's flags (protocol.h's DFW_FLAG_*), and the waiting look: the stale flag, or 3 s of silence.
    uint8_t flags, stale;
    /// The master beat, 1-4, or 0 with none.
    uint8_t beat;
    /// The needle, 0-16383 for a turn from 12 o'clock, once a needle message has come.
    uint8_t needle_heard;
    uint16_t needle;
    /// The deck's mixer channel, level and held peak 0-127, once a meter message has come.
    uint8_t meter_heard, level, peak;
    /// The texts as Windows-1252 codes, once a text message has come since the deck changed.
    uint8_t text_heard;
    uint8_t text_length[DFW_TEXT_FIELDS];
    uint8_t text[DFW_TEXT_FIELDS][DFW_TEXT_MAX];
    /// Tenths of a BPM, 0 for none.
    uint16_t tempo;
    /// The track time in whole seconds, once a time message has come; a length of 0 is unknown. Its look now:
    /// DFW_TIME_NORMAL, _RED or _WHITE.
    uint8_t time_heard;
    uint16_t elapsed, track_length;
    uint8_t time_look;
    /// 1/16384 beats from the master, negative behind; DFW_PHASE_UNKNOWN when not measured.
    int16_t phase;
} dfw_view;

/// The view of `unit` now.
void dfw_view_of(const dfw_unit *unit, dfw_view *view);

#endif
