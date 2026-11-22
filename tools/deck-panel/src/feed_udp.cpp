#include "feed_udp.h"

#include <Arduino.h>
#include <errno.h>
#include <lwip/sockets.h>
#include <sys/time.h>

#include "deck_core.h"
#include "feed_flags.h"

#if !FEED_RX_TASK && defined(PANEL_PERF_LOG)
// FEED_RX_TASK=0 (feed_flags.h): main's ledger stamps, at the same looks, for the old path (now on the raw socket).
#include <esp_timer.h>

#include "perf_log.h"

namespace {
uint32_t now_us() { return static_cast<uint32_t>(esp_timer_get_time()); }
}  // namespace
#endif

namespace {
/// Empty datagrams dropped in one look before it gives up until the next: each is read off, so the look ends.
constexpr int kMaxEmpty = 16;
}  // namespace

void FeedUdp::poll(bool connected, uint32_t joins, uint32_t now_ms) {
    if (!connected) {
        shut();
        return;
    }
    if (fd_ >= 0 && opened_for_ == joins) return;
    if (tried_ && opened_for_ == joins && now_ms - tried_ms_ < kRetryMs) return;
    // A rejoin can bring a new interface address: a fresh socket, not one bound before it.
    shut();
    tried_ = true;
    tried_ms_ = now_ms;
    opened_for_ = joins;
    const bool opened = open();
    Serial.printf("deck panel: feed port %u %s\n", unsigned(deck_core::DeckCore::kFeedPort),
                  opened ? "open" : "didn't open; retrying");
}

bool FeedUdp::open() {
    // socket(), setsockopt() and bind() are lwIP's, inline (lwip/sockets.h); no VFS between.
    const int fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (fd < 0) return false;
    const int yes = 1;
    sockaddr_in at = {};
    at.sin_family = AF_INET;
    at.sin_port = htons(deck_core::DeckCore::kFeedPort);
    at.sin_addr.s_addr = htonl(INADDR_ANY);
    if (setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof yes) < 0 ||
        bind(fd, reinterpret_cast<const sockaddr*>(&at), sizeof at) < 0) {
        lwip_close(fd);
        return false;
    }
    fd_ = fd;
    pending_ = 0;
    return true;
}

void FeedUdp::shut() {
    if (fd_ < 0) return;
    lwip_close(fd_);
    fd_ = -1;
    pending_ = 0;
}

bool FeedUdp::wait(uint32_t timeout_ms) {
    if (fd_ < 0) {
        vTaskDelay(pdMS_TO_TICKS(timeout_ms));
        return false;
    }
    if (pending_ > 0) return true;  // peeked, not yet taken
    fd_set readable;
    FD_ZERO(&readable);
    FD_SET(fd_, &readable);
    timeval limit = {};
    limit.tv_sec = static_cast<time_t>(timeout_ms / 1000);
    limit.tv_usec = static_cast<suseconds_t>((timeout_ms % 1000) * 1000);
    // lwip_select(), not select(): VFS's select() wraps it with a heap allocation and a scan of every VFS, each call,
    // for one lwIP descriptor. It sleeps on a semaphore lwIP's own task gives when a datagram lands, so it wakes at
    // the arrival, and at worst after `timeout_ms` (rounded to ticks).
    const int ready = lwip_select(fd_ + 1, &readable, nullptr, nullptr, &limit);
    if (ready > 0) return true;
    if (ready == 0) return false;
    Serial.printf("deck panel: feed port wait failed (errno %d); reopening\n", errno);
    // Shut, so poll() reopens it a retry later; sleep, so a failure that comes back at once can't spin.
    shut();
    vTaskDelay(pdMS_TO_TICKS(timeout_ms));
    return false;
}

size_t FeedUdp::next_size() {
    if (fd_ < 0) return 0;
    for (int empty = 0; pending_ == 0 && empty < kMaxEmpty;) {
        // Peeks: lwIP keeps the datagram (its lastdata) for read() or skip() to take. Not FIONREAD: in this lwIP
        // (LWIP_FIONREAD_LINUXMODE 0) it's every queued datagram's bytes together, not the next one's size.
        const ssize_t got = recvfrom(fd_, peek_, sizeof peek_, MSG_PEEK | MSG_DONTWAIT, nullptr, nullptr);
        if (got < 0) {
            if (errno == EWOULDBLOCK || errno == EAGAIN) return 0;  // none waiting
            // Anything else would come back at every wake with select() saying ready: shut, poll() reopens it.
            Serial.printf("deck panel: feed port read failed (errno %d); reopening\n", errno);
            shut();
            return 0;
        }
        if (got == 0) {
            // An empty datagram: 0 here means "none" to the drain and the intake, so take it off, or it would sit
            // at the head with select() saying ready, and the task would spin on it.
            recvfrom(fd_, peek_, 1, MSG_DONTWAIT, nullptr, nullptr);
            ++empty;
            continue;
        }
        pending_ = static_cast<size_t>(got);  // sizeof peek_ means bigger than kMaxDatagram: the caller skips it
#if !FEED_RX_TASK && defined(PANEL_PERF_LOG)
        // The first look that finds it, for the frame ledger (#662). Only the drain looks, right before it reads, so
        // this is the read's time to within microseconds, not its arrival: it trails that by the time since the
        // last drain (about a frame).
        perf_log::feed_seen(now_us());
#endif
    }
    return pending_;
}

size_t FeedUdp::read(uint8_t* into, size_t room) {
    if (fd_ < 0) return 0;
    // Straight into the caller's slot. Whatever didn't fit goes too: one datagram is one message.
    const ssize_t got = recvfrom(fd_, into, room, MSG_DONTWAIT, nullptr, nullptr);
    pending_ = 0;
#if !FEED_RX_TASK && defined(PANEL_PERF_LOG)
    if (got > 0) perf_log::feed_read(now_us());
#endif
    return got > 0 ? static_cast<size_t>(got) : 0;
}

void FeedUdp::skip() {
    if (fd_ < 0) return;
    // One byte read takes the whole datagram off: lwIP drops what a UDP read doesn't take.
    uint8_t scratch;
    recvfrom(fd_, &scratch, sizeof scratch, MSG_DONTWAIT, nullptr, nullptr);
    pending_ = 0;
}
