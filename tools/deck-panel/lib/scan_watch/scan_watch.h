// The scan watch (#635): makes a jumping picture visible in numbers. esp_lcd has no underrun or resync counter, but
// in bounce mode its frame-complete callback comes at a fixed point after each vsync while the scan-out is healthy.
// Kept free of Arduino so it's host-tested; the panel's two interrupts feed it, on one core.
#pragma once

#include <cstdint>

namespace scan_watch {

// A change in the vsync-to-frame-complete time bigger than this is a resync: about one bounce chunk at 16 MHz.
constexpr uint32_t kResyncUs = 500;

struct Report {
    uint32_t lag_min_us = 0, lag_max_us = 0;      // vsync to frame-complete
    uint32_t vsync_min_us = 0, vsync_max_us = 0;  // vsync to vsync
    uint32_t resyncs = 0;
};

class Watch {
  public:
    void vsync(uint32_t now_us);
    void frame_complete(uint32_t now_us);
    // This window's numbers, and a new window.
    Report take();

  private:
    bool have_vsync_ = false, have_lag_ = false;  // across windows
    uint32_t last_vsync_us_ = 0, last_lag_us_ = 0;
    bool window_lag_ = false, window_interval_ = false;
    Report window_;
};

}  // namespace scan_watch
