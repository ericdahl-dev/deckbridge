// Feedback stopping (#464): no drawn-display message for 3 s and the unit draws the waiting look; any message
// clears it. The host's heartbeat re-sends begin, the deck and the state once a second, so 3 s is three missed beats.
#include "harness.h"

#define BEGIN_V1 "F0 00 02 0B 7F 10 20 00 02 01 01 F7"
#define DECK_2_RED_TRACK "F0 00 02 0B 7F 10 20 00 09 03 02 01 7F 00 00 00 00 01 F7"
#define STATE_LOADED "F0 00 02 0B 7F 10 20 00 02 07 01 F7"

static dfw_unit unit;
static recording rec;

static void drawing_since(uint32_t start) {
    fresh(&unit, &rec);
    feed(&unit, BEGIN_V1);
    feed(&unit, DECK_2_RED_TRACK);
    dfw_tick(&unit, start);
}

void three_seconds_of_silence_is_stale(void) {
    drawing_since(1000);
    dfw_tick(&unit, 3999);
    CHECK(!dfw_stale(&unit));
    CHECK(rec.presents == 1);
    dfw_tick(&unit, 4000);
    CHECK(dfw_stale(&unit));
    CHECK(rec.presents == 2);   // redrawn once, as the waiting look
    dfw_tick(&unit, 9000);
    CHECK(rec.presents == 2);
}

void any_message_clears_the_silence(void) {
    drawing_since(1000);
    dfw_tick(&unit, 4000);
    feed(&unit, STATE_LOADED);
    dfw_tick(&unit, 4500);
    CHECK(!dfw_stale(&unit));
    CHECK(rec.presents == 3);
}

void garbage_doesnt_count_as_a_message(void) {
    drawing_since(1000);
    feed(&unit, "F0 00 02 0B 7F 10 20 00 02 07 40 F7");   // reserved bit: ignored
    dfw_tick(&unit, 3500);
    dfw_tick(&unit, 4000);
    CHECK(dfw_stale(&unit));
}

void the_clock_wrapping_isnt_silence(void) {
    drawing_since(0xFFFFFC00u);
    dfw_tick(&unit, 0x00000400u);   // 2048 ms later, across the wrap
    CHECK(!dfw_stale(&unit));
    dfw_tick(&unit, 0x000007E8u);   // 3048 ms
    CHECK(dfw_stale(&unit));
}

void the_stale_flag_is_stale_too(void) {
    drawing_since(1000);
    feed(&unit, "F0 00 02 0B 7F 10 20 00 02 07 21 F7");   // loaded, feedback stale
    dfw_tick(&unit, 1100);
    CHECK(dfw_stale(&unit));
}
