// The panel's frame ledger (#662): one record per frame, from the newest feed datagram's arrival to the vsync that
// put its frame on the glass, so lag is measured without a camera and "nothing changed" is told from "missed a frame".
// Kept free of Arduino so it's host-tested; the perf build (-DPANEL_PERF_LOG) feeds it and prints its report in the
// 5 s perf line, never per frame. Times are microseconds on one clock (esp_timer on the board); they may wrap.
#pragma once

#include <cstdint>

namespace frame_ledger {

struct Report {
    uint32_t frames = 0;           // frames that carried feed data to the glass
    uint32_t lag_typical_us = 0;   // arrival to glass, the median (the upper of the middle two)
    uint32_t lag_worst_us = 0;
    uint32_t skipped = 0;          // frames that reached the glass a vsync or more late
};

class Ledger {
  public:
    // Lags kept per window for the median: a 5 s window at the panel's 39 frames/s is about 195.
    static constexpr int kCapacity = 256;

    // A feed datagram arrived at `us`, stamped where it came in (#664); it may be told after later vsyncs. Lag counts
    // from the newest arrival since the last read, the skip from the oldest.
    void arrived(uint32_t us);
    // A feed datagram was read and handed to the core. Its frame is skipped if the oldest arrival since the last read came before the latch ahead of
    // the one that woke this read: a frame went by that could have taken it. The waking latch must already have been
    // told (vsync), or the count is one short.
    void read(uint32_t us);
    // The frame was handed to the panel.
    void swapped(uint32_t us);
    // A refresh after the read drew nothing: what was read changed nothing on screen, so it waits for no frame.
    void nothing_drawn();
    // Every vsync (latch), drawing or not, in order.
    void vsync(uint32_t us);
    // The swap's release: the start of the scan-out that shows the frame. "On glass" means that moment; a row further
    // down shows later by a constant (the deck's beat row about 22 ms), so a camera's numbers differ by that much.
    void on_glass(uint32_t us);
    // The report since the last take(), and a fresh window.
    Report take();

  private:
    // Seen on the socket, not read yet: the newest.
    bool arrived_ = false;
    uint32_t arrived_us_ = 0;
    // The last latches' times, newest at latches_[0]; 0 told so far are unknown.
    static constexpr int kLatches = 2;
    uint32_t latches_[kLatches] = {};
    int latches_told_ = 0;
    uint32_t oldest_us_ = 0;  // the oldest of them
    // Read, waiting for a frame to be handed over.
    bool waiting_ = false;
    uint32_t waiting_us_ = 0;
    bool waiting_late_ = false;  // a vsync passed while it waited
    // In the frame handed over, waiting for the glass.
    bool in_flight_ = false;
    uint32_t in_flight_us_ = 0;
    bool in_flight_late_ = false;
    Report report_;
    uint32_t lags_[kCapacity];
    int stored_ = 0;
};

}  // namespace frame_ledger
