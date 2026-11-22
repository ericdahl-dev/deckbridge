// The companion chip's backlight and touch bytes (#615), by board revision. Getting them wrong leaves a black screen
// with no error, so they're pinned here. Values from Elecrow's driver, as phrasedeck's panel_mcu has them.
#include <unity.h>

#include <initializer_list>
#include <vector>

#include "backlight.h"

void setUp() {}
void tearDown() {}

static void assert_bytes(const backlight::Bytes& got, std::initializer_list<uint8_t> want) {
    TEST_ASSERT_EQUAL(want.size(), got.count);
    size_t i = 0;
    for (uint8_t b : want) TEST_ASSERT_EQUAL_HEX8(b, got.bytes[i++]);
}

// V1.3 and later (the owner's V1.4 is 140): 0 is brightest, 244 dimmest, 245 off.
void test_v1_4_full_is_0_off_is_245_and_the_scale_runs_backwards() {
    assert_bytes(backlight::level(140, 100), {0});
    assert_bytes(backlight::level(140, 0), {245});
    assert_bytes(backlight::level(140, 50), {122});
    assert_bytes(backlight::level(140, 1), {242});
}

void test_over_100_percent_is_full() { assert_bytes(backlight::level(140, 200), {0}); }

void test_v1_4_touch_activation_is_250() { TEST_ASSERT_EQUAL_HEX8(250, backlight::touch_activate(140)); }

// V1.2: 0x10 on, 0x05 off, and dimming needs 0x10 sent first.
void test_v1_2_sends_on_then_its_level_and_0x05_for_off() {
    assert_bytes(backlight::level(120, 100), {0x10, 0x10});
    assert_bytes(backlight::level(120, 0), {0x05});
    TEST_ASSERT_EQUAL_HEX8(0x19, backlight::touch_activate(120));
}

// The chip can NAK while it's busy (at power-on it comes up after the ESP32): a lost "on" byte is a dark screen with no
// error, so each byte is retried, and a byte that never gets an ACK is reported.
void test_a_byte_that_is_not_acked_is_sent_again_until_it_is() {
    std::vector<uint8_t> sent;
    int naks = 2;
    const bool ok = backlight::send(backlight::level(140, 100), [&](uint8_t b) {
        sent.push_back(b);
        return naks-- <= 0;
    });
    TEST_ASSERT_TRUE(ok);
    TEST_ASSERT_EQUAL(3, sent.size());
}

void test_a_byte_never_acked_gives_up_after_three_tries_and_reports_it() {
    std::vector<uint8_t> sent;
    const bool ok = backlight::send(backlight::level(120, 100), [&](uint8_t b) {
        sent.push_back(b);
        return false;
    });
    TEST_ASSERT_FALSE(ok);
    TEST_ASSERT_EQUAL(3, sent.size());  // V1.2's second byte isn't sent after its first failed
}

void test_both_of_v1_2s_bytes_go_out_in_order() {
    std::vector<uint8_t> sent;
    TEST_ASSERT_TRUE(backlight::send(backlight::level(120, 100), [&](uint8_t b) {
        sent.push_back(b);
        return true;
    }));
    TEST_ASSERT_EQUAL(2, sent.size());
    TEST_ASSERT_EQUAL_HEX8(0x10, sent[0]);
    TEST_ASSERT_EQUAL_HEX8(0x10, sent[1]);
}

int main() {
    UNITY_BEGIN();
    RUN_TEST(test_v1_4_full_is_0_off_is_245_and_the_scale_runs_backwards);
    RUN_TEST(test_over_100_percent_is_full);
    RUN_TEST(test_v1_4_touch_activation_is_250);
    RUN_TEST(test_v1_2_sends_on_then_its_level_and_0x05_for_off);
    RUN_TEST(test_a_byte_that_is_not_acked_is_sent_again_until_it_is);
    RUN_TEST(test_a_byte_never_acked_gives_up_after_three_tries_and_reports_it);
    RUN_TEST(test_both_of_v1_2s_bytes_go_out_in_order);
    return UNITY_END();
}
