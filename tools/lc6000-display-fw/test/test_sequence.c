// The sequence rules (#464): the host re-sends begin, the deck and the state once a second while drawing.
#include "harness.h"
#include "view.h"

#define BEGIN_V1 "F0 00 02 0B 7F 10 20 00 02 01 01 F7"
#define DECK_2_RED_TRACK "F0 00 02 0B 7F 10 20 00 09 03 02 01 7F 00 00 00 00 01 F7"
#define STATE_ALL "F0 00 02 0B 7F 10 20 00 02 07 3F F7"

static dfw_unit unit;

/// What drawing would see now (#573): the tests read this, never dfw_unit's fields.
static dfw_view view(void) {
    dfw_view v;
    dfw_view_of(&unit, &v);
    return v;
}
static recording rec;

void begin_while_drawing_changes_nothing(void) {
    fresh(&unit, &rec);
    feed(&unit, BEGIN_V1);
    feed(&unit, DECK_2_RED_TRACK);
    feed(&unit, STATE_ALL);
    dfw_tick(&unit, 0);
    feed(&unit, BEGIN_V1);
    dfw_tick(&unit, 0);
    CHECK(rec.presents == 1);
    CHECK(view().deck.number == 2);
    CHECK(view().flags == 0x3F);
}

#define DECK_3_RED_TRACK "F0 00 02 0B 7F 10 20 00 09 03 03 01 7F 00 00 00 00 01 F7"
#define BEAT_2 "F0 00 02 0B 7F 10 20 00 02 08 02 F7"
#define NEEDLE_4096 "F0 00 02 0B 7F 10 20 00 03 09 20 00 F7"
#define METER_64_90 "F0 00 02 0B 7F 10 20 00 03 0A 40 5A F7"

void a_deck_clears_the_deck_flags_but_not_stale(void) {
    fresh(&unit, &rec);
    feed(&unit, BEGIN_V1);
    feed(&unit, DECK_2_RED_TRACK);
    feed(&unit, STATE_ALL);
    feed(&unit, DECK_3_RED_TRACK);
    dfw_tick(&unit, 0);
    CHECK(view().flags == 0x20);
}

/// The heartbeat (#459, agent3's review): an unchanged deck keeps its flags, and a whole unchanged heartbeat presents
/// nothing, so the screen isn't redrawn once a second for nothing.
void an_unchanged_heartbeat_presents_nothing(void) {
    fresh(&unit, &rec);
    feed(&unit, BEGIN_V1);
    feed(&unit, DECK_2_RED_TRACK);
    feed(&unit, STATE_ALL);
    feed(&unit, BEAT_2);
    feed(&unit, NEEDLE_4096);
    feed(&unit, METER_64_90);
    dfw_tick(&unit, 0);
    CHECK(rec.presents == 1);
    feed(&unit, BEGIN_V1);
    feed(&unit, DECK_2_RED_TRACK);
    dfw_tick(&unit, 500);   // the deck and its state may land in different ticks
    CHECK(view().flags == 0x3F);
    feed(&unit, STATE_ALL);
    feed(&unit, BEAT_2);
    feed(&unit, NEEDLE_4096);
    feed(&unit, METER_64_90);
    dfw_tick(&unit, 1000);
    CHECK(rec.presents == 1);
    CHECK(view().flags == 0x3F);
}

#define DECK_4_BLUE_EMPTY "F0 00 02 0B 7F 10 20 00 09 03 04 00 00 01 00 01 7F 00 F7"
#define METER_0_0 "F0 00 02 0B 7F 10 20 00 03 0A 00 00 F7"

/// Begin and deck 4, drawn once.
static void drawing_deck_4(void) {
    fresh(&unit, &rec);
    feed(&unit, BEGIN_V1);
    feed(&unit, DECK_4_BLUE_EMPTY);
    dfw_tick(&unit, 0);
}

/// The meter (#461): the first meter message draws it even at silence, the values a fresh unit holds, since until one
/// comes there is no meter at all.
void the_first_meter_at_silence_presents(void) {
    drawing_deck_4();
    CHECK(rec.presents == 1);
    feed(&unit, METER_0_0);
    dfw_tick(&unit, 10);
    CHECK(rec.presents == 2);
}

