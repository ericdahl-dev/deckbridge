#include "update_floor.h"

#include "update_session.h"

namespace update_floor {

std::string raised(const std::string& current, const std::string& pending) {
    if (!update_session::is_version(pending) || update_session::below(pending, current)) return current;
    return pending;
}

}  // namespace update_floor
