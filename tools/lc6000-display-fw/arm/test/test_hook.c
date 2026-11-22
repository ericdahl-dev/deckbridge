// The hook's portable logic (#467), built natively: what the stock firmware's two hook sites hand our code, and what
// our code does with it. The stock side (uptime counter, receive count, malloc, reset witness) is simulated here.
#include <string.h>

#include "harness.h"
#include "view.h"
#include "hook.h"
#include "draw.h"
#include "upper.h"
#include "upper_build.h"

#define CAPABILITY_V1 "F0 00 02 0B 7F 10 20 00 02 00 01 F7"
#define BEGIN_V1 "F0 00 02 0B 7F 10 20 00 02 01 01 F7"
#define DECK_2_RED_TRACK "F0 00 02 0B 7F 10 20 00 09 03 02 01 7F 00 00 00 00 01 F7"
#define END_V1 "F0 00 02 0B 7F 10 20 00 02 02 01 F7"
#define STATE_LOADED_PLAYING "F0 00 02 0B 7F 10 20 00 02 07 03 F7"

/// The simulated stock firmware: its RAM, its malloc, and our state's untouched top-of-SRAM home.
static struct {
    uint32_t uptime;
    uint8_t witness;
    uint16_t rx_count;
    uint8_t rx[0x200];
    int mallocs;
    int malloc_fails;
    int hides;
    dfw_pixel heap[DFW_SIZE * DFW_SIZE];
} chip;
static hook_state state;
static recording rec;
static hook_stock stock;
/// Our marker word as the flash holds it: present after a good placement, 0xFFFFFFFF where nothing was placed.
static uint32_t marker_word;

/// What drawing would see of the hook's unit (#573): the tests read this, never dfw_unit's fields.
static dfw_view view(void) {
    dfw_view v;
    dfw_view_of(&state.unit, &v);
    return v;
}

static void *stock_malloc(size_t size) {
    chip.mallocs++;
    if (chip.malloc_fails || size > sizeof chip.heap) return NULL;
    return chip.heap;
}

static void hide(void) { chip.hides++; }

static void present(void *ctx, const dfw_pixel *frame) { (void)frame; ((recording *)ctx)->presents++; }
static void send(void *ctx, const uint8_t *bytes, size_t length) {
    recording *r = ctx;
    r->sends++;
    r->sent_length = length;
    memcpy(r->sent, bytes, length < sizeof r->sent ? length : sizeof r->sent);
}

/// Power-on: stock RAM is zeroed (.bss) and the witness reads 0; our state keeps whatever was there.
static void power_on(void) {
    chip.uptime = 0;
    chip.witness = 0;
    chip.rx_count = 0;
    chip.mallocs = 0;
    chip.malloc_fails = 0;
    chip.hides = 0;
    memset(&rec, 0, sizeof rec);
    marker_word = HOOK_MARKER;
    stock = (hook_stock){ .marker = &marker_word, .uptime = &chip.uptime, .witness = &chip.witness, .rx_count = &chip.rx_count,
                          .malloc = stock_malloc, .hide = hide, .port = { .present = present, .send = send, .ctx = &rec },
                          .drawing = &dfw_drawn };
}

/// A cold first boot: our state is SRAM garbage too.
static void cold_boot(void) {
    memset(&state, 0xA5, sizeof state);
    power_on();
}

/// Puts one message in the stock receive buffer as the dispatcher sees it, and calls the command entry.
static void deliver(uint8_t cmd_override, const char *hex) {
    size_t n = parse_hex(hex, chip.rx, sizeof chip.rx);
    if (cmd_override) chip.rx[6] = cmd_override;
    chip.rx_count = (uint16_t)n;
    uint32_t len = ((uint32_t)chip.rx[7] << 7) | chip.rx[8];
    hook_command(&state, &stock, chip.rx[6], chip.rx, len);
    chip.uptime += 10;
}

static void tick(void) {
    hook_tick(&state, &stock);
    chip.uptime += 10;
}

static void drawing_session(void) {
    deliver(0, CAPABILITY_V1);
    deliver(0, BEGIN_V1);
    deliver(0, DECK_2_RED_TRACK);
    tick();
}

