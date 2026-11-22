// The display feed over the USB cable (#667): the cable's bytes, SLIP framed, come out of serial_feed as whole OSC
// packets, through the same feed_drain::Socket the UDP feed uses.
#include <unity.h>

#include <cstdlib>
#include <deque>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

#include "../test_deck_core/json_mini.h"
#include "deck_core.h"
#include "serial_feed.h"

void setUp() {}
void tearDown() {}

/// Bytes waiting on a fake cable.
struct FakeCable : serial_feed::Bytes {
    std::deque<uint8_t> waiting;
    void add(const std::vector<uint8_t>& bytes) { waiting.insert(waiting.end(), bytes.begin(), bytes.end()); }
    size_t read(uint8_t* into, size_t room) override {
        size_t n = 0;
        for (; n < room && !waiting.empty(); ++n) {
            into[n] = waiting.front();
            waiting.pop_front();
        }
        return n;
    }
};

static std::vector<uint8_t> hex(const std::string& text) {
    std::vector<uint8_t> out;
    for (size_t i = 0; i + 1 < text.size(); i += 2) out.push_back(uint8_t(std::stoul(text.substr(i, 2), nullptr, 16)));
    return out;
}

/// Reads the next packet; empty if none is whole yet.
static std::vector<uint8_t> next_packet(serial_feed::SerialFeed& feed) {
    const size_t size = feed.next_size();
    std::vector<uint8_t> out(size);
    if (size) out.resize(feed.read(out.data(), out.size()));
    return out;
}

// The shared examples, feed/slip.json: written by hand, walked by the Kit's SLIP test too.
void test_each_shared_example_frame_comes_out_as_its_packet() {
    const std::string here = __FILE__;
    std::ifstream in(here.substr(0, here.rfind('/')) + "/../../feed/slip.json");
    std::stringstream text;
    text << in.rdbuf();
    const json_mini::Value file = json_mini::parse(text.str());
    TEST_ASSERT_TRUE(file["cases"].array.size() >= 6);
    for (const json_mini::Value& example : file["cases"].array) {
        FakeCable cable;
        serial_feed::SerialFeed feed(cable);
        cable.add(hex(example["framed_hex"].string));
        const std::vector<uint8_t> expected = hex(example["packet_hex"].string);
        const std::vector<uint8_t> got = next_packet(feed);
        TEST_ASSERT_EQUAL_MESSAGE(expected.size(), got.size(), example["name"].string.c_str());
        TEST_ASSERT_EQUAL_UINT8_ARRAY_MESSAGE(expected.data(), got.data(), expected.size(), example["name"].string.c_str());
        TEST_ASSERT_EQUAL_MESSAGE(0, feed.next_size(), example["name"].string.c_str());
    }
}

// A frame bigger than a datagram the drain reads is dropped whole and counted as too big, never cut and parsed; the
// next frame still comes through.
void test_an_overlong_frame_is_dropped_whole_and_the_next_comes_through() {
    FakeCable cable;
    serial_feed::SerialFeed feed(cable);
    std::vector<uint8_t> big(feed_drain::kMaxDatagram + 1, 0x2f);
    big.insert(big.begin(), 0xC0);
    big.push_back(0xC0);
    cable.add(big);
    cable.add({0xC0, 0x2f, 0x61, 0xC0});
    TEST_ASSERT_TRUE(feed.next_size() > feed_drain::kMaxDatagram);
    feed.skip();
    const std::vector<uint8_t> got = next_packet(feed);
    TEST_ASSERT_EQUAL(2, got.size());
    TEST_ASSERT_EQUAL_HEX8(0x2f, got[0]);
    TEST_ASSERT_EQUAL_HEX8(0x61, got[1]);
}

/// What the feed passed on as text.
struct Lines : serial_feed::Text {
    std::string got;
    void put(char c) override { got += c; }
};

