// The feed's intake (#664): each datagram is stamped when it arrives, off the loop, and queued in fixed memory; the
// frame takes what came since the last one and feeds the core each datagram at its own arrival time.
#include <unity.h>

#include <cstdlib>
#include <new>
#include <atomic>
#include <cstring>
#include <deque>
#include <thread>
#include <vector>

#include "deck_core.h"
#include "feed_drain.h"
#include "feed_intake.h"

// Every heap allocation in this test binary is counted, so a test can say the intake makes none per datagram.
static size_t allocations = 0;
void* operator new(size_t size) {
    ++allocations;
    if (void* p = std::malloc(size ? size : 1)) return p;
    throw std::bad_alloc();
}
void operator delete(void* p) noexcept { std::free(p); }
void operator delete(void* p, size_t) noexcept { std::free(p); }

void setUp() {}
void tearDown() {}

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

/// Datagrams waiting on a fake socket, the board's seam (feed_drain::Socket).
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

static uint64_t g_us = 0;
static uint64_t ticking_us() { return g_us += 250; }  // 250 us a look

struct Last : deck_core::Screen {
    int deck = -1;
    bool waiting = false;
    void show_waiting(const deck_core::WaitingView&, const deck_core::WaitingChanges&) override { waiting = true; }
    void show_deck(const deck_core::Face& f, const deck_core::Changes&) override {
        waiting = false;
        deck = std::atoi(f.deck);
    }
};

static void connect(deck_core::DeckCore& core) { core.set_network(deck_core::Network::connected, "192.168.1.40"); }

// A datagram that arrived at 1.000 s and was read 30 ms later is the core's at 1.000 s: 3 s after its arrival, not
// after the read, the panel goes to waiting.
void test_the_core_gets_each_datagram_at_its_arrival_not_its_read() {
    feed_intake::Intake intake;
    const auto m = deck_message(2);
    TEST_ASSERT_TRUE(intake.push(m.data(), m.size(), 1000000));
    deck_core::DeckCore core;
    connect(core);
    TEST_ASSERT_EQUAL(1, intake.drain(core).count);
    Last screen;
    core.render(screen, 3999);
    TEST_ASSERT_FALSE(screen.waiting);
    TEST_ASSERT_EQUAL(2, screen.deck);
    core.render(screen, 4000);
    TEST_ASSERT_TRUE(screen.waiting);
}

// What came between two frames goes in order, each at its own time; the frame learns the newest arrival, for the
// ledger's lag (#662).
void test_a_frame_takes_everything_since_the_last_in_order_and_knows_the_newest() {
    feed_intake::Intake intake;
    const auto one = deck_message(1), three = deck_message(3);
    intake.push(one.data(), one.size(), 1000000);
    intake.push(three.data(), three.size(), 1010500);
    deck_core::DeckCore core;
    connect(core);
    const feed_intake::Drained got = intake.drain(core);
    TEST_ASSERT_EQUAL(2, got.count);
    TEST_ASSERT_EQUAL_UINT64(1010500, got.newest_us);
    TEST_ASSERT_EQUAL_UINT64(1000000, got.oldest_us);  // for the ledger's skip
    Last screen;
    core.render(screen, 4009);
    TEST_ASSERT_EQUAL(3, screen.deck);
    core.render(screen, 4010);
    TEST_ASSERT_TRUE(screen.waiting);
    // Nothing since: the next frame takes nothing.
    TEST_ASSERT_EQUAL(0, intake.drain(core).count);
}

// Full, the newcomer is dropped and counted; what's queued stays. The feed's 2 s snapshot heals a drop (ADR 0011).
void test_a_full_queue_drops_the_newcomer_and_counts_it() {
    feed_intake::Intake intake;
    const auto two = deck_message(2), four = deck_message(4), one = deck_message(1);
    for (size_t i = 0; i + 1 < feed_intake::kSlots; ++i) TEST_ASSERT_TRUE(intake.push(two.data(), two.size(), 1000));
    TEST_ASSERT_TRUE(intake.push(four.data(), four.size(), 2000));
    TEST_ASSERT_FALSE(intake.push(one.data(), one.size(), 3000));
    TEST_ASSERT_FALSE(intake.push(one.data(), one.size(), 4000));
    TEST_ASSERT_EQUAL_UINT32(2, intake.dropped());
    deck_core::DeckCore core;
    connect(core);
    const feed_intake::Drained got = intake.drain(core);
    TEST_ASSERT_EQUAL(int(feed_intake::kSlots), got.count);
    TEST_ASSERT_EQUAL_UINT64(2000, got.newest_us);
    Last screen;
    core.render(screen, 10);
    TEST_ASSERT_EQUAL(4, screen.deck);
    // Drained, it has room again.
    TEST_ASSERT_TRUE(intake.push(one.data(), one.size(), 5000));
}

