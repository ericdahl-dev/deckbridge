// The state message (op 07, #464): one flags byte, bit 6 reserved. Checked directly here too, so the decoder stays
// covered whichever side's vectors land first.
#include "harness.h"
#include "view.h"

#define BEGIN_V1 "F0 00 02 0B 7F 10 20 00 02 01 01 F7"

static dfw_unit unit;

/// What drawing would see now (#573): the tests read this, never dfw_unit's fields.
static dfw_view view(void) {
    dfw_view v;
    dfw_view_of(&unit, &v);
    return v;
}
static recording rec;

static int flags_after(const char *state) {
    fresh(&unit, &rec);
    feed(&unit, BEGIN_V1);
    feed(&unit, "F0 00 02 0B 7F 10 20 00 02 07 03 F7");   // loaded and playing
    feed(&unit, state);
    dfw_tick(&unit, 0);
    return view().flags;
}

void the_state_flags_decode(void) {
    CHECK(flags_after("F0 00 02 0B 7F 10 20 00 02 07 21 F7") == 0x21);   // loaded, feedback stale
    CHECK(flags_after("F0 00 02 0B 7F 10 20 00 02 07 3F F7") == 0x3F);
    CHECK(flags_after("F0 00 02 0B 7F 10 20 00 02 07 00 F7") == 0x00);
}

void a_state_with_the_reserved_bit_or_a_wrong_length_is_ignored(void) {
    CHECK(flags_after("F0 00 02 0B 7F 10 20 00 02 07 40 F7") == 0x03);
    CHECK(flags_after("F0 00 02 0B 7F 10 20 00 02 07 7F F7") == 0x03);
    CHECK(flags_after("F0 00 02 0B 7F 10 20 00 03 07 01 00 F7") == 0x03);
    CHECK(flags_after("F0 00 02 0B 7F 10 20 00 01 07 F7") == 0x03);
}

/// A relaunch after a quit (#600): the quit left deck 2 on the neutral hub, stale, still drawn (no end). The new app's
/// capability ask, begin, the deck in its own color and its state bring the deck screen back: not stale, its color.
void a_relaunch_after_a_quit_brings_the_deck_back(void) {
    fresh(&unit, &rec);
    feed(&unit, BEGIN_V1);
    feed(&unit, "F0 00 02 0B 7F 10 20 00 09 03 02 01 7F 00 00 00 00 01 F7");   // deck 2, red
    feed(&unit, "F0 00 02 0B 7F 10 20 00 02 07 03 F7");                        // loaded, playing
    feed(&unit, "F0 00 02 0B 7F 10 20 00 09 03 02 01 55 01 55 01 55 01 F7");   // quit: deck 2, D5D5D5
    feed(&unit, "F0 00 02 0B 7F 10 20 00 02 07 23 F7");                        // quit: stale
    dfw_tick(&unit, 0);
    CHECK(view().stale && view().drawn && view().deck.r == 0xD5);
    feed(&unit, "F0 00 02 0B 7F 10 20 00 02 00 01 F7");                        // relaunch: can you draw?
    feed(&unit, BEGIN_V1);
    feed(&unit, "F0 00 02 0B 7F 10 20 00 09 03 02 01 7F 00 00 00 00 01 F7");   // deck 2, red
    feed(&unit, "F0 00 02 0B 7F 10 20 00 02 07 01 F7");                        // loaded
    int before = rec.presents;
    dfw_tick(&unit, 40);
    CHECK(rec.presents == before + 1);
    CHECK(!view().stale);
    CHECK(view().deck.number == 2 && view().deck.r == 255 && view().deck.g == 0 && view().deck.b == 0);
}