void the_tick_does_nothing_before_our_first_message(void) {
    cold_boot();
    for (int i = 0; i < 100; i++) tick();
    CHECK(rec.presents == 0 && rec.sends == 0 && chip.mallocs == 0);
}

void a_capability_ask_allocates_the_frame_once_and_is_answered(void) {
    cold_boot();
    deliver(0, CAPABILITY_V1);
    deliver(0, CAPABILITY_V1);
    deliver(0, CAPABILITY_V1);
    tick();
    CHECK(chip.mallocs == 1);
    CHECK(rec.sends == 3);   // answered, so the unit has its frame (no frame, no answer)
}

void a_failed_allocation_means_no_answer_and_no_second_try(void) {
    cold_boot();
    chip.malloc_fails = 1;
    deliver(0, CAPABILITY_V1);
    deliver(0, CAPABILITY_V1);
    tick();
    CHECK(chip.mallocs == 1);
    CHECK(rec.sends == 0);
}

void begin_with_no_frame_allocates_it(void) {
    cold_boot();
    deliver(0, BEGIN_V1);
    deliver(0, DECK_2_RED_TRACK);
    tick();
    CHECK(chip.mallocs == 1);
    CHECK(view().drawn == 1);
    CHECK(rec.presents == 1);
}

void begin_after_a_failed_allocation_stays_in_stock_mode(void) {
    // begin is passed on (agent3, #491): with no frame dfw presents nothing, so the screen is never taken.
    cold_boot();
    chip.malloc_fails = 1;
    deliver(0, BEGIN_V1);
    deliver(0, DECK_2_RED_TRACK);
    deliver(0, BEGIN_V1);
    tick();
    CHECK(chip.mallocs == 1);
    CHECK(rec.presents == 0 && chip.hides == 0);
}

void a_repeated_begin_never_allocates_again(void) {
    cold_boot();
    drawing_session();
    for (int i = 0; i < 5; i++) deliver(0, BEGIN_V1);
    tick();
    CHECK(chip.mallocs == 1);
}

void other_commands_are_left_to_stock(void) {
    cold_boot();
    deliver(0x7F, CAPABILITY_V1);
    deliver(0x21, BEGIN_V1);
    deliver(0x72, BEGIN_V1);
    tick();
    CHECK(chip.mallocs == 0 && rec.sends == 0 && state.magic != HOOK_MAGIC);
}

void a_message_longer_than_the_bytes_received_is_ignored(void) {
    cold_boot();
    size_t n = parse_hex(CAPABILITY_V1, chip.rx, sizeof chip.rx);
    chip.rx_count = (uint16_t)(n - 1);  // the F7 hasn't arrived
    hook_command(&state, &stock, 0x20, chip.rx, 2);
    tick();
    CHECK(chip.mallocs == 0 && rec.sends == 0);
}

void a_message_without_f7_at_its_declared_end_is_ignored(void) {
    cold_boot();
    size_t n = parse_hex(CAPABILITY_V1, chip.rx, sizeof chip.rx);
    chip.rx[n - 1] = 0x00;
    chip.rx[n] = 0xF7;
    chip.rx_count = (uint16_t)(n + 1);
    hook_command(&state, &stock, 0x20, chip.rx, 2);
    tick();
    CHECK(chip.mallocs == 0 && rec.sends == 0);
}

void without_the_marker_nothing_runs(void) {
    cold_boot();
    marker_word = 0xFFFFFFFFu;
    deliver(0, CAPABILITY_V1);
    deliver(0, BEGIN_V1);
    tick();
    CHECK(chip.mallocs == 0 && rec.sends == 0 && rec.presents == 0);
}

void messages_are_copied_out_of_the_stock_buffer(void) {
    // begin, deck and state can share one USB packet; stock reuses its buffer, so nothing may point into it.
    cold_boot();
    deliver(0, BEGIN_V1);
    memset(chip.rx, 0x00, sizeof chip.rx);
    deliver(0, DECK_2_RED_TRACK);
    memset(chip.rx, 0x00, sizeof chip.rx);
    deliver(0, STATE_LOADED_PLAYING);
    memset(chip.rx, 0x00, sizeof chip.rx);
    tick();
    CHECK(view().drawn == 1);
    CHECK(view().deck.number == 2 && view().deck.r == 255 && view().deck.g == 0);
    CHECK(view().flags == 3);
}

