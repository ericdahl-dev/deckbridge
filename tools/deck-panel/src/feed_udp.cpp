#include "feed_udp.h"

#include <Arduino.h>

#include "deck_core.h"
#include "feed_flags.h"

#if !FEED_RX_TASK && defined(PANEL_PERF_LOG)
// FEED_RX_TASK=0 (feed_flags.h): main's ledger stamps, verbatim, for the old path.
#include <esp_timer.h>

#include "perf_log.h"

namespace {
uint32_t now_us() { return static_cast<uint32_t>(esp_timer_get_time()); }
}  // namespace
#endif

void FeedUdp::poll(bool connected, uint32_t joins, uint32_t now_ms) {
    if (!connected) {
        if (open_) {
            udp_.stop();
            open_ = false;
            pending_ = 0;
        }
        return;
    }
    if (open_ && opened_for_ == joins) return;
    if (tried_ && opened_for_ == joins && now_ms - tried_ms_ < kRetryMs) return;
    // A rejoin can bring a new interface address: a fresh socket, not one bound before it. begin() stops the old one.
    tried_ = true;
    tried_ms_ = now_ms;
    opened_for_ = joins;
    pending_ = 0;
    open_ = udp_.begin(deck_core::DeckCore::kFeedPort) != 0;
    Serial.printf("deck panel: feed port %u %s\n", unsigned(deck_core::DeckCore::kFeedPort),
                  open_ ? "open" : "didn't open; retrying");
}

size_t FeedUdp::next_size() {
    if (!open_) return 0;
    if (pending_ == 0) {
        // Takes the next datagram off lwIP into WiFiUDP's own buffer; never waits.
        const int size = udp_.parsePacket();
        pending_ = size > 0 ? static_cast<size_t>(size) : 0;
#if !FEED_RX_TASK && defined(PANEL_PERF_LOG)
        // The first look that finds it, for the frame ledger (#662). Only the drain looks, right before it reads, so
        // this is the read's time to within microseconds, not its arrival: it trails that by the time since the
        // last drain (about a frame). parsePacket() is the only look, and it takes the datagram off lwIP.
        if (pending_ > 0) perf_log::feed_seen(now_us());
#endif
    }
    return pending_;
}

size_t FeedUdp::read(uint8_t* into, size_t room) {
    const int got = udp_.read(into, room);
    // Whatever didn't fit goes too: one datagram is one message.
    udp_.clear();
    pending_ = 0;
#if !FEED_RX_TASK && defined(PANEL_PERF_LOG)
    if (got > 0) perf_log::feed_read(now_us());
#endif
    return got > 0 ? static_cast<size_t>(got) : 0;
}

void FeedUdp::skip() {
    // clear(), not flush(): flush() is clear() in this core, but in others it's a no-op, which would stall the feed.
    udp_.clear();
    pending_ = 0;
}
