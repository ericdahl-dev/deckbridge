// The version question over the USB cable (#695, #667): the cable's text outside the feed's SLIP frames, from
// serial_feed, goes to build_info's Question, and each whole "version" line is answered through `write`.
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

private:
    const build_info::Build& build_;
    Write write_;
    build_info::Question question_;
};

}  // namespace cable_question
