#include "feed_intake.h"

#include <cstring>

namespace feed_intake {

Intake::Slot* Intake::free_slot() {
    const uint32_t tail = tail_.load(std::memory_order_relaxed);
    if (tail - head_.load(std::memory_order_acquire) == kSlots) return nullptr;
    return &slots_[tail % kSlots];
}

bool Intake::push(const uint8_t* bytes, size_t length, uint64_t at_us, deck_core::Source source) {
    if (length > kMaxDatagram) {
        count(too_big_);
        return false;
    }
    Slot* slot = free_slot();
    if (!slot) {
        count(dropped_);
        return false;
    }
    std::memcpy(slot->bytes, bytes, length);
    slot->length = length;
    slot->at_us = at_us;
    slot->source = source;
    publish();
    return true;
}

int Intake::pump(feed_drain::Socket& socket, ClockUs clock, deck_core::Source source) {
    int kept = 0;
    for (size_t size = socket.next_size(); size > 0; size = socket.next_size()) {
        const uint64_t at_us = clock();
        if (size > kMaxDatagram) {
            count(too_big_);
            socket.skip();
            continue;
        }
        Slot* slot = free_slot();
        if (!slot) {
            count(dropped_);
            socket.skip();
            continue;
        }
        slot->length = socket.read(slot->bytes, sizeof slot->bytes);
        slot->at_us = at_us;
        slot->source = source;
        publish();
        ++kept;
    }
    return kept;
}

}  // namespace feed_intake
