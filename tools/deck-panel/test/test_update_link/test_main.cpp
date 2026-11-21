// The update connection (#690): framed bytes in, text lines out, one connection at a time, idle timeouts.
#include <unity.h>

#include <cstring>
#include <string>
#include <vector>

#include "update_link.h"

using namespace update_session;
using update_link::Link;
using update_link::Out;

namespace {

bool fake_verify(const uint8_t key[32], const uint8_t*, size_t, const uint8_t signature[64]) { return signature[0] == key[0]; }

const TrustedKey kKeys[] = {{"primary", {0x11}}};

class FakeHasher : public Hasher {
  public:
    void start() override { sum_ = 0; }
    void update(const uint8_t* data, size_t length) override { for (size_t i = 0; i < length; ++i) sum_ += data[i]; }
    void finish(uint8_t out[32]) override { std::memset(out, 0, 32); out[0] = static_cast<uint8_t>(sum_); }
  private:
    unsigned sum_ = 0;
};

class FakeSlot : public Slot {
  public:
    uint32_t capacity() const override { return 6553600; }
    bool begin(uint32_t) override { begun = true; return true; }
    bool write(const uint8_t* data, size_t length) override { written.insert(written.end(), data, data + length); return true; }
    bool end() override { return true; }
    bool set_boot() override { boot = true; return true; }
    void abort() override { aborted = true; }
    bool begun = false, boot = false, aborted = false;
    std::vector<uint8_t> written;
};

const std::string kManifest = std::string("{\"format\": 1, \"key\": \"primary\", \"lowest_allowed\": {\"deck-panel\": \"1.0.0\"}, ") +
    "\"files\": [{\"device\": \"deck-panel\", \"name\": \"p.bin\", \"version\": \"1.1.0\", \"size\": 4, \"sha256\": \"0a" +
    std::string(62, '0') + "\"}]}";

std::vector<uint8_t> frame(char type, const std::vector<uint8_t>& payload) {
    std::vector<uint8_t> out{static_cast<uint8_t>(type)};
    const uint32_t n = static_cast<uint32_t>(payload.size());
    for (int i = 0; i < 4; ++i) out.push_back(static_cast<uint8_t>(n >> (8 * i)));
    out.insert(out.end(), payload.begin(), payload.end());
    return out;
}

std::vector<uint8_t> whole_update() {
    std::vector<uint8_t> bytes = frame('M', std::vector<uint8_t>(kManifest.begin(), kManifest.end()));
    std::vector<uint8_t> signature(64, 0);
    signature[0] = 0x11;
    for (const auto& f : {frame('S', signature), frame('I', {1, 2, 3, 4}), frame('D', {})}) bytes.insert(bytes.end(), f.begin(), f.end());
    return bytes;
}

struct Panel {
    FakeHasher hasher;
    FakeSlot slot;
    Link link{Config{kKeys, 1, fake_verify, &hasher, &slot, "1.0.0"}};
};

std::vector<std::string> lines_of(const std::vector<Out>& outs) {
    std::vector<std::string> all;
    for (const auto& out : outs) all.insert(all.end(), out.lines.begin(), out.lines.end());
    return all;
}

void test_a_whole_update_in_one_go_switches_and_asks_for_a_restart() {
    Panel panel;
    Out out;
    TEST_ASSERT_TRUE(panel.link.accept(1, 0, out));
    const auto bytes = whole_update();
    out = panel.link.received(1, bytes.data(), bytes.size(), 10);
    const std::vector<std::string> expected{"ok manifest", "progress 4", "ok switched 1.1.0"};
    TEST_ASSERT_EQUAL(expected.size(), out.lines.size());
    for (size_t i = 0; i < expected.size(); ++i) TEST_ASSERT_EQUAL_STRING(expected[i].c_str(), out.lines[i].c_str());
    TEST_ASSERT_TRUE(out.close);
    TEST_ASSERT_TRUE(out.reboot);
    TEST_ASSERT_EQUAL_STRING("1.0.0", out.floor.c_str());
}

void test_the_same_update_a_byte_at_a_time_gives_the_same_lines() {
    Panel panel;
    Out out;
    panel.link.accept(1, 0, out);
    std::vector<Out> outs;
    for (uint8_t byte : whole_update()) outs.push_back(panel.link.received(1, &byte, 1, 10));
    const auto all = lines_of(outs);
    TEST_ASSERT_EQUAL(3, all.size());
    TEST_ASSERT_EQUAL_STRING("ok switched 1.1.0", all.back().c_str());
    TEST_ASSERT_TRUE(outs.back().reboot);
}

Out connected_and_sent(Panel& panel, const std::vector<uint8_t>& bytes) {
    Out out;
    panel.link.accept(1, 0, out);
    return panel.link.received(1, bytes.data(), bytes.size(), 10);
}

void expect_refused(const Out& out, const char* expected) {
    TEST_ASSERT_EQUAL(1, out.lines.size());
    TEST_ASSERT_EQUAL_STRING(expected, out.lines[0].c_str());
    TEST_ASSERT_TRUE(out.close);
    TEST_ASSERT_FALSE(out.reboot);
}

// The caps are checked from the frame's header, before its bytes are kept: no one can make the panel buffer more.
void test_a_manifest_frame_over_the_cap_is_refused_from_its_header() {
    Panel panel;
    std::vector<uint8_t> header{'M', 0, 0, 0, 0};
    const uint32_t n = update_link::kMaxManifest + 1;
    for (int i = 0; i < 4; ++i) header[1 + i] = static_cast<uint8_t>(n >> (8 * i));
    expect_refused(connected_and_sent(panel, header), "refused too-large");
}

void test_an_image_chunk_over_the_cap_is_refused_and_nothing_is_written() {
    Panel panel;
    auto bytes = whole_update();
    bytes.resize(bytes.size() - 2 * 5 - 4);  // up to the signature: then a chunk over the cap
    std::vector<uint8_t> header{'I', 0, 0, 0, 0};
    const uint32_t n = update_link::kMaxChunk + 1;
    for (int i = 0; i < 4; ++i) header[1 + i] = static_cast<uint8_t>(n >> (8 * i));
    bytes.insert(bytes.end(), header.begin(), header.end());
    Out out;
    panel.link.accept(1, 0, out);
    out = panel.link.received(1, bytes.data(), bytes.size(), 10);
    TEST_ASSERT_EQUAL_STRING("refused too-large", out.lines.back().c_str());
    TEST_ASSERT_TRUE(panel.slot.written.empty());
    TEST_ASSERT_TRUE(panel.slot.aborted);
}

void test_a_signature_frame_that_is_not_64_bytes_is_refused() {
    Panel panel;
    auto bytes = frame('M', std::vector<uint8_t>(kManifest.begin(), kManifest.end()));
    const auto signature = frame('S', std::vector<uint8_t>(65, 0x11));
    bytes.insert(bytes.end(), signature.begin(), signature.end());
    expect_refused(connected_and_sent(panel, bytes), "refused too-large");
}

void test_a_frame_of_an_unknown_type_is_refused() {
    Panel panel;
    expect_refused(connected_and_sent(panel, frame('X', {1})), "refused no-manifest");
}

}  // namespace

int main() {
    UNITY_BEGIN();
    RUN_TEST(test_a_whole_update_in_one_go_switches_and_asks_for_a_restart);
    RUN_TEST(test_the_same_update_a_byte_at_a_time_gives_the_same_lines);
    RUN_TEST(test_a_manifest_frame_over_the_cap_is_refused_from_its_header);
    RUN_TEST(test_an_image_chunk_over_the_cap_is_refused_and_nothing_is_written);
    RUN_TEST(test_a_signature_frame_that_is_not_64_bytes_is_refused);
    RUN_TEST(test_a_frame_of_an_unknown_type_is_refused);
    return UNITY_END();
}
