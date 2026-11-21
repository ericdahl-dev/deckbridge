// The panel's beat clock (#660): the master clock's beat (1-4) at any time, from the beat edges the feed brings,
// so a box can light when its beat is due, not when a packet happens to arrive. No board here: times are any
// millisecond clock, which may wrap.
#pragma once

#include <cstdint>

#ifndef DECK_PANEL_PREDICT_BEATS
#define DECK_PANEL_PREDICT_BEATS 1
#endif

namespace deck_core {

class BeatClock {
  public:
    /// How many beats past the last edge heard the clock shows when they're due. 1: the next beat lights on time,
    /// and if the master stops, at most one beat shows that didn't happen. 0: never past the last edge, as before
    /// #660. The owner chose 1 after seeing both on the panel (2026-11-21); -DDECK_PANEL_PREDICT_BEATS=0 builds the other.
    static constexpr int kPredictBeats = DECK_PANEL_PREDICT_BEATS;
    /// Tempos the clock believes, as a beat's length: 40-300 BPM.
    static constexpr uint32_t kShortestBeatMs = 200, kLongestBeatMs = 1500;

    /// The feed's beat arrived at `at_ms`: a new value is an edge; the same again (a keepalive) is none.
    void edge(int beat, uint32_t at_ms);
    /// The beat to show at `now_ms`, 1-4; 0 for none.
    int beat_at(uint32_t now_ms) const;
    /// The master clock's BPM (the feed's clockBpm, #674): with it, a beat's length is known from the first edge and
    /// only the beat's place is locked; a change applies at once. 0 (or out of range) is none: the edges give it.
    void set_tempo(float bpm);
    /// The master stopped: show the beat heard, nothing ahead, until beats come again.
    void stop() {
        period_ms_ = 0;
        stopped_ = true;
    }

    /// The lock (#660): arrivals jitter by a few ms (Wi-Fi, the sender), so each edge moves the clock only part of
    /// the way: kPhaseGain of its error, and the tempo kTempoGain of it, each error clipped to kMaxErrorMs so one late
    /// message barely moves the next beat. The first kAveragedEdges beats set the tempo as an average since the first.
    /// Tuned in a simulation of +-10 ms jitter at 128 BPM: after 16 edges, 3.8 ms off on average, 9 ms at the 95th
    /// percentile.
    static constexpr float kPhaseGain = 0.25f, kTempoGain = 0.05f, kMaxErrorMs = 10;
    static constexpr int kAveragedEdges = 4;
    /// An edge more than this many beats after the last starts the clock over: a gap, not a beat.
    static constexpr float kGapBeats = 1.5f;
    /// An edge further than this off the grid isn't jitter: the clock moves to it at once, keeping the tempo.
    static constexpr float kSnapMs = 40;

  private:
    void snap(int beat, uint32_t at_ms);

    int beat_ = 0;              ///< the last beat heard
    uint32_t edge_ms_ = 0;      ///< when it's taken to have started: its arrival, corrected by the lock
    float period_ms_ = 0;       ///< a beat's length; 0 until two edges in a row give it
    uint32_t first_ms_ = 0;     ///< the first edge of this run of beats in a row
    int edges_ = 0;             ///< beats in a row since first_ms_
    float tempo_ms_ = 0;        ///< a beat's length from the master clock's BPM; 0 for none
    bool stopped_ = false;      ///< stop() since the last edge: nothing ahead until beats come again
};

}  // namespace deck_core
