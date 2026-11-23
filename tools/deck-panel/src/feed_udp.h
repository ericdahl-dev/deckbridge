// The feed's UDP socket (#620): a raw lwIP socket on DeckCore::kFeedPort (#664), never a callback. The receive task
// (main.cpp) waits on it with a bounded select() and drains it; it's that task's alone (or, with FEED_RX_TASK=0, the
// loop's), so open, close, wait and read never race: a close under another task's select() is the case to avoid.
// Every read is MSG_DONTWAIT and nothing here allocates. The intake stamps each datagram (lib/feed_intake), so nothing
// here keeps time. Receive only: the panel never sends (ADR 0011).
#pragma once

#include <cstdint>

#include "feed_drain.h"

class FeedUdp : public feed_drain::Socket {
public:
    /// Opens the socket on each new connection (`joins` changed) and closes it off Wi-Fi; call before each look.
    void poll(bool connected, uint32_t joins, uint32_t now_ms);

    /// Waits up to `timeout_ms` for a datagram; true if one is waiting. Never longer, and never less without one: with
    /// the socket shut (no Wi-Fi) or select() failing it sleeps `timeout_ms` instead, so a task looping on it can't
    /// spin. A failed select() also shuts the socket, and poll() reopens it after kRetryMs.
    bool wait(uint32_t timeout_ms);

    size_t next_size() override;
    size_t read(uint8_t* into, size_t room) override;
    void skip() override;

private:
    /// Retries a failed open this long after.
    static constexpr uint32_t kRetryMs = 1000;

    bool open();
    void shut();

    int fd_ = -1;  ///< lwIP's descriptor; -1 shut
    uint32_t opened_for_ = 0;  ///< the join it was opened for
    uint32_t tried_ms_ = 0;
    bool tried_ = false;
    /// The waiting datagram's size, peeked and not yet read or skipped; 0 if none looked at.
    size_t pending_ = 0;
    /// The peek's landing: a byte more than the biggest kept, so a bigger one shows as too big (lwIP's recvfrom
    /// returns what it copied, never the datagram's length). Here, not on the task's stack; .bss, internal RAM.
    uint8_t peek_[feed_drain::kMaxDatagram + 1];
};
