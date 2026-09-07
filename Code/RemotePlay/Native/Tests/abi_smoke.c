#include <RemotePlayChiakiBridge.h>

#include <stdio.h>

int main(void)
{
    const RPChiakiRuntimeInfo info = rp_chiaki_runtime_info();
    if(info.abi_version != RP_CHIAKI_NATIVE_ABI_VERSION || info.session_size == 0)
        return 1;
    if(info.video_callback_offset >= info.session_size ||
       info.audio_sink_offset >= info.session_size ||
       info.display_sink_offset >= info.session_size)
        return 2;
    if((info.capability_mask & RP_CHIAKI_CAPABILITY_WAKE_PS5) == 0 ||
       (info.capability_mask & RP_CHIAKI_CAPABILITY_CONNECT_PS5) == 0 ||
       (info.capability_mask & RP_CHIAKI_CAPABILITY_MEDIA_CALLBACKS) == 0 ||
       (info.capability_mask & RP_CHIAKI_CAPABILITY_CONTROLLER_INPUT) == 0 ||
       (info.capability_mask & RP_CHIAKI_CAPABILITY_REST_PS5) == 0 ||
       (info.capability_mask & RP_CHIAKI_CAPABILITY_GO_HOME) == 0 ||
       (info.capability_mask & RP_CHIAKI_CAPABILITY_CONTROLLER_FEEDBACK) == 0)
        return 5;

    uint8_t invalid_registration_key[RP_CHIAKI_REGISTRATION_KEY_SIZE] = { 'x' };
    if(rp_chiaki_wake_ps5(NULL, invalid_registration_key, sizeof(invalid_registration_key)) != RP_CHIAKI_BRIDGE_INVALID_ARGUMENT)
        return 6;
    if(rp_chiaki_wake_ps5("", invalid_registration_key, sizeof(invalid_registration_key)) != RP_CHIAKI_BRIDGE_INVALID_ARGUMENT)
        return 7;
    if(rp_chiaki_wake_ps5("127.0.0.1", invalid_registration_key, sizeof(invalid_registration_key) - 1) != RP_CHIAKI_BRIDGE_INVALID_ARGUMENT)
        return 8;
    if(rp_chiaki_wake_ps5("127.0.0.1", invalid_registration_key, sizeof(invalid_registration_key)) != RP_CHIAKI_BRIDGE_INVALID_REGISTRATION_KEY)
        return 9;

    RPChiakiSessionHandle *handle = rp_chiaki_session_handle_create();
    if(!handle)
        return 3;
    if(rp_chiaki_session_handle_allocation_size(handle) != info.session_size)
    {
        (void)rp_chiaki_session_handle_destroy(handle);
        return 4;
    }
    if(rp_chiaki_session_initialize(NULL, NULL, NULL) != RP_CHIAKI_BRIDGE_INVALID_ARGUMENT)
    {
        (void)rp_chiaki_session_handle_destroy(handle);
        return 10;
    }
    if(rp_chiaki_session_start(NULL) != RP_CHIAKI_BRIDGE_INVALID_ARGUMENT ||
       rp_chiaki_session_set_controller_state(NULL, NULL) !=
           RP_CHIAKI_BRIDGE_INVALID_ARGUMENT ||
       rp_chiaki_session_go_home(NULL) != RP_CHIAKI_BRIDGE_INVALID_ARGUMENT ||
       rp_chiaki_session_go_to_bed(NULL) != RP_CHIAKI_BRIDGE_INVALID_ARGUMENT ||
       rp_chiaki_session_request_stop(NULL) != RP_CHIAKI_BRIDGE_INVALID_ARGUMENT ||
       rp_chiaki_session_join(NULL) != RP_CHIAKI_BRIDGE_INVALID_ARGUMENT)
    {
        (void)rp_chiaki_session_handle_destroy(handle);
        return 11;
    }
    RPChiakiControllerState controller_state = { 0 };
    if(rp_chiaki_session_start(handle) != RP_CHIAKI_BRIDGE_INVALID_STATE ||
       rp_chiaki_session_set_controller_state(handle, &controller_state) !=
           RP_CHIAKI_BRIDGE_INVALID_STATE ||
       rp_chiaki_session_go_home(handle) != RP_CHIAKI_BRIDGE_INVALID_STATE ||
       rp_chiaki_session_go_to_bed(handle) != RP_CHIAKI_BRIDGE_INVALID_STATE ||
       rp_chiaki_session_request_stop(handle) != RP_CHIAKI_BRIDGE_SUCCESS ||
       rp_chiaki_session_join(handle) != RP_CHIAKI_BRIDGE_SUCCESS)
    {
        (void)rp_chiaki_session_handle_destroy(handle);
        return 12;
    }

    printf("ChiakiNative ABI %u capabilities=0x%x session=%zu video=%zu audio=%zu display=%zu\n",
           info.abi_version,
           info.capability_mask,
           info.session_size,
           info.video_callback_offset,
           info.audio_sink_offset,
           info.display_sink_offset);
    if(rp_chiaki_session_handle_destroy(handle) != RP_CHIAKI_BRIDGE_SUCCESS)
        return 13;
    return 0;
}
