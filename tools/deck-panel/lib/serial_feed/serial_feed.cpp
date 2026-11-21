#include "serial_feed.h"

namespace serial_feed {

namespace {
constexpr uint8_t kEnd = 0xC0;
constexpr uint8_t kEsc = 0xDB;
constexpr uint8_t kEscEnd = 0xDC;
constexpr uint8_t kEscEsc = 0xDD;
}  // namespace

size_t SerialFeed::next_size() {
    while (!complete_) {
        const int next = bytes_.next();
        if (next < 0) return 0;
        uint8_t byte = static_cast<uint8_t>(next);
        if (byte == kEnd) {
            // An END with nothing before it opens a frame; one after bytes closes it.
            if (in_frame_ && length_ > 0) complete_ = true;
            in_frame_ = !complete_;
            escaped_ = false;
            continue;
        }
        if (!in_frame_) continue;
        if (escaped_) {
            escaped_ = false;
            if (byte == kEscEnd) byte = kEnd;
            else if (byte == kEscEsc) byte = kEsc;
        } else if (byte == kEsc) {
            escaped_ = true;
            continue;
        }
        if (length_ < sizeof packet_) packet_[length_++] = byte;
    }
    return length_;
}

size_t SerialFeed::read(uint8_t* into, size_t room) {
    const size_t n = length_ < room ? length_ : room;
    for (size_t i = 0; i < n; ++i) into[i] = packet_[i];
    skip();
    return n;
}

void SerialFeed::skip() {
    length_ = 0;
    complete_ = false;
}

}  // namespace serial_feed
