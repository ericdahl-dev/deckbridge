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
    /// The next received byte, or -1 if none waits.
    virtual int next() = 0;
};

/// Where text outside a frame goes, a byte at a time: the "version" question (#695) shares the cable with the feed.
struct Text {
    virtual ~Text() = default;
    virtual void put(char c) = 0;
};

class SerialFeed : public feed_drain::Socket {
public:
    explicit SerialFeed(Bytes& bytes, Text* text = nullptr) : bytes_(bytes), text_(text) {}

    size_t next_size() override;
    size_t read(uint8_t* into, size_t room) override;
    void skip() override;

private:
    Bytes& bytes_;
    Text* text_;
    uint8_t packet_[feed_drain::kMaxDatagram];
    size_t length_ = 0;
    bool complete_ = false;
    bool overlong_ = false;  ///< the frame had more than packet_ holds: the rest was dropped
    bool in_frame_ = false;
    bool escaped_ = false;
};

}  // namespace serial_feed
