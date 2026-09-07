#include <RemotePlayChiakiBridge.h>

#include "fake_chiaki_runtime.h"

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define REQUIRE(condition) \
    do { \
        if(!(condition)) { \
            fprintf(stderr, "Registration bridge contract failed at line %d: %s\n", \
                    __LINE__, #condition); \
            return 1; \
        } \
    } while(0)

typedef struct RegistrationObserver {
    unsigned int call_count;
    RPChiakiRegistrationEventType event_type;
    bool received_result;
    RPChiakiRegistrationResult result;
} RegistrationObserver;

static void observe_registration(
    void *user,
    RPChiakiRegistrationEventType event_type,
    const RPChiakiRegistrationResult *result)
{
    RegistrationObserver *observer = user;
    if(!observer)
        return;
    observer->call_count++;
    observer->event_type = event_type;
    observer->received_result = result != NULL;
    if(result)
        observer->result = *result;
}

static RPChiakiRegistrationCallbacks make_callbacks(RegistrationObserver *observer)
{
    return (RPChiakiRegistrationCallbacks) {
        .user = observer,
        .event = observe_registration,
    };
}

static RPChiakiRegistrationConfiguration make_configuration(
    const char *host,
    const uint8_t account_id[RP_CHIAKI_PSN_ACCOUNT_ID_SIZE],
    const char pin[8])
{
    return (RPChiakiRegistrationConfiguration) {
        .host = host,
        .psn_account_id = account_id,
        .psn_account_id_size = RP_CHIAKI_PSN_ACCOUNT_ID_SIZE,
        .link_device_pin = pin,
        .link_device_pin_size = 8,
    };
}

int main(void)
{
    fake_chiaki_runtime_reset();
    const RPChiakiRuntimeInfo runtime = rp_chiaki_runtime_info();
    REQUIRE(runtime.abi_version == 7u);
    REQUIRE((runtime.capability_mask & RP_CHIAKI_CAPABILITY_REGISTER_PS5) != 0);

    const uint8_t account_id[RP_CHIAKI_PSN_ACCOUNT_ID_SIZE] = {
        0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01,
    };
    const char pin[8] = { '0', '1', '2', '3', '4', '5', '6', '7' };
    RegistrationObserver observer = { 0 };
    RPChiakiRegistrationCallbacks callbacks = make_callbacks(&observer);
    RPChiakiRegistrationConfiguration configuration =
        make_configuration("192.0.2.44", account_id, pin);

    RPChiakiRegistrationHandle *handle = rp_chiaki_registration_handle_create();
    REQUIRE(handle != NULL);
    REQUIRE(rp_chiaki_registration_start(NULL, &configuration, &callbacks) ==
            RP_CHIAKI_BRIDGE_INVALID_ARGUMENT);
    REQUIRE(rp_chiaki_registration_start(handle, &configuration, NULL) ==
            RP_CHIAKI_BRIDGE_INVALID_ARGUMENT);

    RPChiakiRegistrationConfiguration invalid = configuration;
    invalid.host = "";
    REQUIRE(rp_chiaki_registration_start(handle, &invalid, &callbacks) ==
            RP_CHIAKI_BRIDGE_INVALID_REGISTRATION_CONFIGURATION);
    invalid = configuration;
    invalid.psn_account_id_size = 7;
    REQUIRE(rp_chiaki_registration_start(handle, &invalid, &callbacks) ==
            RP_CHIAKI_BRIDGE_INVALID_REGISTRATION_CONFIGURATION);
    invalid = configuration;
    const char invalid_pin[8] = { '0', '1', '2', 'x', '4', '5', '6', '7' };
    invalid.link_device_pin = invalid_pin;
    REQUIRE(rp_chiaki_registration_start(handle, &invalid, &callbacks) ==
            RP_CHIAKI_BRIDGE_INVALID_REGISTRATION_CONFIGURATION);
    REQUIRE(fake_chiaki_runtime_state()->registration_count == 0);

    REQUIRE(rp_chiaki_registration_start(handle, &configuration, &callbacks) ==
            RP_CHIAKI_BRIDGE_SUCCESS);
    REQUIRE(rp_chiaki_registration_handle_destroy(handle) ==
            RP_CHIAKI_BRIDGE_INVALID_STATE);
    const FakeChiakiRegistrationRecord *record = fake_chiaki_registration_record(0);
    REQUIRE(record != NULL);
    REQUIRE(strcmp(record->host, "192.0.2.44") == 0);
    REQUIRE(record->info.target == CHIAKI_TARGET_PS5_1);
    REQUIRE(record->info.broadcast == false);
    REQUIRE(record->info.psn_online_id == NULL);
    REQUIRE(memcmp(record->info.psn_account_id, account_id, sizeof(account_id)) == 0);
    REQUIRE(record->info.pin == 1234567u);
    REQUIRE(record->info.holepunch_info == NULL);

    ChiakiRegisteredHost registered_host;
    memset(&registered_host, 0, sizeof(registered_host));
    for(size_t index = 0; index < RP_CHIAKI_REGISTRATION_KEY_SIZE; index++)
        registered_host.rp_regist_key[index] = (char)(0x20u + index);
    for(size_t index = 0; index < RP_CHIAKI_REMOTE_PLAY_KEY_SIZE; index++)
        registered_host.rp_key[index] = (uint8_t)(0x70u + index);
    const uint8_t server_mac[RP_CHIAKI_SERVER_MAC_SIZE] =
        { 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff };
    memcpy(registered_host.server_mac, server_mac, sizeof(server_mac));
    memset(registered_host.server_nickname, 'N', sizeof(registered_host.server_nickname));

    REQUIRE(fake_chiaki_emit_registration(
        0,
        CHIAKI_REGIST_EVENT_TYPE_FINISHED_SUCCESS,
        &registered_host));
    REQUIRE(observer.call_count == 1);
    REQUIRE(observer.event_type == RP_CHIAKI_REGISTRATION_EVENT_SUCCEEDED);
    REQUIRE(observer.received_result);
    REQUIRE(memcmp(
        observer.result.registration_key,
        registered_host.rp_regist_key,
        RP_CHIAKI_REGISTRATION_KEY_SIZE) == 0);
    REQUIRE(memcmp(
        observer.result.remote_play_key,
        registered_host.rp_key,
        RP_CHIAKI_REMOTE_PLAY_KEY_SIZE) == 0);
    REQUIRE(memcmp(observer.result.server_mac, server_mac, sizeof(server_mac)) == 0);
    REQUIRE(observer.result.server_nickname[RP_CHIAKI_SERVER_NICKNAME_SIZE - 1u] == '\0');

    REQUIRE(rp_chiaki_registration_join(handle) == RP_CHIAKI_BRIDGE_SUCCESS);
    REQUIRE(record->fini_calls == 1);
    REQUIRE(rp_chiaki_registration_join(handle) == RP_CHIAKI_BRIDGE_SUCCESS);
    REQUIRE(record->fini_calls == 1);
    REQUIRE(rp_chiaki_registration_handle_destroy(handle) == RP_CHIAKI_BRIDGE_SUCCESS);

    RegistrationObserver canceled_observer = { 0 };
    callbacks = make_callbacks(&canceled_observer);
    handle = rp_chiaki_registration_handle_create();
    REQUIRE(handle != NULL);
    REQUIRE(rp_chiaki_registration_start(handle, &configuration, &callbacks) ==
            RP_CHIAKI_BRIDGE_SUCCESS);
    REQUIRE(rp_chiaki_registration_request_stop(handle) == RP_CHIAKI_BRIDGE_SUCCESS);
    REQUIRE(rp_chiaki_registration_request_stop(handle) == RP_CHIAKI_BRIDGE_SUCCESS);
    record = fake_chiaki_registration_record(1);
    REQUIRE(record != NULL);
    REQUIRE(record->stop_calls == 1);
    REQUIRE(fake_chiaki_emit_registration(
        1,
        CHIAKI_REGIST_EVENT_TYPE_FINISHED_CANCELED,
        NULL));
    REQUIRE(canceled_observer.call_count == 1);
    REQUIRE(canceled_observer.event_type == RP_CHIAKI_REGISTRATION_EVENT_CANCELED);
    REQUIRE(!canceled_observer.received_result);
    REQUIRE(rp_chiaki_registration_join(handle) == RP_CHIAKI_BRIDGE_SUCCESS);
    REQUIRE(rp_chiaki_registration_handle_destroy(handle) == RP_CHIAKI_BRIDGE_SUCCESS);

    handle = rp_chiaki_registration_handle_create();
    REQUIRE(handle != NULL);
    fake_chiaki_set_next_registration_start_result(CHIAKI_ERR_UNKNOWN);
    REQUIRE(rp_chiaki_registration_start(handle, &configuration, &callbacks) ==
            CHIAKI_ERR_UNKNOWN);
    REQUIRE(rp_chiaki_registration_handle_destroy(handle) == RP_CHIAKI_BRIDGE_SUCCESS);

    printf("REGISTRATION BRIDGE VERIFIED  exact PS5 identity/PIN/result and retry-safe lifecycle\n");
    return 0;
}
