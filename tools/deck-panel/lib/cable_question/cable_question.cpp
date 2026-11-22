#include "cable_question.h"

namespace cable_question {

void CableQuestion::put(char c) {
    if (question_.feed(c)) asked_ = true;
}

void CableQuestion::answer() {
    if (!asked_) return;
    asked_ = false;
    // A newline first: whatever is on the line before ends, so the answer starts its own line (#754).
    char line[96];
    line[0] = '\n';
    build_info::answer_line(build_, line + 1, sizeof line - 1);
    write_(line);
}

}  // namespace cable_question
