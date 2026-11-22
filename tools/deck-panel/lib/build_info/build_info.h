// The panel's build, as the updater reads it (#695). The version is from VERSION and the SHA from git, both set at
// build time by git_sha.py; `release` is true only for a clean build on its deck-panel-v<version> tag.
#pragma once

#include <cstddef>

namespace build_info {

struct Build {
    const char* version;  ///< dotted digits, such as "1.2.0"
    const char* sha;      ///< the short commit, "-dirty" with uncommitted changes
    bool release;
};

/// The serial boot line: "deck panel: boot, build <sha>, version <v>", " local" after a local build's version.
void boot_line(const Build& b, char* out, size_t n);
/// The answer to a version question, the boot line without "boot, ".
void answer_line(const Build& b, char* out, size_t n);
/// The waiting screen's small line: "v<version>  <sha>", " local" after a local build's version.
void label(const Build& b, char* out, size_t n);

/// The version question over serial: fed the bytes as they arrive, true once for each whole line that is exactly
/// "version" (ended by CR, LF or CR LF). Any other line, or one too long to be the question, is dropped whole.
class Question {
public:
    bool feed(char c);

private:
    static constexpr size_t kMax = 16;
    char line_[kMax] = {};
    size_t len_ = 0;  ///< stops at kMax, so a longer line never matches
};

}  // namespace build_info
