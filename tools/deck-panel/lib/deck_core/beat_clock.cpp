#include "beat_clock.h"

#include <cmath>

namespace deck_core {

namespace {

int next(int beat) { return beat % 4 + 1; }

}  // namespace

void BeatClock::edge(int beat, uint32_t at_ms) {
    if (beat < 1 || beat > 4) {
        beat_ = 0;
        period_ms_ = 0;
        return;
    }
    if (beat == beat_) return;  // a keepalive
    // The first beat after a stop starts a new run: the time since the last before it is the pause, not a beat (#718).
    const bool resumed = stopped_;
    stopped_ = false;
    // Unsigned difference: the clock wrapping is no jump.
    const float since_last = static_cast<float>(at_ms - edge_ms_);
    // Too long since the last for one beat: a gap (the master stopped, or the feed went quiet), not a beat length.
    const bool gap = since_last > (period_ms_ > 0 ? kGapBeats * period_ms_ : static_cast<float>(kLongestBeatMs));
    if (beat_ != 0 && !gap && period_ms_ > 0 && beat != next(beat_)) {
        snap(beat, at_ms);  // out of turn: a cue jump on the master
        return;
    }
    if (beat_ == 0 || beat != next(beat_) || gap || resumed) {
        // A first beat, not the next one, or the first after a stop: a new run starts here.
        beat_ = beat;
        edge_ms_ = first_ms_ = at_ms;
        edges_ = 0;
        period_ms_ = tempo_ms_;  // known from the BPM, or 0 until the next edge
        return;
    }
    beat_ = beat;
    ++edges_;
    if (period_ms_ == 0) {
        if (since_last >= kShortestBeatMs && since_last <= kLongestBeatMs) period_ms_ = since_last;
        edge_ms_ = at_ms;
        return;
    }
    float error = since_last - period_ms_;
    if (std::fabs(error) > kSnapMs) {
        snap(beat, at_ms);  // in turn but far off the grid: a loop wrapping, a jump
        return;
    }
    if (error > kMaxErrorMs) error = kMaxErrorMs;
    if (error < -kMaxErrorMs) error = -kMaxErrorMs;
    edge_ms_ += static_cast<uint32_t>(static_cast<int32_t>(std::lround(period_ms_ + kPhaseGain * error)));
    if (tempo_ms_ > 0) {
        period_ms_ = tempo_ms_;  // the BPM's, never the edges'
    } else if (edges_ <= kAveragedEdges) {
        period_ms_ = static_cast<float>(at_ms - first_ms_) / static_cast<float>(edges_);
    } else {
        period_ms_ += kTempoGain * error;
    }
}

void BeatClock::set_tempo(float bpm) {
    const float ms = bpm > 0 ? 60000.0f / bpm : 0;
    tempo_ms_ = ms >= kShortestBeatMs && ms <= kLongestBeatMs ? ms : 0;
    // A beat heard and not stopped: the new length from now, the first edge's too. Stopped, the next edge takes it.
    if (tempo_ms_ > 0 && beat_ != 0 && !stopped_) period_ms_ = tempo_ms_;
}

void BeatClock::snap(int beat, uint32_t at_ms) {
    // The beat as heard, from now; the tempo holds, and from here on only the lock moves it.
    beat_ = beat;
    edge_ms_ = at_ms;
    if (edges_ < kAveragedEdges) edges_ = kAveragedEdges;
}

int BeatClock::beat_at(uint32_t now_ms) const {
    if (beat_ == 0 || period_ms_ == 0) return beat_;
    const int32_t since = static_cast<int32_t>(now_ms + lead_ms_ - edge_ms_);
    if (since <= 0) return beat_;
    uint32_t ahead = static_cast<uint32_t>(static_cast<float>(since) / period_ms_);
    if (ahead > static_cast<uint32_t>(kPredictBeats)) ahead = kPredictBeats;
    int beat = beat_;
    for (uint32_t i = 0; i < ahead; ++i) beat = next(beat);
    return beat;
}

}  // namespace deck_core