void a_changed_meter_presents(void) {
    drawing_deck_4();
    feed(&unit, METER_0_0);
    dfw_tick(&unit, 10);
    feed(&unit, METER_64_90);
    dfw_tick(&unit, 20);
    CHECK(rec.presents == 3);
}

void the_same_meter_does_not_present_again(void) {
    drawing_deck_4();
    feed(&unit, METER_64_90);
    dfw_tick(&unit, 10);
    feed(&unit, METER_64_90);
    dfw_tick(&unit, 20);
    CHECK(rec.presents == 2);
}

/// End forgets the meter: after a new begin, the first meter message draws it again, even at silence.
void end_forgets_the_meter(void) {
    drawing_deck_4();
    feed(&unit, METER_0_0);
    dfw_tick(&unit, 10);
    feed(&unit, "F0 00 02 0B 7F 10 20 00 02 02 01 F7");
    feed(&unit, BEGIN_V1);
    feed(&unit, DECK_4_BLUE_EMPTY);
    dfw_tick(&unit, 20);
    CHECK(rec.presents == 3);
    feed(&unit, METER_0_0);
    dfw_tick(&unit, 30);
    CHECK(rec.presents == 4);
}

#define TITLE_STROBE "F0 00 02 0B 7F 10 20 00 08 04 00 53 74 72 6F 62 65 F7"
#define TEMPO_128 "F0 00 02 0B 7F 10 20 00 03 05 0A 00 F7"

/// Text and tempo ride the heartbeat too (#458): sent again unchanged, they present nothing.
void an_unchanged_text_or_tempo_presents_nothing(void) {
    fresh(&unit, &rec);
    feed(&unit, BEGIN_V1);
    feed(&unit, DECK_2_RED_TRACK);
    feed(&unit, TITLE_STROBE);
    feed(&unit, TEMPO_128);
    dfw_tick(&unit, 0);
    CHECK(rec.presents == 1);
    feed(&unit, TITLE_STROBE);
    feed(&unit, TEMPO_128);
    dfw_tick(&unit, 1000);
    CHECK(rec.presents == 1);
}

/// A new deck's text and tempo wait for its own messages, as its flags do: the old deck's title never shows on it.
void a_deck_change_clears_the_text_and_tempo(void) {
    fresh(&unit, &rec);
    feed(&unit, BEGIN_V1);
    feed(&unit, DECK_2_RED_TRACK);
    feed(&unit, TITLE_STROBE);
    feed(&unit, TEMPO_128);
    feed(&unit, DECK_2_RED_TRACK);   // the heartbeat's same deck keeps them
    dfw_tick(&unit, 0);
    CHECK(view().text_length[0] == 6 && view().tempo == 1280);
    feed(&unit, DECK_3_RED_TRACK);
    dfw_tick(&unit, 100);
    CHECK(view().text_length[0] == 0 && view().tempo == 0);
}

#define TITLE_EMPTY "F0 00 02 0B 7F 10 20 00 02 04 00 F7"

/// The words wait for the new deck's own text (#458): until one comes, no text is drawn, so a deck change never
/// flashes the empty deck's words for a tick. An empty title counts: it's how an empty deck says so.
void a_new_decks_words_wait_for_its_text(void) {
    fresh(&unit, &rec);
    feed(&unit, BEGIN_V1);
    feed(&unit, DECK_2_RED_TRACK);
    dfw_tick(&unit, 0);
    CHECK(!view().text_heard);
    feed(&unit, TITLE_STROBE);
    dfw_tick(&unit, 10);
    CHECK(view().text_heard);
    feed(&unit, DECK_2_RED_TRACK);   // the heartbeat's same deck: still heard
    dfw_tick(&unit, 20);
    CHECK(view().text_heard);
    feed(&unit, DECK_3_RED_TRACK);
    dfw_tick(&unit, 30);
    CHECK(!view().text_heard);
    feed(&unit, TITLE_EMPTY);
    dfw_tick(&unit, 40);
    CHECK(view().text_heard);
}

#define TIME_65_OF_293 "F0 00 02 0B 7F 10 20 00 05 06 00 41 02 25 F7"
#define TIME_66_OF_293 "F0 00 02 0B 7F 10 20 00 05 06 00 42 02 25 F7"
#define TIME_0_OF_0 "F0 00 02 0B 7F 10 20 00 05 06 00 00 00 00 F7"