void a_reboot_seen_through_the_witness_resets_drawn_mode(void) {
    // The required case: the first call after the reboot comes later than the count saved before it, so the
    // uptime comparison alone can't see the reboot. The witness (cleared by every reset) does.
    cold_boot();
    drawing_session();
    CHECK(view().drawn == 1);
    uint32_t saved = state.last_uptime;
    power_on();
    chip.uptime = saved + 100000;
    for (int i = 0; i < 10; i++) tick();
    CHECK(rec.presents == 0);
    CHECK(state.magic != HOOK_MAGIC);
    deliver(0, DECK_2_RED_TRACK);  // a stray message doesn't bring drawing back: the unit starts fresh, not drawn
    tick();
    CHECK(!view().drawn && rec.presents == 0);   // and no frame: the next begin allocates again
    deliver(0, BEGIN_V1);
    tick();
    CHECK(chip.mallocs == 1);  // the new boot's heap, allocated afresh
}

void without_the_witness_a_late_first_call_keeps_the_old_session(void) {
    // What the uptime comparison alone would do in the required case: it misses the reboot, keeps drawn mode and a
    // frame pointer into the old boot's heap. That's why the hook doesn't rely on it alone.
    cold_boot();
    drawing_session();
    uint32_t saved = state.last_uptime;
    power_on();
    stock.witness = NULL;
    chip.uptime = saved + 100000;
    tick();
    CHECK(state.magic == HOOK_MAGIC && view().drawn == 1);
}

void an_uptime_that_went_backwards_resets_too(void) {
    cold_boot();
    drawing_session();
    chip.witness = 0xF0;  // say the witness survived (it can't, but the counter alone must still catch this)
    chip.uptime = 5;
    tick();
    CHECK(state.magic != HOOK_MAGIC);
}

void a_counter_wrap_keeps_the_session_and_its_frame(void) {
    // The 100 us counter wraps after 4.97 days. A false reset there would drop the frame and allocate again later:
    // a 157 KB leak every wrap. A backwards step from within 10 s of the top is a wrap, not a reboot.
    cold_boot();
    chip.uptime = 0xFFFFFF00u;
    drawing_session();
    chip.uptime = 0x10;
    tick();
    CHECK(state.magic == HOOK_MAGIC && view().drawn == 1);
    deliver(0, BEGIN_V1);
    deliver(0, CAPABILITY_V1);
    tick();
    CHECK(chip.mallocs == 1);
}

void a_backwards_step_from_low_in_the_count_is_a_reboot(void) {
    cold_boot();
    chip.uptime = 0xFFFFFFFFu - 200000u;  // 20 s below the top: outside the 10 s wrap window
    drawing_session();
    chip.witness = HOOK_WITNESS;  // only the counter can tell here
    chip.uptime = 0x10;
    chip.mallocs = 0;
    tick();
    CHECK(state.magic != HOOK_MAGIC);
    deliver(0, BEGIN_V1);
    tick();
    CHECK(chip.mallocs == 1);  // one malloc in the new boot's heap
}

/// Ticks with the 100 us counter `units` further on, in one step.
static void tick_after(uint32_t units) {
    chip.uptime += units;
    hook_tick(&state, &stock);
}

void three_seconds_of_silence_turn_the_screen_stale(void) {
    // dfw's clock is milliseconds; the stock counter is 100 us, so 30,000 counts are 3 s (#464).
    cold_boot();
    drawing_session();
    tick_after(29000);
    CHECK(!dfw_stale(&state.unit));
    tick_after(2000);
    CHECK(dfw_stale(&state.unit));
}

