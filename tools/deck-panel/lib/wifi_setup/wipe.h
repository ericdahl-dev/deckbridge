// Zeroing password copies (#622) by writes through a volatile pointer, which the compiler can't drop as dead stores
// the way it may drop a memset just before a buffer goes out of scope.
#pragma once

#include <cstddef>

namespace wifi_setup {

inline void wipe(void* p, size_t n) {
    volatile unsigned char* b = static_cast<volatile unsigned char*>(p);
    while (n--) *b++ = 0;
}

// Wipes a buffer on every way out of a scope, early returns included.
class WipeOnExit {
  public:
    WipeOnExit(void* p, size_t n) : p_(p), n_(n) {}
    ~WipeOnExit() { wipe(p_, n_); }
    WipeOnExit(const WipeOnExit&) = delete;
    WipeOnExit& operator=(const WipeOnExit&) = delete;

  private:
    void* p_;
    size_t n_;
};

}  // namespace wifi_setup
