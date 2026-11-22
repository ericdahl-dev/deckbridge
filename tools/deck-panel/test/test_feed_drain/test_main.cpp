// The panel's receive path (#620): on the loop task, each frame reads waiting datagrams into the core, at most a few,
// so a burst can't hold the screen up. A datagram too big for the buffer is dropped, never cut and parsed.
#include <unity.h>

#include <deque>
#include <vector>

#include <cstdlib>

#include "deck_core.h"
#include "feed_drain.h"

void setUp() {}
void tearDown() {}

/// Datagrams waiting on a fake socket.
struct FakeSocket : feed_drain::Socket {
    std::deque<std::vector<uint8_t>> waiting;
    size_t next_size() override { return waiting.empty() ? 0 : waiting.front().size(); }
    size_t read(uint8_t* into, size_t room) override {
        std::vector<uint8_t> d = waiting.front();
        waiting.pop_front();
        size_t n = d.size() < room ? d.size() : room;
        for (size_t i = 0; i < n; ++i) into[i] = d[i];
        return n;
    }
    void skip() override { waiting.pop_front(); }
};

/// A deck message: /DeckBridge/Display/deck ,i n.
static std::vector<uint8_t> deck_message(uint8_t deck) {
    const char address[] = "/DeckBridge/Display/deck";  // 24 bytes, padded to 28
    std::vector<uint8_t> out(address, address + sizeof address - 1);
    while (out.size() < 28) out.push_back(0);
    const uint8_t tags[] = {',', 'i', 0, 0};
    out.insert(out.end(), tags, tags + 4);
    const uint8_t value[] = {0, 0, 0, deck};
    out.insert(out.end(), value, value + 4);
    return out;
}

struct Last : deck_core::Screen {
    int deck = -1;
    bool waiting = false;
    void show_waiting(const deck_core::WaitingView&, const deck_core::WaitingChanges&) override { waiting = true; }
    void show_deck(const deck_core::Face& f, const deck_core::Changes&) override {
        waiting = false;
        deck = std::atoi(f.deck);
    }
};

void test_waiting_datagrams_go_to_the_core_in_order() {
    FakeSocket socket;
    socket.waiting = {deck_message(1), deck_message(3)};
    deck_core::DeckCore core;
    feed_drain::Drain drain;
    TEST_ASSERT_EQUAL(2, drain.run(socket, core, 100));
    Last screen;
    core.render(screen, 100);
    TEST_ASSERT_EQUAL(3, screen.deck);
}

// lwIP holds only 6 datagrams for the socket (#636): a frame reads until it's empty, so a burst isn't clipped there.
static uint32_t g_clock_ms = 0;
static uint32_t still_clock() { return g_clock_ms; }
static uint32_t ticking_clock() { return g_clock_ms++; }  // 1 ms a read

void test_a_frame_reads_until_the_socket_is_empty() {
    FakeSocket socket;
    for (int i = 0; i < 40; ++i) socket.waiting.push_back(deck_message(2));
    deck_core::DeckCore core;
    feed_drain::Drain drain;
    g_clock_ms = 0;
    TEST_ASSERT_EQUAL(40, drain.run(socket, core, 100, still_clock));
    TEST_ASSERT_TRUE(socket.waiting.empty());
}

// But never past its time budget, so a flood can't hold the screen up; the rest wait for the next frame.
void test_a_frame_stops_at_its_time_budget() {
    FakeSocket socket;
    for (int i = 0; i < 40; ++i) socket.waiting.push_back(deck_message(2));
    deck_core::DeckCore core;
    feed_drain::Drain drain;
    g_clock_ms = 0;
    const int read = drain.run(socket, core, 100, ticking_clock);
    TEST_ASSERT_TRUE(read >= 1);
    TEST_ASSERT_TRUE(read <= static_cast<int>(feed_drain::kBudgetMs) + 1);
    TEST_ASSERT_EQUAL(40 - read, socket.waiting.size());
}

