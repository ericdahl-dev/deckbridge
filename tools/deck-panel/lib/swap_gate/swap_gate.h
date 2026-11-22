// The flush/vsync handshake for two framebuffers (#635), as a state machine kept free of Arduino and FreeRTOS so it's
// host-tested. On the panel: flush() and swapped() run in LVGL's flush callback, must_wait() and waited() in its
// flush-wait callback, vsync() in the panel's vsync interrupt.
#pragma once

#include <atomic>
#include <cstdint>

namespace swap_gate {

class Gate {
  public:
    // One area of a frame was drawn. True: release it at once (call lv_display_flush_ready). False: it's the last,
    // so hand the buffer to the panel, then call swapped().
    bool flush(bool last_area);
    // The buffer was handed to the panel: the frame is released at the next vsync.
    void swapped();
    // From the vsync interrupt: true if this vsync releases the frame (give the semaphore), once per swap.
    bool vsync();
    // Whether LVGL must wait for a vsync before drawing again.
    bool must_wait() const;
    // The wait ended: got the vsync, or timed out (counted).
    void waited(bool got_vsync);
    uint32_t timeouts() const;

  private:
    // Set by swapped(), read and cleared by the vsync interrupt: atomic.
    std::atomic<bool> armed_{false};
    // LVGL's task only.
    bool outstanding_ = false;
    uint32_t timeouts_ = 0;
};

}  // namespace swap_gate
