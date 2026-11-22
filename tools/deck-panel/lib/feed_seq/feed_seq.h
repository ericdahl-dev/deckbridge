// The feed's sequence number (#750): DeckBridge numbers every bundle (`/DeckBridge/Display/seq`), and the panel counts
// the numbers it never saw. Kept free of Arduino so it's host-tested.
#pragma once

#include <cstdint>

namespace feed_seq {

/// One source's count (Wi-Fi's UDP, or the USB cable): the datagrams lost between the ones it saw.
class Counter {
  public:
    /// At most this far behind the last, and not 1, a number is a late datagram, not a restart (#750's review).
    static constexpr uint32_t kLate = 8;

    /// A bundle numbered `seq` came.
    void saw(uint32_t seq);
    /// The next number starts a new count (the feed was quiet): a baseline, not a gap.
    void restart() { seen_ = false; }
    /// Datagrams missing since boot.
    uint32_t lost() const;
    /// A numbered bundle has come at least once: a DeckBridge from before #750 sends none.
    bool seen() const;

  private:
    bool seen_ = false;
    uint32_t last_ = 0;
    uint32_t lost_ = 0;
};

}  // namespace feed_seq
