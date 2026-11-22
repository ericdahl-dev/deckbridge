#include "cable_question.h"

namespace cable_question {

void CableQuestion::put(char c) {
    if (question_.feed(c)) asked_ = true;
}

void CableQuestion::answer() {
    if (!asked_) return;
    asked_ = false;
    char line[96];
    build_info::answer_line(build_, line, sizeof line);
    write_(line);
}

}  // namespace cable_question
