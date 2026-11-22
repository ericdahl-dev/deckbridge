// The panel's receive path (#620, #636). The loop task polls the UDP socket and hands each datagram to the core, so the
// core only ever runs on that one task (it isn't thread-safe). lwIP's socket buffer is the queue, 6 datagrams deep in
// this sdkconfig: what it drops is invisible from here (LWIP_STATS is off). The feed sends each update and each full
// snapshot as one bundle (#636), and a frame reads until the socket is empty, so a burst fits.
#pragma once

#include <cstddef>
#include <cstdint>

#include "deck_core.h"

namespace feed_drain {

/// The biggest datagram read: one UDP payload in an Ethernet frame (1500 less the IP and UDP headers). The feed's
/// bundles (#636) are about 700 B and split past 1200 B. Bigger ones are dropped. A fixed buffer, read into per frame.
constexpr size_t kMaxDatagram = 1472;
/// A frame reads until the socket is empty (lwIP holds only 6 datagrams for it, #636), but for no longer than this,
/// so a flood can't hold the screen up; the rest wait for the next frame.
constexpr uint32_t kBudgetMs = 4;
/// And never more than this many, whatever the clock says.
constexpr int kMaxPerFrame = 256;

/// Milliseconds, any clock (millis on the board).
using Clock = uint32_t (*)();

/// A UDP socket, as the board layer has it (WiFiUDP).
struct Socket {
    virtual ~Socket() = default;
    /// The next waiting datagram's size; 0 if none.
    virtual size_t next_size() = 0;
    /// Reads the next datagram into `into`; returns its length.
    virtual size_t read(uint8_t* into, size_t room) = 0;
    /// Drops the next datagram unread.
    virtual void skip() = 0;
};

class Drain {
public:
    /// `source`: where the socket's datagrams come from, told to the core (the USB cable needs no Wi-Fi, #667).
    explicit Drain(deck_core::Source source = deck_core::Source::wifi) : source_(source) {}
    /// Feeds waiting datagrams to `core`, stamped `now_ms`, until the socket is empty or `clock` has run kBudgetMs;
    /// returns how many were fed. Without a clock, only kMaxPerFrame bounds it.
    int run(Socket& socket, deck_core::DeckCore& core, uint32_t now_ms, Clock clock = nullptr);
    /// Since boot: datagrams seen on the socket, fed to the core, and dropped for being bigger than kMaxDatagram.
    /// received - processed - too_big is always 0: what a frame leaves waits on the socket, unseen yet.
    uint32_t received() const { return received_; }
    uint32_t processed() const { return processed_; }
    uint32_t too_big() const { return too_big_; }

private:
    deck_core::Source source_;
    uint8_t buffer_[kMaxDatagram];
    uint32_t received_ = 0;
    uint32_t processed_ = 0;
    uint32_t too_big_ = 0;
};

}  // namespace feed_drain
