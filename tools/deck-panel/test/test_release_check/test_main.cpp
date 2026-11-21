// The panel's Ed25519 check (#690, ADR 0012) against the two vectors the updater checks too (#689): RFC 8032 TEST 1,
// and the randomized CryptoKit signature in the updater's own fixture file, read from it here so the two can't drift.
#include <unity.h>

#include <cstdio>
#include <string>
#include <vector>

#include "release_check.h"

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

}  // namespace

int main() {
    UNITY_BEGIN();
    RUN_TEST(test_the_rfc_8032_test_vector_verifies_and_a_changed_message_does_not);
    RUN_TEST(test_the_updaters_cryptokit_vector_verifies_and_a_one_bit_flip_does_not);
    RUN_TEST(test_sha256_of_an_image_fed_in_pieces_matches_the_fips_vectors_and_start_begins_again);
    return UNITY_END();
}