void the_millisecond_clock_runs_on_across_a_counter_wrap(void) {
    // counter / 10 would jump back by 429,496 ms at the wrap and look like a long silence; our clock doesn't.
    cold_boot();
    chip.uptime = 0xFFFFFF00u;
    drawing_session();
    tick_after(20000);  // 2 s on, across the wrap
    CHECK(state.magic == HOOK_MAGIC);
    CHECK(!dfw_stale(&state.unit));
    tick_after(11000);
    CHECK(dfw_stale(&state.unit));
}

void garbage_with_the_magic_but_a_bad_check_word_is_fresh_state(void) {
    cold_boot();
    state.magic = HOOK_MAGIC;
    state.check = 0;
    state.unit.drawn = 1;   // power-on garbage in SRAM, which is what this test is about: not driving the unit
    chip.witness = 0xF0;
    for (int i = 0; i < 5; i++) tick();
    CHECK(rec.presents == 0);
    deliver(0, DECK_2_RED_TRACK);
    tick();
    CHECK(view().drawn == 0);
}

void end_hands_the_screen_back_once(void) {
    cold_boot();
    drawing_session();
    CHECK(rec.presents == 1 && chip.hides == 0);
    deliver(0, END_V1);
    tick();
    tick();
    CHECK(chip.hides == 1);
    deliver(0, BEGIN_V1);
    deliver(0, DECK_2_RED_TRACK);
    tick();
    CHECK(rec.presents == 2 && chip.hides == 1);
}

void nothing_is_hidden_that_was_never_shown(void) {
    cold_boot();
    deliver(0, CAPABILITY_V1);
    deliver(0, END_V1);
    tick();
    CHECK(chip.hides == 0);
}

/// Block B as the upper flash holds it (#501): erased, unless a test writes one. Every header here is upper_build's
/// (#572), the C one pinned to Python's upper_header.py.
static uint8_t upper[0x80000]; /* the upper flash: sectors 8-11 */
/// The layout word the upper_check tests hand in as A's: any value, as long as B's header carries the same (#516).
#define TEST_LAYOUT 0x1A2B3C4Du

static void put_word(uint8_t *at, uint32_t word) {
    for (int i = 0; i < 4; i++) at[i] = (uint8_t)(word >> (8 * i));
}

#define GOOD_LENGTH (UPPER_HEADER + 9)
#define GOOD_DRAW 0x0808001Du
#define GOOD_BAND 0x0808001Fu

/// A 37-byte B: its header, then "123456789"; erased after.
static void good_upper_for(uint32_t layout, uint32_t draw, uint32_t band) {
    memset(upper, 0xFF, sizeof upper);
    memcpy(upper + UPPER_HEADER, "123456789", 9);
    upper_build(upper, GOOD_LENGTH, layout, draw, band);
}

static void good_upper(void) { good_upper_for(TEST_LAYOUT, GOOD_DRAW, GOOD_BAND); }

static uint32_t word_at(const uint8_t *at) {
    return (uint32_t)at[0] | (uint32_t)at[1] << 8 | (uint32_t)at[2] << 16 | (uint32_t)at[3] << 24;
}

void upper_builds_crc_is_zlibs(void) {
    // Worked out apart, with Python's zlib.crc32 of the good B from +16: the CRC this fixture carried by hand.
    good_upper();
    CHECK(word_at(upper + 12) == 0x6ACCA34Bu);
}

/// B's draw entry if the B in `upper` checks out for `layout`, else 0; its band entry likewise.
static uint32_t draw_entry(uint32_t layout) {
    upper_entries entries;
    return upper_check(upper, layout, &entries) ? entries.draw : 0;
}

static uint32_t band_entry(uint32_t layout) {
    upper_entries entries;
    return upper_check(upper, layout, &entries) ? entries.band : 0;
}

void a_good_upper_block_gives_its_draw_and_band_entries(void) {
    good_upper();
    CHECK(draw_entry(TEST_LAYOUT) == GOOD_DRAW);
    CHECK(band_entry(TEST_LAYOUT) == 0x0808001Fu);
}

void erased_upper_flash_has_no_block(void) {
    memset(upper, 0xFF, sizeof upper);
    CHECK(draw_entry(TEST_LAYOUT) == 0);
}

