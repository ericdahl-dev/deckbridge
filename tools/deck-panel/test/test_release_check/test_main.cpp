// The panel's Ed25519 check (#690, ADR 0012) against the two vectors the updater checks too (#689): RFC 8032 TEST 1,
// and the randomized CryptoKit signature in the updater's own fixture file, read from it here so the two can't drift.
#include <unity.h>

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include "release_check.h"
#include "update_session.h"

namespace {

std::vector<uint8_t> hex(const std::string& text) {
    std::vector<uint8_t> out;
    for (size_t i = 0; i + 1 < text.size(); i += 2) out.push_back(static_cast<uint8_t>(std::stoi(text.substr(i, 2), nullptr, 16)));
    return out;
}

// The value of "key" in the fixture's flat JSON object of strings.
std::string field(const std::string& json, const std::string& key) {
    const size_t at = json.find("\"" + key + "\"");
    const size_t open = json.find('"', json.find(':', at) + 1);
    return json.substr(open + 1, json.find('"', open + 1) - open - 1);
}

void test_the_rfc_8032_test_vector_verifies_and_a_changed_message_does_not() {
    const auto key = hex("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a");
    const auto sig = hex("e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b");
    TEST_ASSERT_TRUE(release_check::signature_ok(key.data(), nullptr, 0, sig.data()));
    const uint8_t one = 0;
    TEST_ASSERT_FALSE(release_check::signature_ok(key.data(), &one, 1, sig.data()));
}

void test_the_updaters_cryptokit_vector_verifies_and_a_one_bit_flip_does_not() {
    FILE* file = std::fopen("../../Packages/FirmwareUpdaterKit/Tests/FirmwareReleaseTests/Fixtures/cryptokit-ed25519.json", "r");
    TEST_ASSERT_NOT_NULL_MESSAGE(file, "the updater's shared vector file");
    std::string json;
    char buffer[512];
    for (size_t n; (n = std::fread(buffer, 1, sizeof buffer, file)) > 0;) json.append(buffer, n);
    std::fclose(file);
    const auto key = hex(field(json, "public_key"));
    const auto message = hex(field(json, "message"));
    auto sig = hex(field(json, "signature"));
    TEST_ASSERT_EQUAL(32, key.size());
    TEST_ASSERT_EQUAL(64, sig.size());
    TEST_ASSERT_TRUE(release_check::signature_ok(key.data(), message.data(), message.size(), sig.data()));
    sig[0] ^= 1;
    TEST_ASSERT_FALSE(release_check::signature_ok(key.data(), message.data(), message.size(), sig.data()));
}

std::string hex_of(const uint8_t* bytes, size_t length) {
    std::string out;
    char pair[3];
    for (size_t i = 0; i < length; ++i) {
        std::snprintf(pair, sizeof pair, "%02x", bytes[i]);
        out += pair;
    }
    return out;
}

// FIPS 180-2 appendix B.1 and B.2, fed in uneven pieces, then the same hasher started again on the empty string.
void test_sha256_of_an_image_fed_in_pieces_matches_the_fips_vectors_and_start_begins_again() {
    release_check::Sha256 hasher;
    uint8_t digest[32];
    hasher.start();
    hasher.update(reinterpret_cast<const uint8_t*>("a"), 1);
    hasher.update(reinterpret_cast<const uint8_t*>("bc"), 2);
    hasher.finish(digest);
    TEST_ASSERT_EQUAL_STRING("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", hex_of(digest, 32).c_str());

    const char* two_blocks = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq";
    hasher.start();
    hasher.update(reinterpret_cast<const uint8_t*>(two_blocks), 7);
    hasher.update(reinterpret_cast<const uint8_t*>(two_blocks) + 7, 49);
    hasher.finish(digest);
    TEST_ASSERT_EQUAL_STRING("248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1", hex_of(digest, 32).c_str());

    hasher.start();
    hasher.update(reinterpret_cast<const uint8_t*>("abc"), 3);
    hasher.start();
    hasher.finish(digest);
    TEST_ASSERT_EQUAL_STRING("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", hex_of(digest, 32).c_str());
}

class MemorySlot : public update_session::Slot {
  public:
    uint32_t capacity() const override { return 6553600; }
    bool begin(uint32_t) override { return true; }
    bool write(const uint8_t* data, size_t length) override { written.insert(written.end(), data, data + length); return true; }
    bool end() override { return true; }
    bool set_boot() override { boot = true; return true; }
    void abort() override {}
    bool boot = false;
    std::vector<uint8_t> written;
};

// One whole update through the session with the real checks: a manifest signed with a key made here from a fixed
// test seed (never a release key), and a 10,000-byte image sent in the link's 4 KB chunks.
struct RealUpdate {
    uint8_t public_key[32];
    uint8_t secret_key[64];
    std::vector<uint8_t> image;
    std::string manifest;

