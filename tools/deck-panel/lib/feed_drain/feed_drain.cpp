#include "feed_drain.h"

namespace feed_drain {

int Drain::run(Socket& socket, deck_core::DeckCore& core, uint32_t now_ms, Clock clock) {
    return run(socket, core, now_ms, clock, clock ? clock() : 0);
}

int Drain::run(Socket& socket, deck_core::DeckCore& core, uint32_t now_ms, Clock clock, uint32_t since_ms) {
    int fed = 0;
    const uint32_t start = since_ms;
    // Each turn takes one datagram, read or dropped, so a frame's work is bounded either way.
    for (int turn = 0; turn < kMaxPerFrame; ++turn) {
        if (turn > 0 && clock && clock() - start >= kBudgetMs) break;
        const size_t size = socket.next_size();
        if (size == 0) break;
        ++received_;
        if (size > kMaxDatagram) {
            socket.skip();
            ++too_big_;
            continue;
        }
        const size_t length = socket.read(buffer_, sizeof buffer_);
        core.feed(buffer_, length, now_ms, source_);
        ++fed;
        ++processed_;
    }
    return fed;
}

}  // namespace feed_drain