// Bigger than a slot: counted and never queued, never cut and parsed. It takes no slot from the next datagram.
void test_a_datagram_too_big_is_counted_and_never_queued() {
    feed_intake::Intake intake;
    std::vector<uint8_t> big(feed_intake::kMaxDatagram + 1, 0);
    TEST_ASSERT_FALSE(intake.push(big.data(), big.size(), 1000));
    TEST_ASSERT_EQUAL_UINT32(1, intake.too_big());
    TEST_ASSERT_EQUAL_UINT32(0, intake.dropped());
    std::vector<uint8_t> fits(feed_intake::kMaxDatagram, 0);
    TEST_ASSERT_TRUE(intake.push(fits.data(), fits.size(), 2000));
    deck_core::DeckCore core;
    TEST_ASSERT_EQUAL(1, intake.drain(core).count);
}

// From a socket (the receive side's seam): everything waiting is taken, each stamped when it's read off the socket;
// one too big is skipped unread and counted, and one with the queue full is skipped and counted as dropped.
void test_pumping_a_socket_stamps_each_datagram_as_it_is_taken() {
    feed_intake::Intake intake;
    FakeSocket socket;
    socket.waiting = {deck_message(1), std::vector<uint8_t>(feed_intake::kMaxDatagram + 1, 0), deck_message(3)};
    g_us = 1000000;
    TEST_ASSERT_EQUAL(2, intake.pump(socket, ticking_us));
    TEST_ASSERT_TRUE(socket.waiting.empty());
    TEST_ASSERT_EQUAL_UINT32(1, intake.too_big());
    deck_core::DeckCore core;
    connect(core);
    const feed_intake::Drained got = intake.drain(core);
    TEST_ASSERT_EQUAL(2, got.count);
    TEST_ASSERT_EQUAL_UINT64(1000750, got.newest_us);  // the third look
    for (size_t i = 0; i <= feed_intake::kSlots; ++i) socket.waiting.push_back(deck_message(2));
    TEST_ASSERT_EQUAL(int(feed_intake::kSlots), intake.pump(socket, ticking_us));
    TEST_ASSERT_TRUE(socket.waiting.empty());
    TEST_ASSERT_EQUAL_UINT32(1, intake.dropped());
}

// A flood (#713's firmware review): one pump looks at no more than kMostPerPump datagrams, so the receive task returns
// to its wait and lets core 0's idle task run; the rest stay on the socket for the next pump.
void test_one_pump_takes_no_more_than_its_share_of_a_flood() {
    feed_intake::Intake intake;
    FakeSocket socket;
    for (int i = 0; i < 100; ++i) socket.waiting.push_back(deck_message(2));
    intake.pump(socket, ticking_us);
    TEST_ASSERT_EQUAL(100 - int(feed_intake::kMostPerPump), int(socket.waiting.size()));
    TEST_ASSERT_EQUAL(int(2 * feed_intake::kSlots), int(feed_intake::kMostPerPump));
}

/// One datagram waiting, again and again, from fixed memory: a socket that allocates nothing itself.
struct SameSocket : feed_drain::Socket {
    const std::vector<uint8_t>* datagram = nullptr;
    int left = 0;
    size_t next_size() override { return left > 0 ? datagram->size() : 0; }
    size_t read(uint8_t* into, size_t room) override {
        --left;
        size_t n = datagram->size() < room ? datagram->size() : room;
        for (size_t i = 0; i < n; ++i) into[i] = (*datagram)[i];
        return n;
    }
    void skip() override { --left; }
};

// No heap per datagram: pushing, pumping and draining a thousand frames' worth allocates nothing.
void test_taking_and_draining_datagrams_uses_no_heap() {
    static feed_intake::Intake intake;
    static deck_core::DeckCore core;
    connect(core);
    const auto m = deck_message(2);
    SameSocket socket;
    socket.datagram = &m;
    const size_t before = allocations;
    for (int frame = 0; frame < 1000; ++frame) {
        intake.push(m.data(), m.size(), uint64_t(frame) * 33000);
        socket.left = 3;
        intake.pump(socket, ticking_us);
        intake.drain(core);
    }
    TEST_ASSERT_EQUAL(before, allocations);
}

