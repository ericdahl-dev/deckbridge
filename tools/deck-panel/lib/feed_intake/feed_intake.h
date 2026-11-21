// The feed's intake (#664): each datagram is stamped when it arrives and queued in fixed memory; the loop's frame takes
// what came since the last one and feeds the core each datagram at its own arrival time.
//
// Two tasks share it, and only these rules make that safe (a single-producer, single-consumer ring):
// - One producer: push() and pump() are called from one task only (the receive side). One consumer: drain() and
//   drain_into() are called from one task only (the loop). Never two producers, never two consumers.
// - The producer writes only tail_ and the counters, and a slot only while it's free (tail_ - head_ < kSlots). It
//   fills the slot first, then publishes it by storing tail_ (release).
// - The consumer writes only head_, and reads a slot only after loading tail_ (acquire) shows it filled. It frees the
//   slot by storing head_ (release) only after it's done with the bytes, so the producer, which loads head_ (acquire),
//   never writes a slot that's being read.
// - head_ and tail_ count up forever and wrap together (unsigned); a slot is index % kSlots, kSlots a power of two.
// - The counters are written by the producer only and read anywhere; a read may be a datagram behind.
// - Nothing blocks and nothing allocates, on either side.
#pragma once

#include <atomic>
#include <cstddef>
#include <cstdint>

#include "deck_core.h"
#include "feed_drain.h"

namespace feed_intake {

/// The biggest datagram kept: one UDP payload in an Ethernet frame (1500 less the IP and UDP headers).
constexpr size_t kMaxDatagram = 1472;
/// Datagrams held between frames. The feed's worst burst in one frame (ADR 0011, #636): a snapshot (one bundle, two
/// past 1200 B), the fast slot's bundle and a change or two, so about 5. The old path held 6 in lwIP and read 8 a
/// frame. 16 holds three frames' worth, so a frame late by two periods (a Wi-Fi rejoin, a slow chore) drops nothing;
/// a drop is counted and the 2 s keepalive heals it. 16 x 1.5 KB = 24 KB, fixed.
constexpr size_t kSlots = 16;
static_assert((kSlots & (kSlots - 1)) == 0, "the indexes wrap cleanly only for a power of two");

/// What a frame took: how many datagrams, and when the oldest and the newest of them arrived (0 if none): the
/// ledger's skip goes by the oldest, its lag by the newest (#662).
struct Drained {
    int count = 0;
    uint64_t oldest_us = 0;
    uint64_t newest_us = 0;
};

/// Microseconds, esp_timer's clock on the board.
using ClockUs = uint64_t (*)();

class Intake {
public:
    /// Queues a datagram that arrived at `at_us` (microseconds, esp_timer's clock). False if it wasn't kept: bigger
    /// than kMaxDatagram (counted in too_big), or the queue was full, so the newcomer is dropped and counted (dropped)
    /// and what's queued stays. The producer's.
    bool push(const uint8_t* bytes, size_t length, uint64_t at_us,
              deck_core::Source source = deck_core::Source::wifi);
    /// Takes every datagram waiting on `socket` into the queue, each stamped by `clock` as it's found, read straight
    /// into its slot; one too big, or one with the queue full, is skipped unread and counted. Returns how many it
    /// kept. `source` is where they came from: Wi-Fi's UDP socket, or the USB cable's reader (#667), pumped by the same
    /// receive task so there is still one producer. The producer's.
    int pump(feed_drain::Socket& socket, ClockUs clock, deck_core::Source source = deck_core::Source::wifi);
    /// Feeds the core every datagram queued, oldest first, each at its arrival (in ms, millis' clock) and with where it
    /// came from. The consumer's.
    Drained drain(deck_core::DeckCore& core) { return drain_into(core); }
    /// The same, into anything with DeckCore's feed(bytes, length, now_ms, source).
    template <class Sink>
    Drained drain_into(Sink& sink);
    /// Since boot: datagrams dropped because the queue was full, and because they were bigger than kMaxDatagram.
    uint32_t dropped() const { return dropped_.load(std::memory_order_relaxed); }
    uint32_t too_big() const { return too_big_.load(std::memory_order_relaxed); }

private:
    struct Slot {
        uint64_t at_us = 0;
        size_t length = 0;
        deck_core::Source source = deck_core::Source::wifi;
        uint8_t bytes[kMaxDatagram];
    };
    /// The producer's next free slot, or nullptr when full.
    Slot* free_slot();
    /// Publishes the slot free_slot() gave.
    void publish() { tail_.store(tail_.load(std::memory_order_relaxed) + 1, std::memory_order_release); }
    void count(std::atomic<uint32_t>& counter) {
        counter.store(counter.load(std::memory_order_relaxed) + 1, std::memory_order_relaxed);
    }

    Slot slots_[kSlots];
    std::atomic<uint32_t> head_{0};  // the next to drain: the consumer's
    std::atomic<uint32_t> tail_{0};  // the next to fill: the producer's
    std::atomic<uint32_t> dropped_{0};
    std::atomic<uint32_t> too_big_{0};
};

template <class Sink>
Drained Intake::drain_into(Sink& sink) {
    Drained got;
    uint32_t head = head_.load(std::memory_order_relaxed);
    const uint32_t tail = tail_.load(std::memory_order_acquire);
    // Only what was there when the frame looked: one that lands meanwhile waits for the next frame, so a flood
    // can't hold this frame past kSlots datagrams.
    for (; head != tail; ++head) {
        const Slot& slot = slots_[head % kSlots];
        sink.feed(slot.bytes, slot.length, static_cast<uint32_t>(slot.at_us / 1000), slot.source);
        if (got.count == 0) got.oldest_us = slot.at_us;
        got.newest_us = slot.at_us;
        ++got.count;
        head_.store(head + 1, std::memory_order_release);
    }
    return got;
}

}  // namespace feed_intake
