// One update over Wi-Fi (#690), driven frame by frame with a fake signature check, hash and slot.
#include <unity.h>

#include <cstring>
#include <string>
#include <vector>

#include "update_session.h"

using namespace update_session;

namespace {

// The fake signature check: a signature is "valid" when it is the key's first byte, then the message length, then 0s.
bool fake_verify(const uint8_t key[32], const uint8_t*, size_t length, const uint8_t signature[64]) {
    return signature[0] == key[0] && signature[1] == static_cast<uint8_t>(length);
}

std::vector<uint8_t> signed_by(uint8_t key_first, size_t length) {
    std::vector<uint8_t> signature(64, 0);
    signature[0] = key_first;
    signature[1] = static_cast<uint8_t>(length);
    return signature;
}

const TrustedKey kKeys[] = {{"primary", {0x11}}, {"backup", {0x22}}};

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
    bool begin(uint32_t size) override { begun = true; erased = size; return true; }
    bool write(const uint8_t* data, size_t length) override { written.insert(written.end(), data, data + length); return true; }
    bool end() override { ended = true; return true; }
    bool set_boot() override { boot = true; return true; }
    void abort() override { aborted = true; }
    bool begun = false, ended = false, boot = false, aborted = false;
    uint32_t erased = 0;
    std::vector<uint8_t> written;
};

std::string manifest_text(const char* key = "primary", const char* version = "1.1.0", uint32_t size = 4,
                          const char* lowest = "1.0.0", int format = 1) {
    // The fake hash of {1, 2, 3, 4} is 10: 0a, then 31 zero bytes.
    return std::string("{\"format\": ") + std::to_string(format) + ", \"key\": \"" + key +
           "\", \"lowest_allowed\": {\"deck-panel\": \"" + lowest +
           "\"}, \"files\": [{\"device\": \"deck-panel\", \"name\": \"p.bin\", \"version\": \"" + version +
           "\", \"size\": " + std::to_string(size) + ", \"sha256\": \"0a" + std::string(62, '0') + "\"}]}";
}

struct Panel {
    FakeHasher hasher;
    FakeSlot slot;
    Session session{Config{kKeys, 2, fake_verify, &hasher, &slot, "1.0.0"}};

    Reply send_manifest(const std::string& text, uint8_t key_first) {
        Reply first = session.manifest(reinterpret_cast<const uint8_t*>(text.data()), text.size());
        if (first.kind == Reply::refused) return first;
        const auto signature = signed_by(key_first, text.size());
        return session.signature(signature.data(), signature.size());
    }
};

void test_a_manifest_signed_by_a_trusted_key_is_taken() {
    Panel panel;
    TEST_ASSERT_EQUAL(Reply::ok_manifest, panel.send_manifest(manifest_text(), 0x11).kind);
}

void test_the_backup_key_is_trusted_too() {
    Panel panel;
    TEST_ASSERT_EQUAL(Reply::ok_manifest, panel.send_manifest(manifest_text("backup"), 0x22).kind);
}

void test_a_manifest_naming_a_key_the_panel_does_not_trust_is_refused_and_the_slot_untouched() {
    Panel panel;
    const Reply reply = panel.send_manifest(manifest_text("someone-else"), 0x11);
    TEST_ASSERT_EQUAL(Reply::refused, reply.kind);
    TEST_ASSERT_EQUAL(static_cast<int>(Refusal::unknown_key), static_cast<int>(reply.refusal));
    TEST_ASSERT_FALSE(panel.slot.begun);
}

void test_a_bad_signature_is_refused_and_the_slot_untouched() {
    Panel panel;
    const Reply reply = panel.send_manifest(manifest_text(), 0x22);  // the backup's signature, claiming the primary
    TEST_ASSERT_EQUAL(static_cast<int>(Refusal::bad_signature), static_cast<int>(reply.refusal));
    TEST_ASSERT_FALSE(panel.slot.begun);
}

const uint8_t kImage[] = {1, 2, 3, 4};

// Nothing reaches the slot unless a signed manifest came first: image bytes, "done" or a lone signature are refused.
void test_image_bytes_before_a_signed_manifest_are_refused_and_never_written() {
    Panel panel;
    TEST_ASSERT_EQUAL(static_cast<int>(Refusal::no_manifest), static_cast<int>(panel.session.chunk(kImage, 4).refusal));
    TEST_ASSERT_FALSE(panel.slot.begun);
    TEST_ASSERT_TRUE(panel.slot.written.empty());
}

