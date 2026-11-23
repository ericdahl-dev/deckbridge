// The panel's release keys (#690) as the update session takes them: a mistyped key isn't trusted, silently or not.
#include <unity.h>

#include "release_keys.h"

using release_keys::Listed;

namespace {

void test_listed_keys_become_trusted_keys_and_a_mistyped_one_is_left_out() {
    const Listed list[] = {
        {"primary", "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a"},
        {"backup", "zz5a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a"},  // not hex
        {"backup", "d75a98"},                                                          // too short
        {nullptr, nullptr},
    };
    update_session::TrustedKey out[4];
    TEST_ASSERT_EQUAL(1, release_keys::trusted(list, out, 4));
    TEST_ASSERT_EQUAL_STRING("primary", out[0].id);
    TEST_ASSERT_EQUAL_HEX8(0xd7, out[0].public_key[0]);
    TEST_ASSERT_EQUAL_HEX8(0x1a, out[0].public_key[31]);
}

// The owner's keys (#689, made 2026-11-23), as `firmware-release public-key` printed them: primary, then backup.
void test_the_shipped_list_trusts_the_owners_primary_and_backup_keys() {
    update_session::TrustedKey out[3];
    TEST_ASSERT_EQUAL(2, release_keys::trusted(release_keys::kListed, out, 3));
    TEST_ASSERT_EQUAL_STRING("primary", out[0].id);
    TEST_ASSERT_EQUAL_HEX8(0x26, out[0].public_key[0]);
    TEST_ASSERT_EQUAL_HEX8(0xf8, out[0].public_key[31]);
    TEST_ASSERT_EQUAL_STRING("backup", out[1].id);
    TEST_ASSERT_EQUAL_HEX8(0x2e, out[1].public_key[0]);
    TEST_ASSERT_EQUAL_HEX8(0xbe, out[1].public_key[31]);
}

}  // namespace

int main() {
    UNITY_BEGIN();
    RUN_TEST(test_listed_keys_become_trusted_keys_and_a_mistyped_one_is_left_out);
    RUN_TEST(test_the_shipped_list_trusts_the_owners_primary_and_backup_keys);
    return UNITY_END();
}
