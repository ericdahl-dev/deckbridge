// The display feed over the USB cable (#667): DeckBridge sends each OSC packet as one SLIP frame (RFC 1055, as OSC 1.1
// has it for serial), END (0xC0) before and after. This reads the cable's bytes and hands out whole packets as a
// feed_drain::Socket, so the drain and its time budget serve the cable as they serve UDP. The serial driver's receive
// buffer is the queue: bytes are pulled only when the drain asks for the next packet.
#pragma once

#include <cstddef>
#include <cstdint>

#include "feed_drain.h"

namespace serial_feed {

/// The cable's received bytes, as the board layer has them (Serial).
struct Bytes {
    virtual ~Bytes() = default;
    /// Reads up to `room` waiting bytes into `into` without waiting (Serial.read(buf, n) on the board); returns how many.
    virtual size_t read(uint8_t* into, size_t room) = 0;
};

/// Where text outside a frame goes, a byte at a time: the "version" question (#695) shares the cable with the feed.
struct Text {
    virtual ~Text() = default;
    virtual void put(char c) = 0;
};

class SerialFeed : public feed_drain::Socket {
public:
    /// A frame with no byte for this long is dropped: DeckBridge writes each frame whole, so it was cut (#667).
    static constexpr uint32_t kQuietMs = 100;
    /// One look reads at most this many bytes (Codex on #754): a frame of 1,472 B, escaped, fits; a stream of text or
    /// a runaway frame can't hold the read step, and the rest waits for the next look.
    static constexpr size_t kMostPerCall = 4096;

    /// `clock`: milliseconds (millis on the board), to drop a cut frame; without one, a cut frame waits for an END.
    explicit SerialFeed(Bytes& bytes, Text* text = nullptr, feed_drain::Clock clock = nullptr)
        : bytes_(bytes), text_(text), clock_(clock) {}

    size_t next_size() override;
    size_t read(uint8_t* into, size_t room) override;
    void skip() override;

private:
    Bytes& bytes_;
    Text* text_;
    feed_drain::Clock clock_;
    uint32_t last_byte_ms_ = 0;
    /// Bytes read from the cable in one call and not yet taken: one driver call per chunk, not per byte (firmware review).
    static constexpr size_t kChunk = 64;
    uint8_t chunk_[kChunk];
    size_t chunk_at_ = 0;
    size_t chunk_end_ = 0;
    /// The next byte read, or -1 if none waits.
    int next();
    /// A cut frame being dropped: a whole "version" line inside it goes to the text sink.
    void pass_version_line();
    uint8_t packet_[feed_drain::kMaxDatagram];
    size_t length_ = 0;
    bool complete_ = false;
    bool overlong_ = false;  ///< the frame had more than packet_ holds: the rest was dropped
    bool in_frame_ = false;
    bool escaped_ = false;
};

}  // namespace serial_feed
