// The display feed over the USB cable (#667): the cable's bytes, SLIP framed, come out of serial_feed as whole OSC
// packets, through the same feed_drain::Socket the UDP feed uses.
#include <unity.h>

#include <deque>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

#include "../test_deck_core/json_mini.h"
#include "serial_feed.h"

void setUp() {}
void tearDown() {}

/// Bytes waiting on a fake cable.
struct FakeCable : serial_feed::Bytes {
    std::deque<uint8_t> waiting;
    void add(const std::vector<uint8_t>& bytes) { waiting.insert(waiting.end(), bytes.begin(), bytes.end()); }
    int next() override {
        if (waiting.empty()) return -1;
        const int byte = waiting.front();
        waiting.pop_front();
        return byte;
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

int main() {
    UNITY_BEGIN();
    RUN_TEST(test_each_shared_example_frame_comes_out_as_its_packet);
    RUN_TEST(test_an_overlong_frame_is_dropped_whole_and_the_next_comes_through);
    RUN_TEST(test_text_between_frames_goes_to_the_text_reader);
    RUN_TEST(test_after_a_lost_end_the_feed_is_back_in_step_by_the_next_frame);
    return UNITY_END();
}