void test_a_datagram_too_big_is_dropped_and_counted() {
    FakeSocket socket;
    std::vector<uint8_t> big = deck_message(4);
    big.resize(feed_drain::kMaxDatagram + 4, 0);
    socket.waiting = {big, deck_message(1)};
    deck_core::DeckCore core;
    feed_drain::Drain drain;
    drain.run(socket, core, 100);
    TEST_ASSERT_EQUAL(1, drain.too_big());
    TEST_ASSERT_TRUE(socket.waiting.empty());
    Last screen;
    core.render(screen, 100);
    TEST_ASSERT_EQUAL(1, screen.deck);
}

/// A bundle of `count` deck messages, padded out with an unknown address's string to `size` bytes.
static std::vector<uint8_t> bundle_of_size(size_t size) {
    std::vector<uint8_t> out = {'#', 'b', 'u', 'n', 'd', 'l', 'e', 0, 0, 0, 0, 0, 0, 0, 0, 1};
    std::vector<uint8_t> deck = deck_message(2);
    const uint8_t deck_size[] = {0, 0, 0, static_cast<uint8_t>(deck.size())};
    out.insert(out.end(), deck_size, deck_size + 4);
    out.insert(out.end(), deck.begin(), deck.end());
    // Filler: one more element, /DeckBridge/Display/pad ,s with a long string, to reach `size`.
    const size_t element = size - out.size() - 4;
    std::vector<uint8_t> pad;
    const char address[] = "/DeckBridge/Display/pad";  // 23 + NUL = 24
    pad.insert(pad.end(), address, address + sizeof address);
    const uint8_t tags[] = {',', 's', 0, 0};
    pad.insert(pad.end(), tags, tags + 4);
    pad.resize(element, 'x');
    pad.back() = 0;
    pad[pad.size() - 2] = 0;
    const uint8_t pad_size[] = {0, 0, static_cast<uint8_t>(element >> 8), static_cast<uint8_t>(element & 0xFF)};
    out.insert(out.end(), pad_size, pad_size + 4);
    out.insert(out.end(), pad.begin(), pad.end());
    return out;
}

// The feed's full snapshot is one bundle of about 700 B, up to 1200 B before it splits (#636).
void test_a_1200_byte_bundle_gets_through_and_one_over_the_limit_does_not() {
    TEST_ASSERT_TRUE(feed_drain::kMaxDatagram >= 1200);
    FakeSocket socket;
    socket.waiting = {bundle_of_size(1200)};
    deck_core::DeckCore core;
    feed_drain::Drain drain;
    drain.run(socket, core, 100);
    Last screen;
    core.render(screen, 100);
    TEST_ASSERT_EQUAL(0, drain.too_big());
    TEST_ASSERT_EQUAL(2, screen.deck);
    socket.waiting = {bundle_of_size(feed_drain::kMaxDatagram + 4)};
    drain.run(socket, core, 200);
    TEST_ASSERT_EQUAL(1, drain.too_big());
}

// For the perf env's line (#636): every datagram seen, those fed to the core, and those too big, since boot.
void test_the_drain_counts_received_processed_and_too_big() {
    FakeSocket socket;
    std::vector<uint8_t> big = deck_message(4);
    big.resize(feed_drain::kMaxDatagram + 4, 0);
    socket.waiting = {deck_message(1), big, deck_message(2)};
    deck_core::DeckCore core;
    feed_drain::Drain drain;
    drain.run(socket, core, 100);
    socket.waiting = {deck_message(3)};
    drain.run(socket, core, 110);
    TEST_ASSERT_EQUAL(4, drain.received());
    TEST_ASSERT_EQUAL(3, drain.processed());
    TEST_ASSERT_EQUAL(1, drain.too_big());
}

int main(int, char**) {
    UNITY_BEGIN();
    RUN_TEST(test_waiting_datagrams_go_to_the_core_in_order);
    RUN_TEST(test_a_frame_reads_until_the_socket_is_empty);
    RUN_TEST(test_a_frame_stops_at_its_time_budget);
    RUN_TEST(test_a_datagram_too_big_is_dropped_and_counted);
    RUN_TEST(test_a_1200_byte_bundle_gets_through_and_one_over_the_limit_does_not);
    RUN_TEST(test_the_drain_counts_received_processed_and_too_big);
    return UNITY_END();
}