/// Records where each drained datagram came from.
struct Sources {
    std::vector<deck_core::Source> seen;
    void feed(const uint8_t*, size_t, uint32_t, deck_core::Source source) { seen.push_back(source); }
};

// One receive task takes both the UDP socket and the USB cable (#667): each datagram keeps where it came from, in
// arrival order across the two, and a push or pump without a source is Wi-Fi's.
void test_each_datagram_keeps_its_source_across_wifi_and_the_cable() {
    static feed_intake::Intake intake;
    const auto message = deck_message(2);
    intake.push(message.data(), message.size(), 1000);
    FakeSocket cable;
    cable.waiting.push_back(message);
    cable.waiting.push_back(message);
    intake.pump(cable, ticking_us, deck_core::Source::cable);
    intake.push(message.data(), message.size(), 9000, deck_core::Source::wifi);
    Sources sink;
    TEST_ASSERT_EQUAL(4, intake.drain_into(sink).count);
    TEST_ASSERT_EQUAL(4, sink.seen.size());
    TEST_ASSERT_TRUE(sink.seen[0] == deck_core::Source::wifi);
    TEST_ASSERT_TRUE(sink.seen[1] == deck_core::Source::cable);
    TEST_ASSERT_TRUE(sink.seen[2] == deck_core::Source::cable);
    TEST_ASSERT_TRUE(sink.seen[3] == deck_core::Source::wifi);
}

/// Checks what a drain hands over: each datagram's sequence number, in order, and its bytes whole.
struct Checker {
    uint32_t next = 0;
    uint32_t bad = 0;
    void feed(const uint8_t* bytes, size_t length, uint32_t, deck_core::Source = deck_core::Source::wifi) {
        uint32_t seq;
        std::memcpy(&seq, bytes, sizeof seq);
        if (seq < next) ++bad;  // out of order, or seen twice
        next = seq + 1;
        if (length != 200) ++bad;
        for (size_t i = sizeof seq; i < length; ++i) {
            if (bytes[i] != uint8_t(seq + i)) ++bad;
        }
    }
};

// The receive side and the loop on two threads at once, as on the board (lwIP's task and the loop): every datagram
// is kept or counted dropped, none twice, in order and whole.
void test_two_tasks_at_once_lose_nothing_uncounted_and_tear_nothing() {
    static feed_intake::Intake intake;
    constexpr uint32_t kCount = 200000;
    std::atomic<bool> done{false};
    uint32_t kept = 0;
    std::thread receiver([&] {
        uint8_t d[200];
        for (uint32_t seq = 0; seq < kCount; ++seq) {
            std::memcpy(d, &seq, sizeof seq);
            for (size_t i = sizeof seq; i < sizeof d; ++i) d[i] = uint8_t(seq + i);
            if (intake.push(d, sizeof d, seq)) ++kept;
        }
        done = true;
    });
    Checker checker;
    uint32_t fed = 0;
    for (bool last = false; !last;) {
        last = done.load();
        fed += intake.drain_into(checker).count;
    }
    receiver.join();
    fed += intake.drain_into(checker).count;
    TEST_ASSERT_EQUAL_UINT32(0, checker.bad);
    TEST_ASSERT_EQUAL_UINT32(kept, fed);
    TEST_ASSERT_EQUAL_UINT32(kCount, fed + intake.dropped());
}

int main(int, char**) {
    UNITY_BEGIN();
    RUN_TEST(test_the_core_gets_each_datagram_at_its_arrival_not_its_read);
    RUN_TEST(test_a_frame_takes_everything_since_the_last_in_order_and_knows_the_newest);
    RUN_TEST(test_a_full_queue_drops_the_newcomer_and_counts_it);
    RUN_TEST(test_a_datagram_too_big_is_counted_and_never_queued);
    RUN_TEST(test_pumping_a_socket_stamps_each_datagram_as_it_is_taken);
    RUN_TEST(test_one_pump_takes_no_more_than_its_share_of_a_flood);
    RUN_TEST(test_taking_and_draining_datagrams_uses_no_heap);
    RUN_TEST(test_two_tasks_at_once_lose_nothing_uncounted_and_tear_nothing);
    RUN_TEST(test_each_datagram_keeps_its_source_across_wifi_and_the_cable);
    return UNITY_END();
}
