// The panel's reading of a signed release manifest (#690, ADR 0012), in the shape the updater's signer writes
// (ReleaseSigner, #689: JSONSerialization, pretty-printed, sorted keys).
#include <unity.h>

#include <cstring>
#include <string>

#include "update_manifest.h"

namespace {

const char* const kSigned = R"({
  "catalog" : {
    "lc6000" : [],
    "panel" : [ { "image" : "deck-panel-1.1.0-1d0683f.bin", "sha" : "1d0683f", "version" : "1.1.0" } ]
  },
  "files" : [
    {
      "device" : "lc6000-wd",
      "name" : "wd-00.50-show-slot-16.patch",
      "sha256" : "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff",
      "size" : 554,
      "version" : "00.50"
    },
    {
      "device" : "deck-panel",
      "name" : "deck-panel-1.1.0-1d0683f.bin",
      "sha256" : "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08",
      "size" : 1761280,
      "version" : "1.1.0"
    }
  ],
  "format" : 1,
  "key" : "primary",
  "lowest_allowed" : {
    "deck-panel" : "1.0.5"
  }
})";

update_manifest::Manifest parsed(const char* text) {
    update_manifest::Manifest manifest;
    TEST_ASSERT_TRUE(update_manifest::parse(text, std::strlen(text), manifest));
    return manifest;
}

void test_the_panels_image_and_the_rules_are_read_from_a_signed_manifest() {
    const auto manifest = parsed(kSigned);
    TEST_ASSERT_EQUAL(1, manifest.format);
    TEST_ASSERT_EQUAL_STRING("primary", manifest.key.c_str());
    TEST_ASSERT_EQUAL_STRING("1.0.5", manifest.lowest_allowed.c_str());
    TEST_ASSERT_TRUE(manifest.has_image);
    TEST_ASSERT_EQUAL_STRING("deck-panel-1.1.0-1d0683f.bin", manifest.image.name.c_str());
    TEST_ASSERT_EQUAL_STRING("1.1.0", manifest.image.version.c_str());
    TEST_ASSERT_EQUAL_UINT32(1761280, manifest.image.size);
    const uint8_t first[4] = {0x9f, 0x86, 0xd0, 0x81};
    TEST_ASSERT_EQUAL_HEX8_ARRAY(first, manifest.image.sha256, 4);
    TEST_ASSERT_EQUAL_HEX8(0x08, manifest.image.sha256[31]);
}

}  // namespace

int main() {
    UNITY_BEGIN();
    RUN_TEST(test_the_panels_image_and_the_rules_are_read_from_a_signed_manifest);
    return UNITY_END();
}