void a_block_for_another_version_is_refused(void) {
    good_upper();
    put_word(upper + 4, UPPER_VERSION + 1);
    CHECK(draw_entry(TEST_LAYOUT) == 0);
}

void a_block_built_for_another_layout_is_refused(void) {
    // B's own CRC is good, so only the layout check can refuse it (#516).
    good_upper_for(TEST_LAYOUT + 1, GOOD_DRAW, GOOD_BAND);
    CHECK(draw_entry(TEST_LAYOUT) == 0);
    CHECK(draw_entry(TEST_LAYOUT + 1) == GOOD_DRAW);
}

void a_block_whose_CRC_doesnt_match_is_refused(void) {
    good_upper();
    upper[32] ^= 1;
    CHECK(draw_entry(TEST_LAYOUT) == 0);
}

void a_length_past_the_sector_or_inside_the_header_is_refused(void) {
    good_upper();
    put_word(upper + 8, UPPER_LIMIT + 4);
    CHECK(draw_entry(TEST_LAYOUT) == 0);
    put_word(upper + 8, UPPER_HEADER - 1);
    CHECK(draw_entry(TEST_LAYOUT) == 0);
    put_word(upper + 8, 0);
    CHECK(draw_entry(TEST_LAYOUT) == 0);
}

void an_entry_that_isnt_Thumb_code_inside_the_block_is_refused(void) {
    // Each B sealed with its good CRC, so only the entry check can refuse it: the draw entry, then the band entry
    // (#524).
    static const struct { uint32_t draw, band; } bad[] = {
        { 0x0808001Cu, GOOD_BAND }, /* no Thumb bit */
        { 0x08080027u, GOOD_BAND }, /* past the end of B */
        { 0x08080019u, GOOD_BAND }, /* inside the header */
        { 0x0000001Du, GOOD_BAND }, /* nowhere near B */
        { GOOD_DRAW, 0x0808001Eu },
        { GOOD_DRAW, 0x08080027u },
        { GOOD_DRAW, 0x08080019u },
        { GOOD_DRAW, 0x0000001Fu },
    };
    for (size_t i = 0; i < sizeof bad / sizeof bad[0]; i++) {
        good_upper_for(TEST_LAYOUT, bad[i].draw, bad[i].band);
        CHECK(draw_entry(TEST_LAYOUT) == 0);
    }
}

/// A good B of 0x20028 bytes, past sector 8 into sector 9: zeros after the good B's bytes.
static void long_upper_for(uint32_t layout) {
    good_upper_for(layout, GOOD_DRAW, GOOD_BAND);
    memset(upper + GOOD_LENGTH, 0, 0x20028 - GOOD_LENGTH);
    upper_build(upper, 0x20028, layout, GOOD_DRAW, GOOD_BAND);
}

static void long_upper(void) { long_upper_for(TEST_LAYOUT); }

void a_block_past_sector_8_is_checked_whole(void) {
    long_upper();
    CHECK(draw_entry(TEST_LAYOUT) == GOOD_DRAW);
    upper[0x20027] = 1;
    CHECK(draw_entry(TEST_LAYOUT) == 0);
}

/// A fixture B as block A sees it: carrying A's own DFW_LAYOUT, which differs between the Mac and the chip.
static void hooked_upper(void) { good_upper_for(DFW_LAYOUT, GOOD_DRAW, GOOD_BAND); }

static void hooked_long_upper(void) { long_upper_for(DFW_LAYOUT); }

/// The hook block draws only with the table stock hands it (#501): with none (the drawing block not yet checked), the
/// capability ask gets no answer and nothing is drawn, so the app falls back to images.
void with_no_drawing_from_stock_the_capability_ask_gets_no_answer(void) {
    cold_boot();
    stock.drawing = NULL;
    deliver(0, CAPABILITY_V1);
    deliver(0, BEGIN_V1);
    deliver(0, DECK_2_RED_TRACK);
    tick();
    CHECK(rec.sends == 0 && rec.presents == 0);
}

void with_an_erased_upper_block_the_capability_ask_gets_no_answer(void) {
    // B's absence alone decides, even with a drawing on offer from stock.
    cold_boot();
    memset(upper, 0xFF, sizeof upper);
    stock.upper = upper;
    deliver(0, CAPABILITY_V1);
    tick();
    CHECK(rec.sends == 0);
}

