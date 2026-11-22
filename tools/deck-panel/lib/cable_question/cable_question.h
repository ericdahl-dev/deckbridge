// The version question over the USB cable (#695, #667): the cable's text outside the feed's SLIP frames, from
// serial_feed, goes to build_info's Question. A whole "version" line is answered through `write` at the next answer(),
// called from the loop's chores: put() runs inside the feed's drain, in the gap before the draw, where a print could
// wait on a full TX ring (firmware review).
#pragma once

#include "build_info.h"
#include "serial_feed.h"

namespace cable_question {

/// Writes one answer line (Serial.println on the board).
using Write = void (*)(const char* line);

class CableQuestion : public serial_feed::Text {
public:
    CableQuestion(const build_info::Build& build, Write write) : build_(build), write_(write) {}
    void put(char c) override;
    /// Writes the answer if a question came since the last call.
    void answer();

private:
    bool asked_ = false;
    const build_info::Build& build_;
    Write write_;
    build_info::Question question_;
};

}  // namespace cable_question
