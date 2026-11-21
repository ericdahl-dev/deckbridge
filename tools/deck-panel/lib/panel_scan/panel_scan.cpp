#include "panel_scan.h"

#include "bounce_budget.h"

namespace panel_scan {

bool Scan::start(const Config& config) {
    const uint32_t frame_px = static_cast<uint32_t>(config.timing.width) * static_cast<uint32_t>(config.timing.height);
    if (config.bounce_px != 0 && (frame_px % config.bounce_px != 0 || (frame_px / config.bounce_px) % 2 != 0)) {
        return false;
    }
    // Set before the panel starts: its interrupts begin inside start(), and read the config (bounce or not, the
    // copy's deadline) from their first.
    config_ = config;
    frame_us_ = frame_pacing::frame_us(config.timing);
    const uint32_t budget_ns = config.bounce_px == 0 ? 0 : bounce_budget::chunk_ns(config.timing, config.bounce_px);
    copy_budget_ns_ = budget_ns;
    copy_budget_us_ = budget_ns / 1000;
    meter_ = bounce_budget::Meter(budget_ns);
    return panel_.start(config);
}

bool Scan::present(bool last_area) {
    if (gate_.flush(last_area)) return true;
    panel_.hand_over();
    ++swaps_;
    // A release left from a timed-out wait would free this swap before its latch: dropped before the gate is armed.
    panel_.drop(Signal::release);
    gate_.swapped();
    defer_ = true;
    return false;
}

Wait Scan::wait_release(uint32_t timeout_ms) {
    if (!gate_.must_wait()) return Wait::released;
    if (defer_) {
        defer_ = false;
        return Wait::deferred;
    }
    const bool got = panel_.take(Signal::release, timeout_ms);
    gate_.waited(got);
    return got ? Wait::released : Wait::timed_out;
}

void Scan::latch(uint64_t now_us) {
    const bool released = gate_.vsync();
    // Stamped before the gives, so a waiter that wakes reads this latch.
    panel_.lock();
    ++latches_.count;
    latches_.previous_us = latches_.us;
    latches_.us = now_us;
    panel_.unlock();
    if (released) panel_.give(Signal::release);
    panel_.give(Signal::latch);
}

void Scan::vsync(uint64_t now_us) {
    // Without bounce buffers the latch is this vsync, and comes first, so a frame woken here sees its count.
    if (config_.bounce_px == 0) latch(now_us);
    panel_.lock();
    vsync_us_ = now_us;
    ++vsyncs_;
    watch_.vsync(static_cast<uint32_t>(now_us));
    panel_.unlock();
    panel_.give(Signal::vsync);
}

Latches Scan::latches() const {
    panel_.lock();
    const Latches l = latches_;
    panel_.unlock();
    return l;
}

bool Scan::wait_next_frame(uint32_t timeout_ms, Latches& latch) {
    const uint32_t entry = latches().count;
    const uint64_t until = panel_.now() + uint64_t(timeout_ms) * 1000;
    for (;;) {
        const uint64_t now = panel_.now();
        if (now >= until) return false;
        const uint32_t left_ms = static_cast<uint32_t>((until - now + 999) / 1000);
        if (!panel_.take(Signal::latch, left_ms)) return false;
        latch = latches();
        if (latch.count != entry) return true;  // else a give from before the call: wait on
    }
}

bool Scan::wait_vsync_after(const Latches& latch, uint32_t timeout_ms) {
    const uint64_t until = panel_.now() + uint64_t(timeout_ms) * 1000;
    for (;;) {
        panel_.lock();
        const uint64_t vsync_us = vsync_us_;
        panel_.unlock();
        // Without bounce buffers the latch is this vsync, the same stamp: at or after.
        if (vsync_us > latch.us || (config_.bounce_px == 0 && vsync_us == latch.us)) return true;
        const uint64_t now = panel_.now();
        if (now >= until) return false;
        if (!panel_.take(Signal::vsync, static_cast<uint32_t>((until - now + 999) / 1000))) return false;
    }
}

bool Scan::wait_frame(uint32_t timeout_ms, Latches& latch) {
    const uint32_t entry = latches().count;
    const uint64_t until = panel_.now() + uint64_t(timeout_ms) * 1000;
    for (;;) {
        panel_.lock();
        const Latches l = latches_;
        const uint64_t vsync_us = vsync_us_;
        panel_.unlock();
        if (l.count != entry && (vsync_us > l.us || (config_.bounce_px == 0 && vsync_us == l.us))) {
            latch = l;
            return true;
        }
        const uint64_t now = panel_.now();
        if (now >= until) return false;
        if (!panel_.take(Signal::vsync, static_cast<uint32_t>((until - now + 999) / 1000))) return false;
    }
}

void Scan::frame_complete(uint64_t now_us) {
    panel_.lock();
    watch_.frame_complete(static_cast<uint32_t>(now_us));
    panel_.unlock();
    if (config_.bounce_px != 0) latch(now_us);
}

void Scan::copied(uint32_t took_us, uint64_t now_us, bool drawing) {
    panel_.lock();
    meter_.copied(took_us);
    if (static_cast<uint64_t>(took_us) * 1000 > copy_budget_ns_) {  // the deadline from start(), not per copy
        if (drawing) ++copy_late_drawing_;
        // Placed by its start. A copy that started before the latch wraps to a huge unsigned value: not the turn.
        else if (now_us - took_us - latches_.us < kTurnUs) ++copy_late_turn_;
    }
    panel_.unlock();
}

Health Scan::take_health() {
    Health h;
    panel_.lock();
    h.vsyncs = vsyncs_ - seen_vsyncs_;
    h.latches = latches_.count - seen_latches_;
    seen_vsyncs_ = vsyncs_;
    seen_latches_ = latches_.count;
    h.scan = watch_.take();
    h.copy = meter_.take();
    h.copy_late_drawing = copy_late_drawing_;
    h.copy_late_turn = copy_late_turn_;
    copy_late_drawing_ = copy_late_turn_ = 0;
    panel_.unlock();
    h.swaps = swaps_;
    swaps_ = 0;
    h.swap_timeouts = gate_.timeouts() - seen_timeouts_;
    seen_timeouts_ = gate_.timeouts();
    return h;
}

const Health& HealthLooks::look(Scan& scan, Part part) {
    const int i = static_cast<int>(part);
    if (looked_[i]) {
        health_ = scan.take_health();
        looked_[0] = looked_[1] = looked_[2] = false;
    }
    looked_[i] = true;
    return health_;
}

}  // namespace panel_scan