void with_a_good_upper_block_the_capability_ask_is_answered(void) {
    // Only the capability ask: on the Mac, B's entry is a chip address and is never called.
    cold_boot();
    hooked_upper();
    stock.upper = upper;
    stock.drawing = NULL;
    deliver(0, CAPABILITY_V1);
    tick();
    CHECK(rec.sends == 1);
}

void an_upper_block_with_a_bad_CRC_or_another_version_gets_no_answer(void) {
    for (int bad = 0; bad < 2; bad++) {
        cold_boot();
        hooked_upper();
        if (bad == 0) upper[32] ^= 1;
        else put_word(upper + 4, UPPER_VERSION + 1);
        stock.upper = upper;
        stock.drawing = NULL;
        deliver(0, CAPABILITY_V1);
        tick();
        CHECK(rec.sends == 0);
    }
}

void an_upper_block_built_for_another_layout_gets_no_answer(void) {
    // A B from a commit whose dfw_unit differs would draw from the wrong offsets (#516): A stays silent, and takes no
    // malloc, as with no B at all.
    cold_boot();
    good_upper_for(DFW_LAYOUT ^ 1u, GOOD_DRAW, GOOD_BAND);
    stock.upper = upper;
    stock.drawing = NULL;
    deliver(0, CAPABILITY_V1);
    deliver(0, BEGIN_V1);
    tick();
    CHECK(rec.sends == 0 && rec.presents == 0);
    CHECK(chip.mallocs == 0);
}

void a_long_upper_block_is_checked_whole_at_the_first_ask(void) {
    // The app waits 0.5 s for the answer and doesn't ask again until it reconnects: the ask checks all of B first
    // (45 ms for 512 KB at most), never answering for an unchecked B and never staying silent for a good one.
    for (int corrupt = 0; corrupt < 2; corrupt++) {
        cold_boot();
        hooked_long_upper();
        if (corrupt) upper[0x20027] = 1;  // B's last byte: only a whole check sees it
        stock.upper = upper;
        stock.drawing = NULL;
        deliver(0, CAPABILITY_V1);
        tick();
        CHECK(rec.sends == (corrupt ? 0 : 1));
    }
}

void before_our_first_message_the_tick_touches_nothing_even_with_an_upper_block(void) {
    // Our code runs only after our first message, so a power cycle clears any crash of ours (#501): B is
    // checked at the first ask, never at boot.
    cold_boot();
    hooked_long_upper();
    stock.upper = upper;
    stock.drawing = NULL;
    for (int i = 0; i < 100; i++) tick();
    const uint8_t *bytes = (const uint8_t *)&state;
    size_t touched = 0;
    for (size_t i = 0; i < sizeof state; i++) touched += bytes[i] != 0xA5;
    CHECK(touched == 0);
    CHECK(chip.witness == 0);
}

void without_a_drawing_the_ask_takes_no_malloc(void) {
    // A without B behaves exactly like stock (#501): no answer, and none of stock's heap.
    for (int with_upper = 0; with_upper < 2; with_upper++) {
        cold_boot();
        memset(upper, 0xFF, sizeof upper);
        stock.upper = with_upper ? upper : NULL;
        stock.drawing = NULL;
        deliver(0, CAPABILITY_V1);
        deliver(0, BEGIN_V1);
        tick();
        CHECK(chip.mallocs == 0);
        CHECK(rec.sends == 0);
    }
}