// Text on the cable outside a frame (a "version" question, #695) goes to the text reader in order; a frame's bytes don't.
void test_text_between_frames_goes_to_the_text_reader() {
    FakeCable cable;
    Lines lines;
    serial_feed::SerialFeed feed(cable, &lines);
    cable.add({'v', 'e', 'r'});
    cable.add({0xC0, 's', 0x0a, 0xC0});
    cable.add({'s', 'i', 'o', 'n', 0x0a});
    const std::vector<uint8_t> got = next_packet(feed);
    TEST_ASSERT_EQUAL(2, got.size());
    TEST_ASSERT_EQUAL(0, feed.next_size());
    TEST_ASSERT_EQUAL_STRING("version\n", lines.got.c_str());
}

// A lost END costs at most the frame it belonged to and the one after: the feed is back in step by the next frame.
void test_after_a_lost_end_the_feed_is_back_in_step_by_the_next_frame() {
    FakeCable cable;
    serial_feed::SerialFeed feed(cable);
    cable.add({0x01, 0x02, 0xC0});                // the frame's opening END lost
    cable.add({0xC0, 0x03, 0xC0});
    std::vector<uint8_t> got = next_packet(feed);
    TEST_ASSERT_EQUAL(1, got.size());
    TEST_ASSERT_EQUAL_HEX8(0x03, got[0]);
    cable.add({0xC0, 0x04});                      // the frame's closing END lost
    cable.add({0xC0, 0x05, 0xC0});
    cable.add({0xC0, 0x06, 0xC0});
    std::vector<std::vector<uint8_t>> rest;
    for (got = next_packet(feed); !got.empty(); got = next_packet(feed)) rest.push_back(got);
    TEST_ASSERT_TRUE(rest.size() >= 1);
    TEST_ASSERT_EQUAL(1, rest.back().size());
    TEST_ASSERT_EQUAL_HEX8(0x06, rest.back()[0]);
}

struct Last : deck_core::Screen {
    int deck = -1;
    void show_waiting(const deck_core::WaitingView&, const deck_core::WaitingChanges&) override {}
    void show_deck(const deck_core::Face& f, const deck_core::Changes&) override { deck = std::atoi(f.deck); }
};

// Through the drain into the core, as on the board: a frame that arrives in two parts shows its deck once it is whole,
// and the drain doesn't wait for the rest in between.
void test_a_frame_arriving_in_two_parts_shows_its_deck_once_whole() {
    // /DeckBridge/Display/deck ,i 3: the 24-byte address padded to 28, the tags, the value.
    std::vector<uint8_t> message = {'/', 'D', 'e', 'c', 'k', 'B', 'r', 'i', 'd', 'g', 'e', '/', 'D', 'i', 's', 'p',
                                    'l', 'a', 'y', '/', 'd', 'e', 'c', 'k', 0, 0, 0, 0, ',', 'i', 0, 0, 0, 0, 0, 3};
    FakeCable cable;
    serial_feed::SerialFeed feed(cable);
    deck_core::DeckCore core;
    core.set_network(deck_core::Network::connected, "10.0.0.2");
    feed_drain::Drain drain;
    cable.add({0xC0});
    cable.add(std::vector<uint8_t>(message.begin(), message.begin() + 20));
    TEST_ASSERT_EQUAL(0, drain.run(feed, core, 100));
    cable.add(std::vector<uint8_t>(message.begin() + 20, message.end()));
    cable.add({0xC0});
    TEST_ASSERT_EQUAL(1, drain.run(feed, core, 133));
    Last screen;
    core.render(screen, 133);
    TEST_ASSERT_EQUAL(3, screen.deck);
}

// The cable's drain tells the core its datagrams came on the cable, so the deck shows with Wi-Fi still in setup (#667).
void test_the_cables_drain_shows_the_deck_in_setup_mode() {
    std::vector<uint8_t> message = {'/', 'D', 'e', 'c', 'k', 'B', 'r', 'i', 'd', 'g', 'e', '/', 'D', 'i', 's', 'p',
                                    'l', 'a', 'y', '/', 'd', 'e', 'c', 'k', 0, 0, 0, 0, ',', 'i', 0, 0, 0, 0, 0, 2};
    FakeCable cable;
    serial_feed::SerialFeed feed(cable);
    deck_core::DeckCore core;
    core.set_network(deck_core::Network::setup, "192.168.4.1");
    feed_drain::Drain drain(deck_core::Source::cable);
    cable.add({0xC0});
    cable.add(message);
    cable.add({0xC0});
    TEST_ASSERT_EQUAL(1, drain.run(feed, core, 100));
    Last screen;
    core.render(screen, 100);
    TEST_ASSERT_EQUAL(2, screen.deck);
}

