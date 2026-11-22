// The scripted panel (#666): the panel_scan::Panel seam with a timeline instead of esp_lcd. Interrupts are scripted
// at microsecond times; a blocking take runs the script forward until its signal is given or its timeout passes, as
// the loop would sit in xSemaphoreTake while the panel's interrupts come.
#pragma once

#include <cstdint>
#include <vector>

#include "panel_scan.h"

struct ScriptedPanel : panel_scan::Panel {
    enum class Irq { vsync, frame_complete };
    struct Event {
        uint64_t at_us;
        Irq irq;
    };

    panel_scan::Scan* scan = nullptr;  // where the interrupts go
    std::vector<Event> script;          // in time order
    size_t next = 0;
    uint64_t now_us = 0;
    bool started = false;
    panel_scan::Config config{};
    int hand_overs = 0;
    int wakes = 0;  // takes that returned with their signal: the loop woken
    bool given[3] = {false, false, false};  // a binary semaphore per signal

    bool start(const panel_scan::Config& c) override {
        started = true;
        config = c;
        return true;
    }
    void hand_over() override { ++hand_overs; }
    void give(panel_scan::Signal s) override { given[static_cast<int>(s)] = true; }
    void drop(panel_scan::Signal s) override { given[static_cast<int>(s)] = false; }
    bool take(panel_scan::Signal s, uint32_t timeout_ms) override {
        const uint64_t until = now_us + uint64_t(timeout_ms) * 1000;
        while (!given[static_cast<int>(s)]) {
            if (next >= script.size() || script[next].at_us >= until) {
                now_us = until;
                // An interrupt at the very moment the wait gives up lands after the timeout, before the caller hears
                // of it: the race a real semaphore has, and the give it leaves behind.
                while (next < script.size() && script[next].at_us == until) fire();
                return false;
            }
            fire();
        }
        given[static_cast<int>(s)] = false;
        ++wakes;
        return true;
    }
    uint64_t now() const override { return now_us; }
    void lock() override {}
    void unlock() override {}

    /// The next scripted interrupt, now.
    void fire() {
        const Event e = script[next++];
        if (e.at_us > now_us) now_us = e.at_us;
        if (e.irq == Irq::vsync) scan->vsync(e.at_us);
        else scan->frame_complete(e.at_us);
    }
    /// Every scripted interrupt up to `t_us`, then the clock at `t_us`: the loop busy until then.
    void run_until(uint64_t t_us) {
        while (next < script.size() && script[next].at_us <= t_us) fire();
        if (t_us > now_us) now_us = t_us;
    }
};