const test_case all_tests[] = {
    { "with no drawing from stock the capability ask gets no answer",
      with_no_drawing_from_stock_the_capability_ask_gets_no_answer },
    { "end hands the screen back once", end_hands_the_screen_back_once },
    { "nothing is hidden that was never shown", nothing_is_hidden_that_was_never_shown },
    { "the tick does nothing before our first message", the_tick_does_nothing_before_our_first_message },
    { "a capability ask allocates the frame once and is answered", a_capability_ask_allocates_the_frame_once_and_is_answered },
    { "a failed allocation means no answer and no second try", a_failed_allocation_means_no_answer_and_no_second_try },
    { "begin with no frame allocates it", begin_with_no_frame_allocates_it },
    { "begin after a failed allocation stays in stock mode", begin_after_a_failed_allocation_stays_in_stock_mode },
    { "a repeated begin never allocates again", a_repeated_begin_never_allocates_again },
    { "other commands are left to stock", other_commands_are_left_to_stock },
    { "a message longer than the bytes received is ignored", a_message_longer_than_the_bytes_received_is_ignored },
    { "a message without F7 at its declared end is ignored", a_message_without_f7_at_its_declared_end_is_ignored },
    { "without the marker nothing runs", without_the_marker_nothing_runs },
    { "messages are copied out of the stock buffer", messages_are_copied_out_of_the_stock_buffer },
    { "a reboot seen through the witness resets drawn mode", a_reboot_seen_through_the_witness_resets_drawn_mode },
    { "without the witness a late first call keeps the old session", without_the_witness_a_late_first_call_keeps_the_old_session },
    { "an uptime that went backwards resets too", an_uptime_that_went_backwards_resets_too },
    { "a counter wrap keeps the session and its frame", a_counter_wrap_keeps_the_session_and_its_frame },
    { "a backwards step from low in the count is a reboot", a_backwards_step_from_low_in_the_count_is_a_reboot },
    { "garbage with the magic but a bad check word is fresh state", garbage_with_the_magic_but_a_bad_check_word_is_fresh_state },
    { "three seconds of silence turn the screen stale", three_seconds_of_silence_turn_the_screen_stale },
    { "the millisecond clock runs on across a counter wrap", the_millisecond_clock_runs_on_across_a_counter_wrap },
    { "a good upper block gives its draw and band entries", a_good_upper_block_gives_its_draw_and_band_entries },
    { "erased upper flash has no block", erased_upper_flash_has_no_block },
    { "a block for another version is refused", a_block_for_another_version_is_refused },
    { "a block built for another layout is refused", a_block_built_for_another_layout_is_refused },
    { "upper_build's CRC is zlib's", upper_builds_crc_is_zlibs },
    { "a block whose CRC doesn't match is refused", a_block_whose_CRC_doesnt_match_is_refused },
    { "a length past the sector or inside the header is refused", a_length_past_the_sector_or_inside_the_header_is_refused },
    { "an entry that isn't Thumb code inside the block is refused", an_entry_that_isnt_Thumb_code_inside_the_block_is_refused },
    { "a block past sector 8 is checked whole", a_block_past_sector_8_is_checked_whole },
    { "with an erased upper block the capability ask gets no answer", with_an_erased_upper_block_the_capability_ask_gets_no_answer },
    { "with a good upper block the capability ask is answered", with_a_good_upper_block_the_capability_ask_is_answered },
    { "an upper block with a bad CRC or another version gets no answer", an_upper_block_with_a_bad_CRC_or_another_version_gets_no_answer },
    { "an upper block built for another layout gets no answer", an_upper_block_built_for_another_layout_gets_no_answer },
    { "a long upper block is checked whole at the first ask", a_long_upper_block_is_checked_whole_at_the_first_ask },
    { "before our first message the tick touches nothing even with an upper block", before_our_first_message_the_tick_touches_nothing_even_with_an_upper_block },
    { "without a drawing the ask takes no malloc", without_a_drawing_the_ask_takes_no_malloc },
    { 0, 0 },
};

/// The shared harness also walks agent3's drawing table; the hook's tests have none of their own.
const test_case draw_tests[] = { { 0, 0 } };
const test_case draw_live_tests[] = { { 0, 0 } };
const test_case text_tests[] = { { 0, 0 } };
const test_case layout_tests[] = { { 0, 0 } };
const test_case draw_band_tests[] = { { 0, 0 } };
const test_case ring_table_tests[] = { { 0, 0 } };
const test_case geometry_tests[] = { { 0, 0 } };
const test_case panel_tests[] = { { 0, 0 } };
const test_case present_tests[] = { { 0, 0 } };
const test_case panel_record_tests[] = { { 0, 0 } };
