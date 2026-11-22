// The bounce copy's budget (#635): while the DMA sends one bounce buffer, the interrupt copies the next chunk out of
// PSRAM into the other, and it has to finish before the DMA comes back. This meters how close it runs, so an underrun
// shows on the perf line instead of only as stale rows on the glass. Kept free of Arduino so it's host-tested.
#pragma once

#include <cstdint>

#include "frame_pacing.h"

namespace bounce_budget {

// How long the DMA takes to send one chunk of bounce_px pixels, in ns: the copy's deadline.
uint32_t chunk_ns(const frame_pacing::Timing& timing, uint32_t bounce_px);

struct Report {
    uint32_t chunks = 0;    // copies timed
    uint32_t worst_us = 0;  // the longest
    int32_t margin_us = 0;  // the budget less the longest; below 0 is an underrun
    uint32_t late = 0;      // copies longer than the budget: the margin's count
    // Copies longer than two budgets (#663): the DMA reads the refilled buffer from one chunk after the fill starts
    // to two, front to back as the copy writes it, so only these can leave stale pixels on the glass.
    uint32_t past_glass = 0;
};

class Meter {
  public:
    explicit Meter(uint32_t budget_ns) : budget_ns_(budget_ns) {}
    // One chunk's copy took this long.
    // In the header so the board's IRAM copy wrapper inlines it: no flash call per chunk (#666).
    void copied(uint32_t took_us) {
        ++window_.chunks;
        if (took_us > window_.worst_us) window_.worst_us = took_us;
        if (static_cast<uint64_t>(took_us) * 1000u > budget_ns_) ++window_.late;
        if (static_cast<uint64_t>(took_us) * 1000u > 2ull * budget_ns_) ++window_.past_glass;
    }
    // This window's numbers, and a new window.
    Report take();

  private:
    uint32_t budget_ns_;
    Report window_;
};

}  // namespace bounce_budget
