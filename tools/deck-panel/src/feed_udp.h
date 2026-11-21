// The feed's UDP socket (#620): WiFiUDP on DeckCore::kFeedPort, polled by the receive task (main.cpp, #664), never a
// callback, and touched by no other task: WiFiUDP isn't thread-safe. The intake stamps each datagram (lib/feed_intake),
// so nothing here keeps time. Receive only: the panel never sends (ADR 0011).
#pragma once

#include <WiFiUdp.h>

#include <cstdint>

#include "feed_drain.h"

class FeedUdp : public feed_drain::Socket {
public:
    /// Opens the socket on each new connection (`joins` changed) and closes it off Wi-Fi; call before each look.
    void poll(bool connected, uint32_t joins, uint32_t now_ms);

    size_t next_size() override;
    size_t read(uint8_t* into, size_t room) override;
    void skip() override;

private:
    /// Retries a failed open this long after.
    static constexpr uint32_t kRetryMs = 1000;

    WiFiUDP udp_;
    bool open_ = false;
    uint32_t opened_for_ = 0;  ///< the join it was opened for
    uint32_t tried_ms_ = 0;
    bool tried_ = false;
    /// A datagram parsePacket() took in but nobody read yet: WiFiUDP returns 0 until it's cleared.
    size_t pending_ = 0;
};
