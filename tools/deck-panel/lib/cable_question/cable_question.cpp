#include "cable_question.h"

namespace cable_question {

void CableQuestion::put(char c) {
    if (!question_.feed(c)) return;
    char line[96];
    build_info::answer_line(build_, line, sizeof line);
    write_(line);
}

}  // namespace cable_question