void test_done_or_a_signature_before_a_manifest_is_refused() {
    Panel a;
    TEST_ASSERT_EQUAL(static_cast<int>(Refusal::no_manifest), static_cast<int>(a.session.done().refusal));
    Panel b;
    const auto signature = signed_by(0x11, 0);
    TEST_ASSERT_EQUAL(static_cast<int>(Refusal::no_manifest), static_cast<int>(b.session.signature(signature.data(), 64).refusal));
    TEST_ASSERT_FALSE(a.slot.begun || b.slot.begun);
}

void test_image_bytes_after_a_refused_manifest_are_refused_too() {
    Panel panel;
    panel.send_manifest(manifest_text(), 0x22);
    TEST_ASSERT_EQUAL(static_cast<int>(Refusal::no_manifest), static_cast<int>(panel.session.chunk(kImage, 4).refusal));
    TEST_ASSERT_TRUE(panel.slot.written.empty());
}

void test_an_image_matching_the_manifest_is_written_and_set_to_boot() {
    Panel panel;
    panel.send_manifest(manifest_text(), 0x11);
    TEST_ASSERT_TRUE(panel.slot.begun);
    TEST_ASSERT_EQUAL_UINT32(4, panel.slot.erased);  // only the image's own size is erased
    const Reply first = panel.session.chunk(kImage, 3);
    TEST_ASSERT_EQUAL(Reply::progress, first.kind);
    TEST_ASSERT_EQUAL_UINT32(3, first.bytes);
    TEST_ASSERT_EQUAL_UINT32(4, panel.session.chunk(kImage + 3, 1).bytes);
    const Reply last = panel.session.done();
    TEST_ASSERT_EQUAL(Reply::switched, last.kind);
    TEST_ASSERT_EQUAL_STRING("1.1.0", last.version.c_str());
    TEST_ASSERT_EQUAL_UINT8_ARRAY(kImage, panel.slot.written.data(), 4);
    TEST_ASSERT_TRUE(panel.slot.ended);
    TEST_ASSERT_TRUE(panel.slot.boot);
}

void expect_mismatch(Panel& panel, const Reply& reply) {
    TEST_ASSERT_EQUAL(static_cast<int>(Refusal::mismatch), static_cast<int>(reply.refusal));
    TEST_ASSERT_TRUE(panel.slot.aborted);
    TEST_ASSERT_FALSE(panel.slot.boot);
}

void test_an_altered_image_is_refused_and_never_booted() {
    Panel panel;
    panel.send_manifest(manifest_text(), 0x11);
    const uint8_t altered[] = {1, 2, 3, 5};
    panel.session.chunk(altered, 4);
    expect_mismatch(panel, panel.session.done());
}

void test_an_image_cut_short_is_refused_and_never_booted() {
    Panel panel;
    panel.send_manifest(manifest_text(), 0x11);
    panel.session.chunk(kImage, 3);
    expect_mismatch(panel, panel.session.done());
}

void test_an_image_longer_than_the_manifest_says_is_refused_at_the_first_extra_byte() {
    Panel panel;
    panel.send_manifest(manifest_text(), 0x11);
    panel.session.chunk(kImage, 4);
    const uint8_t extra = 0;
    expect_mismatch(panel, panel.session.chunk(&extra, 1));
    TEST_ASSERT_EQUAL(4, panel.slot.written.size());
}

}  // namespace

int main() {
    UNITY_BEGIN();
    RUN_TEST(test_a_manifest_signed_by_a_trusted_key_is_taken);
    RUN_TEST(test_the_backup_key_is_trusted_too);
    RUN_TEST(test_a_manifest_naming_a_key_the_panel_does_not_trust_is_refused_and_the_slot_untouched);
    RUN_TEST(test_a_bad_signature_is_refused_and_the_slot_untouched);
    RUN_TEST(test_image_bytes_before_a_signed_manifest_are_refused_and_never_written);
    RUN_TEST(test_done_or_a_signature_before_a_manifest_is_refused);
    RUN_TEST(test_image_bytes_after_a_refused_manifest_are_refused_too);
    RUN_TEST(test_an_image_matching_the_manifest_is_written_and_set_to_boot);
    RUN_TEST(test_an_altered_image_is_refused_and_never_booted);
    RUN_TEST(test_an_image_cut_short_is_refused_and_never_booted);
    RUN_TEST(test_an_image_longer_than_the_manifest_says_is_refused_at_the_first_extra_byte);
    return UNITY_END();
}