    RealUpdate() : image(10000) {
        TEST_ASSERT_TRUE(sodium_init() >= 0);
        const std::vector<uint8_t> seed(32, 0x42);
        crypto_sign_seed_keypair(public_key, secret_key, seed.data());
        for (size_t i = 0; i < image.size(); ++i) image[i] = static_cast<uint8_t>(i * 7 + 3);
        uint8_t digest[32];
        crypto_hash_sha256(digest, image.data(), image.size());
        manifest = "{\"format\": 1, \"key\": \"primary\", \"lowest_allowed\": {\"deck-panel\": \"1.0.0\"}, \"files\": "
                   "[{\"device\": \"deck-panel\", \"name\": \"p.bin\", \"version\": \"1.2.0\", \"size\": 10000, "
                   "\"sha256\": \"" + hex_of(digest, 32) + "\"}]}";
    }

    // Signs the manifest, then sends `sent` (the manifest, or a changed copy) and `payload`; the last reply.
    update_session::Reply run(MemorySlot& slot, const std::string& sent, const std::vector<uint8_t>& payload) {
        uint8_t signature[64];
        crypto_sign_detached(signature, nullptr, reinterpret_cast<const uint8_t*>(manifest.data()), manifest.size(), secret_key);
        update_session::TrustedKey keys[1] = {{"primary", {}}};
        std::memcpy(keys[0].public_key, public_key, 32);
        release_check::Sha256 hasher;
        update_session::Session session(
            update_session::Config{keys, 1, release_check::signature_ok, &hasher, &slot, "1.0.0"});
        update_session::Reply reply = session.manifest(reinterpret_cast<const uint8_t*>(sent.data()), sent.size());
        if (reply.kind == update_session::Reply::refused) return reply;
        reply = session.signature(signature, sizeof signature);
        if (reply.kind == update_session::Reply::refused) return reply;
        for (size_t at = 0; at < payload.size(); at += 4096) {
            reply = session.chunk(payload.data() + at, std::min<size_t>(4096, payload.size() - at));
            if (reply.kind == update_session::Reply::refused) return reply;
        }
        return session.done();
    }
};

void test_a_really_signed_update_switches_with_libsodium_checking_the_signature_and_the_image() {
    RealUpdate update;
    MemorySlot slot;
    const update_session::Reply reply = update.run(slot, update.manifest, update.image);
    TEST_ASSERT_EQUAL(update_session::Reply::switched, reply.kind);
    TEST_ASSERT_EQUAL_STRING("1.2.0", reply.version.c_str());
    TEST_ASSERT_TRUE(slot.boot);
    TEST_ASSERT_TRUE(slot.written == update.image);
}

void test_one_changed_image_byte_is_a_mismatch_and_nothing_is_set_to_boot() {
    RealUpdate update;
    MemorySlot slot;
    std::vector<uint8_t> changed = update.image;
    changed[9000] ^= 0x80;
    const update_session::Reply reply = update.run(slot, update.manifest, changed);
    TEST_ASSERT_EQUAL(static_cast<int>(update_session::Refusal::mismatch), static_cast<int>(reply.refusal));
    TEST_ASSERT_FALSE(slot.boot);
}

void test_a_manifest_changed_after_signing_is_a_bad_signature_and_the_slot_untouched() {
    RealUpdate update;
    MemorySlot slot;
    std::string changed = update.manifest;
    changed.replace(changed.find("1.2.0"), 5, "9.2.0");
    const update_session::Reply reply = update.run(slot, changed, update.image);
    TEST_ASSERT_EQUAL(static_cast<int>(update_session::Refusal::bad_signature), static_cast<int>(reply.refusal));
    TEST_ASSERT_TRUE(slot.written.empty());
    TEST_ASSERT_FALSE(slot.boot);
}

}  // namespace

int main() {
    UNITY_BEGIN();
    RUN_TEST(test_the_rfc_8032_test_vector_verifies_and_a_changed_message_does_not);
    RUN_TEST(test_the_updaters_cryptokit_vector_verifies_and_a_one_bit_flip_does_not);
    RUN_TEST(test_sha256_of_an_image_fed_in_pieces_matches_the_fips_vectors_and_start_begins_again);
    RUN_TEST(test_a_really_signed_update_switches_with_libsodium_checking_the_signature_and_the_image);
    RUN_TEST(test_one_changed_image_byte_is_a_mismatch_and_nothing_is_set_to_boot);
    RUN_TEST(test_a_manifest_changed_after_signing_is_a_bad_signature_and_the_slot_untouched);
    return UNITY_END();
}
