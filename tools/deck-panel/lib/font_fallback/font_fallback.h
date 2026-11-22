// Text fitted to the panel's fonts (#620, #621): Geist, converted with printable ASCII, Latin-1 Supplement (U+00A0-
// U+00FF), Latin Extended-A (U+0100-U+017F) and "…". Any other character would draw as an empty box, so it is "?".
// The conversion's ranges (tools/deck-panel/fonts/) and these must match.
#pragma once

#include <cstddef>

namespace font_fallback {

/// `text` (valid UTF-8) fitted into `out`, at most `size - 1` bytes and a NUL, cut between characters.
void fit(const char* text, char* out, size_t size);

}  // namespace font_fallback
