// Malformed messages (#455): anything that isn't exactly one of ours is ignored, and nothing crashes.
#include "harness.h"
#include <string.h>

#define BEGIN_V1 "F0 00 02 0B 7F 10 20 00 02 01 01 F7"
#define DECK_2_RED_TRACK "F0 00 02 0B 7F 10 20 00 09 03 02 01 7F 00 00 00 00 01 F7"

static dfw_unit unit;
static recording rec;

static int presents_after_begin(const char *bad) {
    fresh(&unit, &rec);
    feed(&unit, BEGIN_V1);
    feed(&unit, bad);
    dfw_tick(&unit, 0);
    return rec.presents;
}

void a_malformed_deck_is_ignored(void) {
    CHECK(presents_after_begin("F0 00 02 0B 7F 10 20 00 09 03 02 01 7F F7") == 0);              // cut short
    CHECK(presents_after_begin("F0 00 02 0B 7F 10 20 00 09 03 05 01 7F 00 00 00 00 01 F7") == 0); // deck 5
    CHECK(presents_after_begin("F0 00 02 0B 7F 10 20 00 09 03 02 01 7F 00 00 00 00 06 F7") == 0); // player 6
    CHECK(presents_after_begin("F0 00 02 0B 7F 10 20 00 09 03 02 02 00 00 00 00 00 01 F7") == 0); // color 256
    CHECK(presents_after_begin("F0 00 02 0B 7F 10 20 00 09 03 02 81 7F 00 00 00 00 01 F7") == 0); // a top bit
    CHECK(presents_after_begin("F0 00 02 0B 7F 10 20 00 09 03 02 01 7F 00 00 00 00 01") == 0);    // no F7
}

/// The stock validator doesn't check these (#466), so ours must: the bytes received are exactly len + 10, and F7
/// sits at offset 9 + len.
void the_length_and_the_f7_are_checked_against_the_bytes_received(void) {
    // len 9, but 21 bytes arrive: F7 at 9 + len, then one more
    CHECK(presents_after_begin("F0 00 02 0B 7F 10 20 00 09 03 02 01 7F 00 00 00 00 01 F7 F7") == 0);
    // 19 bytes, as len 9 needs, but the F7 isn't at offset 18
    CHECK(presents_after_begin("F0 00 02 0B 7F 10 20 00 09 03 02 01 7F 00 00 00 00 F7 01") == 0);
    // F7 where len 8 would put it, with len 9 declared
    CHECK(presents_after_begin("F0 00 02 0B 7F 10 20 00 09 03 02 01 7F 00 00 00 00 F7") == 0);
}

/// Commands 0x78 and 0x79 write the unit's settings flash (#466): framed like ours, they're still never acted on,
/// and nothing is sent back.
void the_settings_flash_commands_are_never_acted_on(void) {
    const char *flash[] = { "F0 00 02 0B 7F 10 78 00 02 00 01 F7", "F0 00 02 0B 7F 10 79 00 02 00 01 F7",
                            "F0 00 02 0B 7F 10 78 00 09 03 02 01 7F 00 00 00 00 01 F7" };
    for (size_t i = 0; i < sizeof flash / sizeof flash[0]; i++) {
        CHECK(presents_after_begin(flash[i]) == 0);
        CHECK(rec.sends == 0);
    }
}

void a_malformed_begin_is_ignored(void) {
    fresh(&unit, &rec);
    feed(&unit, "F0 00 02 0B 7F 10 20 00 02 01 00 F7");   // version 0
    feed(&unit, DECK_2_RED_TRACK);
    dfw_tick(&unit, 0);
    CHECK(rec.presents == 0);
}

void an_oversized_message_is_ignored(void) {
    fresh(&unit, &rec);
    feed(&unit, BEGIN_V1);
    uint8_t big[600];
    memset(big, 0x01, sizeof big);
    big[0] = 0xF0;
    big[sizeof big - 1] = 0xF7;
    dfw_message(&unit, big, sizeof big);
    feed(&unit, DECK_2_RED_TRACK);
    dfw_tick(&unit, 0);
    CHECK(rec.presents == 1);   // the good deck after it still lands
}

/// Seeded random bytes, some with our header in front: no crash (ASan, UBSan) and nothing drawn.
void random_bytes_change_nothing(void) {
    fresh(&unit, &rec);
    feed(&unit, BEGIN_V1);
    uint32_t seed = 457;
    static const uint8_t header[] = { 0xF0, 0x00, 0x02, 0x0B, 0x7F, 0x10, 0x20 };
    for (int round = 0; round < 20000; round++) {
        uint8_t bytes[48];
        seed = seed * 1664525u + 1013904223u;
        size_t length = (seed >> 24) % sizeof bytes;
        for (size_t i = 0; i < length; i++) {
            seed = seed * 1664525u + 1013904223u;
            bytes[i] = (uint8_t)(seed >> 24);
        }
        if (round % 2 && length >= sizeof header) memcpy(bytes, header, sizeof header);
        dfw_message(&unit, bytes, length);
        if (round % 7 == 0) dfw_tick(&unit, 0);
    }
    dfw_tick(&unit, 0);
    CHECK(rec.presents == 0);
    CHECK(rec.sends == 0);
}
