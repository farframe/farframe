#include <RemotePlayChiakiBridge.h>

#include "fake_chiaki_runtime.h"

#include <stdint.h>
#include <stdio.h>
#include <string.h>

static int expect_rejected_without_native_calls(
    const uint8_t *registration_key,
    size_t registration_key_size,
    int failure_code)
{
    const FakeChiakiRuntimeState *state = fake_chiaki_runtime_state();
    const unsigned int initial_library_calls = state->library_init_calls;
    const unsigned int initial_wake_calls = state->wake_calls;
    const int32_t result = rp_chiaki_wake_ps5(
        "192.0.2.44",
        registration_key,
        registration_key_size);

    if(result != RP_CHIAKI_BRIDGE_INVALID_REGISTRATION_KEY)
        return failure_code;
    if(state->library_init_calls != initial_library_calls)
        return failure_code + 1;
    if(state->wake_calls != initial_wake_calls)
        return failure_code + 2;
    return 0;
}

int main(void)
{
    fake_chiaki_runtime_reset();
    const FakeChiakiRuntimeState *state = fake_chiaki_runtime_state();

    const uint8_t short_key[8] = { '2', 'a', '3', 'B', 0, 0, 0, 0 };
    const int32_t short_result = rp_chiaki_wake_ps5(
        "192.0.2.44",
        short_key,
        sizeof(short_key));
    if(short_result != RP_CHIAKI_BRIDGE_INVALID_ARGUMENT)
        return 1;
    if(state->library_init_calls != 0 || state->wake_calls != 0)
        return 2;

    const uint8_t empty_key[RP_CHIAKI_REGISTRATION_KEY_SIZE] = { 0 };
    int failure = expect_rejected_without_native_calls(empty_key, sizeof(empty_key), 10);
    if(failure != 0)
        return failure;

    const uint8_t corrupted_prefix[RP_CHIAKI_REGISTRATION_KEY_SIZE] = {
        '1', '2', 'x', 0,
    };
    failure = expect_rejected_without_native_calls(corrupted_prefix, sizeof(corrupted_prefix), 20);
    if(failure != 0)
        return failure;

    const uint8_t nine_hex_digits[RP_CHIAKI_REGISTRATION_KEY_SIZE] = {
        '1', '2', '3', '4', '5', '6', '7', '8', '9', 0,
    };
    failure = expect_rejected_without_native_calls(nine_hex_digits, sizeof(nine_hex_digits), 30);
    if(failure != 0)
        return failure;

    const uint8_t sixteen_hex_digits[RP_CHIAKI_REGISTRATION_KEY_SIZE] = {
        '0', '1', '2', '3', '4', '5', '6', '7',
        '8', '9', 'a', 'b', 'c', 'd', 'e', 'f',
    };
    failure = expect_rejected_without_native_calls(sixteen_hex_digits, sizeof(sixteen_hex_digits), 40);
    if(failure != 0)
        return failure;

    const uint8_t mixed_case_key[RP_CHIAKI_REGISTRATION_KEY_SIZE] = {
        '2', 'a', '3', 'B', 0,
    };
    const int32_t mixed_case_result = rp_chiaki_wake_ps5(
        "192.0.2.44",
        mixed_case_key,
        sizeof(mixed_case_key));
    if(mixed_case_result != RP_CHIAKI_BRIDGE_SUCCESS)
        return 50;
    if(state->library_init_calls != 1 || state->wake_calls != 1)
        return 51;
    if(state->last_wake_credential != UINT64_C(0x2a3b))
        return 52;
    if(strcmp(state->last_wake_host, "192.0.2.44") != 0 ||
       !state->last_wake_was_ps5 || !state->last_wake_discovery_was_null)
        return 53;

    const uint8_t eight_hex_digits[RP_CHIAKI_REGISTRATION_KEY_SIZE] = {
        '8', '9', 'A', 'b', 'C', 'd', 'E', 'f', 0,
    };
    const int32_t eight_digit_result = rp_chiaki_wake_ps5(
        "198.51.100.12",
        eight_hex_digits,
        sizeof(eight_hex_digits));
    if(eight_digit_result != RP_CHIAKI_BRIDGE_SUCCESS)
        return 60;
    if(state->library_init_calls != 1 || state->wake_calls != 2)
        return 61;
    if(state->last_wake_credential != UINT64_C(0x89abcdef))
        return 62;

    printf("WAKE PARSER VERIFIED  1-8 hex digits, fail-closed, fake transport only\n");
    return 0;
}