static uint32_t g_now_ms = 0;
static uint32_t fake_clock() { return g_now_ms; }

// A frame cut short with no END after it is dropped once the cable has been quiet kQuietMs, so a "version" question
// typed later goes to the text reader, not into the dead frame.
void test_a_cut_frame_is_dropped_after_quiet_and_text_reads_again() {
    FakeCable cable;
    Lines lines;
    g_now_ms = 1000;
    serial_feed::SerialFeed feed(cable, &lines, fake_clock);
    cable.add({0xC0, 0x2f, 0x44, 0x65});
    TEST_ASSERT_EQUAL(0, feed.next_size());
    g_now_ms += serial_feed::SerialFeed::kQuietMs;
    TEST_ASSERT_EQUAL(0, feed.next_size());  // the loop asks each frame: the cable is empty and quiet
    cable.add({'v', 'e', 'r', 's', 'i', 'o', 'n', 0x0a});
    TEST_ASSERT_EQUAL(0, feed.next_size());
    TEST_ASSERT_EQUAL_STRING("version\n", lines.got.c_str());
}

// Only a frame's opening END came (the rest lost): after the quiet, text reads again; it doesn't wait inside forever.
void test_an_opening_end_alone_is_dropped_after_quiet() {
    FakeCable cable;
    Lines lines;
    g_now_ms = 5000;
    serial_feed::SerialFeed feed(cable, &lines, fake_clock);
    cable.add({0xC0});
    TEST_ASSERT_EQUAL(0, feed.next_size());
    g_now_ms += serial_feed::SerialFeed::kQuietMs;
    TEST_ASSERT_EQUAL(0, feed.next_size());
    cable.add({'v', 'e', 'r', 's', 'i', 'o', 'n', 0x0a});
    TEST_ASSERT_EQUAL(0, feed.next_size());
    TEST_ASSERT_EQUAL_STRING("version\n", lines.got.c_str());
}

// A loop that stalls with half a frame read and the rest already waiting keeps the frame: quiet is only an empty cable.
void test_a_stall_with_the_rest_waiting_keeps_the_frame() {
    FakeCable cable;
    g_now_ms = 9000;
    serial_feed::SerialFeed feed(cable, nullptr, fake_clock);
    cable.add({0xC0, 0x2f});
    TEST_ASSERT_EQUAL(0, feed.next_size());
    cable.add({0x61, 0xC0});
    g_now_ms += serial_feed::SerialFeed::kQuietMs + 50;
    const std::vector<uint8_t> got = next_packet(feed);
    TEST_ASSERT_EQUAL(2, got.size());
}

int main() {
    UNITY_BEGIN();
    RUN_TEST(test_each_shared_example_frame_comes_out_as_its_packet);
    RUN_TEST(test_an_overlong_frame_is_dropped_whole_and_the_next_comes_through);
    RUN_TEST(test_text_between_frames_goes_to_the_text_reader);
    RUN_TEST(test_after_a_lost_end_the_feed_is_back_in_step_by_the_next_frame);
    RUN_TEST(test_a_frame_arriving_in_two_parts_shows_its_deck_once_whole);
    RUN_TEST(test_the_cables_drain_shows_the_deck_in_setup_mode);
    RUN_TEST(test_a_cut_frame_is_dropped_after_quiet_and_text_reads_again);
    RUN_TEST(test_an_opening_end_alone_is_dropped_after_quiet);
    RUN_TEST(test_a_stall_with_the_rest_waiting_keeps_the_frame);
    return UNITY_END();
}
