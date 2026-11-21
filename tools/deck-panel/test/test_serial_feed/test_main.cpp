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

int main() {
    UNITY_BEGIN();
    RUN_TEST(test_each_shared_example_frame_comes_out_as_its_packet);
    return UNITY_END();
}