/// Time (#460): the first time message presents even at 0 of unknown, the values a fresh unit holds; a changed one
/// presents; the heartbeat's unchanged one presents nothing.
void the_first_time_presents_and_an_unchanged_one_does_not(void) {
    drawing_deck_4();
    CHECK(!view().time_heard);
    feed(&unit, TIME_0_OF_0);
    dfw_tick(&unit, 10);
    CHECK(view().time_heard && rec.presents == 2);
    feed(&unit, TIME_65_OF_293);
    dfw_tick(&unit, 20);
    CHECK(rec.presents == 3);
    feed(&unit, TIME_65_OF_293);
    dfw_tick(&unit, 1000);
    CHECK(rec.presents == 3);
    feed(&unit, TIME_66_OF_293);
    dfw_tick(&unit, 1010);
    CHECK(rec.presents == 4 && view().elapsed == 66 && view().track_length == 293);
}

/// A new deck's time waits for its own message, as its text does: the host sends it right after.
void a_deck_change_clears_the_time(void) {
    drawing_deck_4();
    feed(&unit, TIME_65_OF_293);
    feed(&unit, DECK_4_BLUE_EMPTY);   // the heartbeat's same deck keeps it
    dfw_tick(&unit, 10);
    CHECK(view().time_heard && view().elapsed == 65);
    feed(&unit, DECK_3_RED_TRACK);
    dfw_tick(&unit, 20);
    CHECK(!view().time_heard && view().elapsed == 0 && view().track_length == 0);
    feed(&unit, TIME_65_OF_293);
    dfw_tick(&unit, 30);
    CHECK(view().time_heard && rec.presents == 4);
}

/// End forgets the time: after a new begin there is none until a time message comes.
void end_forgets_the_time(void) {
    drawing_deck_4();
    feed(&unit, TIME_65_OF_293);
    feed(&unit, "F0 00 02 0B 7F 10 20 00 02 02 01 F7");
    feed(&unit, BEGIN_V1);
    feed(&unit, DECK_4_BLUE_EMPTY);
    dfw_tick(&unit, 10);
    CHECK(!view().time_heard);
}

/// Only drawn mode takes the time, as every other live element.
void a_time_before_begin_is_dropped(void) {
    fresh(&unit, &rec);
    feed(&unit, TIME_65_OF_293);
    feed(&unit, BEGIN_V1);
    feed(&unit, DECK_4_BLUE_EMPTY);
    dfw_tick(&unit, 0);
    CHECK(!view().time_heard);
}

#define PHASE_AHEAD "F0 00 02 0B 7F 10 20 00 03 0B 01 24 F7"
#define END_V1 "F0 00 02 0B 7F 10 20 00 02 02 01 F7"

/// The phase is unknown until the deck's own phase message comes (#462): a new deck, or a new begin after end, draws
/// the plain rule rather than the last deck's bar.
void the_phase_is_unknown_until_the_decks_own_phase_comes(void) {
    fresh(&unit, &rec);
    feed(&unit, BEGIN_V1);
    feed(&unit, DECK_2_RED_TRACK);
    dfw_tick(&unit, 0);
    CHECK(view().phase == DFW_PHASE_UNKNOWN);
    feed(&unit, PHASE_AHEAD);
    feed(&unit, DECK_2_RED_TRACK);   // the heartbeat's same deck keeps it
    dfw_tick(&unit, 10);
    CHECK(view().phase == 164);
    feed(&unit, DECK_3_RED_TRACK);
    dfw_tick(&unit, 20);
    CHECK(view().phase == DFW_PHASE_UNKNOWN);
    feed(&unit, PHASE_AHEAD);
    feed(&unit, END_V1);
    feed(&unit, BEGIN_V1);
    dfw_tick(&unit, 30);
    CHECK(view().phase == DFW_PHASE_UNKNOWN);
}

/// The phase rides the heartbeat: sent again unchanged, it presents nothing.
void an_unchanged_phase_presents_nothing(void) {
    fresh(&unit, &rec);
    feed(&unit, BEGIN_V1);
    feed(&unit, DECK_2_RED_TRACK);
    feed(&unit, PHASE_AHEAD);
    dfw_tick(&unit, 0);
    CHECK(rec.presents == 1);
    feed(&unit, PHASE_AHEAD);
    dfw_tick(&unit, 1000);
    CHECK(rec.presents == 1);
}
