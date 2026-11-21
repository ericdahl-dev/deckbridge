// The panel's side of the update connection (#690): one TCP connection at a time, framed bytes in, one text line per
// step out. The protocol is in docs/DECK-PANEL-UPDATE-PROTOCOL.md; the board's task owns the socket and calls this.
//
// A frame is one type byte, a 4-byte little-endian length, then that many bytes:
//   'M' manifest (at most kMaxManifest), 'S' signature (64), 'I' image chunk (at most kMaxChunk), 'D' done (0).
#pragma once

#include <cstddef>
#include <cstdint>
#include <optional>
#include <string>
#include <vector>

#include "update_session.h"

namespace update_link {

constexpr size_t kMaxManifest = 32 * 1024;
constexpr size_t kMaxChunk = 4096;
constexpr uint32_t kIdleBeforeManifestMs = 3000;  ///< a stray connection can't hold "busy" for long
constexpr uint32_t kIdleMidImageMs = 10000;

struct Out {
    std::vector<std::string> lines;  ///< to send, each followed by "\n"
    bool close = false;              ///< close the connection after sending
    bool reboot = false;             ///< a new image is set to boot: restart into it after closing
    std::string floor;               ///< with reboot: the floor to keep once the new image confirms itself
};

class Link {
  public:
    explicit Link(const update_session::Config& config) : config_(config) {}

    /// A new connection. False while one is running: send `out.lines` and close it.
    bool accept(int connection, uint32_t now_ms, Out& out);
    /// Bytes from `connection`, in any split.
    Out received(int connection, const uint8_t* bytes, size_t length, uint32_t now_ms);
    /// Time passing with nothing received: ends an idle connection.
    Out tick(uint32_t now_ms);
    /// The connection went away.
    void closed(int connection);

  private:
    void handle(const update_session::Reply& reply, Out& out);
    void finish(Out& out);

    update_session::Config config_;
    std::optional<update_session::Session> session_;
    int connection_ = -1;
    uint32_t last_ms_ = 0;
    uint8_t header_[5] = {};
    size_t header_have_ = 0;
    std::vector<uint8_t> payload_;
    uint32_t payload_want_ = 0;
};

/// The text line for a reply, as the app reads it.
std::string line(const update_session::Reply& reply);

}  // namespace update_link
