// The panel's floor (#690, docs/DECK-PANEL-UPDATE-PROTOCOL.md): the lowest version it takes over Wi-Fi. The board keeps
// it in NVS; this says what to keep when a new image confirms itself with the floor its manifest asked for.
#pragma once

#include <string>

namespace update_floor {

/// The floor to keep: `pending` when it is a version not below `current`, else `current`. Never lower, and never
/// something that isn't a version (that would count every version below it and refuse every update for good).
std::string raised(const std::string& current, const std::string& pending);

}  // namespace update_floor
