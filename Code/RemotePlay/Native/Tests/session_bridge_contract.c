#include <RemotePlayChiakiBridge.h>

#include "fake_chiaki_runtime.h"

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define REQUIRE(condition) \
    do { \
        if(!(condition)) { \
            fprintf(stderr, "Session bridge contract failed at line %d: %s\n", \
                    __LINE__, #condition); \
            return 1; \
        } \
    } while(0)

typedef struct EventObserver {
    unsigned int call_count;
    RPChiakiSessionEventType event_types[8];
    int32_t detail_codes[8];
    bool accept_video;
    unsigned int video_call_count;
    uint8_t video_bytes[64];
    size_t video_size;
    int32_t video_frames_lost;
    bool video_frame_recovered;
    unsigned int audio_format_call_count;
    uint32_t audio_channels;
    uint32_t audio_bits_per_sample;
    uint32_t audio_sample_rate;
    uint32_t audio_frame_size;
    unsigned int decoded_audio_call_count;
    int16_t decoded_audio_samples[32];
    size_t decoded_audio_frame_count;
    unsigned int display_state_call_count;
    bool cannot_display;
    unsigned int feedback_call_count;
    RPChiakiControllerFeedback feedback[8];
} EventObserver;

static void observe_session_event(
    void *user,
    RPChiakiSessionEventType event_type,
    int32_t detail_code)
{
    EventObserver *observer = user;
    if(!observer || observer->call_count >= 8)
        return;
    const unsigned int index = observer->call_count++;
    observer->event_types[index] = event_type;
    observer->detail_codes[index] = detail_code;
}

static bool observe_video(
    void *user,
    const uint8_t *buffer,
    size_t buffer_size,
    int32_t frames_lost,
    bool frame_recovered)
{
    EventObserver *observer = user;
    if(!observer || !buffer || buffer_size == 0 ||
       buffer_size > sizeof(observer->video_bytes))
        return false;
    observer->video_call_count++;
    observer->video_size = buffer_size;
    observer->video_frames_lost = frames_lost;
    observer->video_frame_recovered = frame_recovered;
    memcpy(observer->video_bytes, buffer, buffer_size);
    return observer->accept_video;
}

static void observe_audio_format(
    void *user,
    uint32_t channels,
    uint32_t bits_per_sample,
    uint32_t sample_rate,
    uint32_t frame_size)
{
    EventObserver *observer = user;
    if(!observer)
        return;
    observer->audio_format_call_count++;
    observer->audio_channels = channels;
    observer->audio_bits_per_sample = bits_per_sample;
    observer->audio_sample_rate = sample_rate;
    observer->audio_frame_size = frame_size;
}

static void observe_decoded_audio(
    void *user,
    const int16_t *samples,
    size_t frame_count,
    uint32_t channels,
    uint32_t sample_rate)
{
    EventObserver *observer = user;
    if(!observer || !samples || channels == 0 ||
       frame_count * channels > sizeof(observer->decoded_audio_samples) / sizeof(int16_t))
        return;
    observer->decoded_audio_call_count++;
    observer->decoded_audio_frame_count = frame_count;
    observer->audio_channels = channels;
    observer->audio_sample_rate = sample_rate;
    memcpy(
        observer->decoded_audio_samples,
        samples,
        frame_count * channels * sizeof(int16_t));
}

static void observe_display_state(void *user, bool cannot_display)
{
    EventObserver *observer = user;
    if(!observer)
        return;
    observer->display_state_call_count++;
    observer->cannot_display = cannot_display;
}

static void observe_controller_feedback(
    void *user,
    const RPChiakiControllerFeedback *feedback)
{
    EventObserver *observer = user;
    if(!observer || !feedback)
        return;
    if(observer->feedback_call_count <
       sizeof(observer->feedback) / sizeof(observer->feedback[0]))
        observer->feedback[observer->feedback_call_count] = *feedback;
    observer->feedback_call_count++;
}

static RPChiakiSessionCallbacks make_callbacks(EventObserver *observer)
{
    return (RPChiakiSessionCallbacks) {
        .user = observer,
        .event = observe_session_event,
        .encoded_video = observe_video,
        .audio_format = observe_audio_format,
        .decoded_audio = observe_decoded_audio,
        .display_state = observe_display_state,
        .controller_feedback = observe_controller_feedback,
    };
}

static int32_t initialize_session(
    RPChiakiSessionHandle *handle,
    const RPChiakiConnectConfiguration *configuration,
    EventObserver *observer)
{
    RPChiakiSessionCallbacks callbacks = make_callbacks(observer);
    return rp_chiaki_session_initialize(handle, configuration, &callbacks);
}

static RPChiakiConnectConfiguration make_configuration(
    const char *host,
    const uint8_t registration_key[RP_CHIAKI_REGISTRATION_KEY_SIZE],
    const uint8_t remote_play_key[RP_CHIAKI_REMOTE_PLAY_KEY_SIZE],
    RPChiakiVideoCodec codec)
{
    return (RPChiakiConnectConfiguration) {
        .host = host,
        .registration_key = registration_key,
        .registration_key_size = RP_CHIAKI_REGISTRATION_KEY_SIZE,
        .remote_play_key = remote_play_key,
        .remote_play_key_size = RP_CHIAKI_REMOTE_PLAY_KEY_SIZE,
        .width = 1920,
        .height = 1080,
        .maximum_frames_per_second = 60,
        .bitrate_kbps = 20000,
        .codec = codec,
    };
}

static bool bytes_are_zero(const uint8_t *bytes, size_t size)
{
    for(size_t index = 0; index < size; index++)
    {
        if(bytes[index] != 0)
            return false;
    }
    return true;
}

static size_t call_position(size_t session_record_index, FakeChiakiCallType type)
{
    const FakeChiakiRuntimeState *state = fake_chiaki_runtime_state();
    for(size_t index = 0; index < state->call_count; index++)
    {
        if(state->calls[index].session_record_index == session_record_index &&
           state->calls[index].type == type)
            return index;
    }
    return SIZE_MAX;
}

static int expect_invalid_configuration(
    RPChiakiSessionHandle *handle,
    const RPChiakiConnectConfiguration *configuration,
    EventObserver *observer)
{
    const FakeChiakiRuntimeState *state = fake_chiaki_runtime_state();
    const size_t initial_session_count = state->session_count;
    const unsigned int initial_log_calls = state->log_init_calls;
    REQUIRE(initialize_session(handle, configuration, observer) ==
            RP_CHIAKI_BRIDGE_INVALID_CONNECT_CONFIGURATION);
    REQUIRE(state->session_count == initial_session_count);
    REQUIRE(state->log_init_calls == initial_log_calls);
    return 0;
}

static int verify_invalid_inputs(
    const RPChiakiConnectConfiguration *valid_configuration,
    EventObserver *observer)
{
    RPChiakiSessionHandle *handle = rp_chiaki_session_handle_create();
    REQUIRE(handle != NULL);

    const FakeChiakiRuntimeState *state = fake_chiaki_runtime_state();
    REQUIRE(initialize_session(NULL, valid_configuration, observer) ==
            RP_CHIAKI_BRIDGE_INVALID_ARGUMENT);
    REQUIRE(rp_chiaki_session_initialize(handle, valid_configuration, NULL) ==
            RP_CHIAKI_BRIDGE_INVALID_ARGUMENT);
    RPChiakiSessionCallbacks invalid_callbacks = make_callbacks(observer);
    invalid_callbacks.user = NULL;
    REQUIRE(rp_chiaki_session_initialize(
                handle,
                valid_configuration,
                &invalid_callbacks) == RP_CHIAKI_BRIDGE_INVALID_ARGUMENT);
    invalid_callbacks = make_callbacks(observer);
    invalid_callbacks.event = NULL;
    REQUIRE(rp_chiaki_session_initialize(
                handle,
                valid_configuration,
                &invalid_callbacks) == RP_CHIAKI_BRIDGE_INVALID_ARGUMENT);
    invalid_callbacks = make_callbacks(observer);
    invalid_callbacks.encoded_video = NULL;
    REQUIRE(rp_chiaki_session_initialize(
                handle,
                valid_configuration,
                &invalid_callbacks) == RP_CHIAKI_BRIDGE_INVALID_ARGUMENT);
    invalid_callbacks = make_callbacks(observer);
    invalid_callbacks.audio_format = NULL;
    REQUIRE(rp_chiaki_session_initialize(
                handle,
                valid_configuration,
                &invalid_callbacks) == RP_CHIAKI_BRIDGE_INVALID_ARGUMENT);
    invalid_callbacks = make_callbacks(observer);
    invalid_callbacks.decoded_audio = NULL;
    REQUIRE(rp_chiaki_session_initialize(
                handle,
                valid_configuration,
                &invalid_callbacks) == RP_CHIAKI_BRIDGE_INVALID_ARGUMENT);
    invalid_callbacks = make_callbacks(observer);
    invalid_callbacks.display_state = NULL;
    REQUIRE(rp_chiaki_session_initialize(
                handle,
                valid_configuration,
                &invalid_callbacks) == RP_CHIAKI_BRIDGE_INVALID_ARGUMENT);
    REQUIRE(state->session_count == 0);
    REQUIRE(rp_chiaki_session_start(NULL) == RP_CHIAKI_BRIDGE_INVALID_ARGUMENT);
    REQUIRE(rp_chiaki_session_start(handle) == RP_CHIAKI_BRIDGE_INVALID_STATE);
    RPChiakiControllerState controller_state = { 0 };
    REQUIRE(rp_chiaki_session_set_controller_state(NULL, &controller_state) ==
            RP_CHIAKI_BRIDGE_INVALID_ARGUMENT);
    REQUIRE(rp_chiaki_session_set_controller_state(handle, NULL) ==
            RP_CHIAKI_BRIDGE_INVALID_ARGUMENT);
    REQUIRE(rp_chiaki_session_set_controller_state(handle, &controller_state) ==
            RP_CHIAKI_BRIDGE_INVALID_STATE);
    REQUIRE(rp_chiaki_session_go_home(NULL) == RP_CHIAKI_BRIDGE_INVALID_ARGUMENT);
    REQUIRE(rp_chiaki_session_go_home(handle) == RP_CHIAKI_BRIDGE_INVALID_STATE);
    REQUIRE(rp_chiaki_session_go_to_bed(NULL) == RP_CHIAKI_BRIDGE_INVALID_ARGUMENT);
    REQUIRE(rp_chiaki_session_go_to_bed(handle) == RP_CHIAKI_BRIDGE_INVALID_STATE);
    REQUIRE(rp_chiaki_session_request_stop(NULL) == RP_CHIAKI_BRIDGE_INVALID_ARGUMENT);
    REQUIRE(rp_chiaki_session_request_stop(handle) == RP_CHIAKI_BRIDGE_SUCCESS);
    REQUIRE(rp_chiaki_session_join(NULL) == RP_CHIAKI_BRIDGE_INVALID_ARGUMENT);
    REQUIRE(rp_chiaki_session_join(handle) == RP_CHIAKI_BRIDGE_SUCCESS);

    RPChiakiConnectConfiguration invalid = *valid_configuration;
    REQUIRE(expect_invalid_configuration(handle, NULL, observer) == 0);
    invalid.host = NULL;
    REQUIRE(expect_invalid_configuration(handle, &invalid, observer) == 0);
    invalid = *valid_configuration;
    invalid.host = "";
    REQUIRE(expect_invalid_configuration(handle, &invalid, observer) == 0);
    invalid = *valid_configuration;
    invalid.registration_key = NULL;
    REQUIRE(expect_invalid_configuration(handle, &invalid, observer) == 0);
    invalid = *valid_configuration;
    invalid.registration_key_size--;
    REQUIRE(expect_invalid_configuration(handle, &invalid, observer) == 0);
    invalid = *valid_configuration;
    invalid.remote_play_key = NULL;
    REQUIRE(expect_invalid_configuration(handle, &invalid, observer) == 0);
    invalid = *valid_configuration;
    invalid.remote_play_key_size--;
    REQUIRE(expect_invalid_configuration(handle, &invalid, observer) == 0);
    invalid = *valid_configuration;
    invalid.width = 0;
    REQUIRE(expect_invalid_configuration(handle, &invalid, observer) == 0);
    invalid = *valid_configuration;
    invalid.height = 0;
    REQUIRE(expect_invalid_configuration(handle, &invalid, observer) == 0);
    invalid = *valid_configuration;
    invalid.maximum_frames_per_second = 59;
    REQUIRE(expect_invalid_configuration(handle, &invalid, observer) == 0);
    invalid = *valid_configuration;
    invalid.maximum_frames_per_second = 120;
    REQUIRE(expect_invalid_configuration(handle, &invalid, observer) == 0);
    invalid = *valid_configuration;
    invalid.bitrate_kbps = 0;
    REQUIRE(expect_invalid_configuration(handle, &invalid, observer) == 0);
    invalid = *valid_configuration;
    invalid.codec = (RPChiakiVideoCodec)0;
    REQUIRE(expect_invalid_configuration(handle, &invalid, observer) == 0);

    REQUIRE(state->session_count == 0);
    REQUIRE(rp_chiaki_session_handle_destroy(handle) == RP_CHIAKI_BRIDGE_SUCCESS);
    return 0;
}

static int verify_exact_configuration_and_callbacks(
    const RPChiakiConnectConfiguration *configuration,
    const uint8_t registration_key[RP_CHIAKI_REGISTRATION_KEY_SIZE],
    const uint8_t remote_play_key[RP_CHIAKI_REMOTE_PLAY_KEY_SIZE],
    EventObserver *observer,
    RPChiakiSessionHandle **handle_out,
    size_t *record_index_out)
{
    RPChiakiSessionHandle *handle = rp_chiaki_session_handle_create();
    REQUIRE(handle != NULL);
    const FakeChiakiRuntimeState *state = fake_chiaki_runtime_state();
    const size_t record_index = state->session_count;

    REQUIRE(initialize_session(handle, configuration, observer) ==
            RP_CHIAKI_BRIDGE_SUCCESS);
    REQUIRE(state->session_count == record_index + 1);
    const FakeChiakiSessionRecord *record = fake_chiaki_session_record(record_index);
    REQUIRE(record != NULL);
    REQUIRE(record->connect_info.ps5);
    REQUIRE(strcmp(record->connect_info.host, configuration->host) == 0);
    REQUIRE(memcmp(record->connect_info.regist_key,
                   registration_key,
                   RP_CHIAKI_REGISTRATION_KEY_SIZE) == 0);
    REQUIRE(memcmp(record->connect_info.morning,
                   remote_play_key,
                   RP_CHIAKI_REMOTE_PLAY_KEY_SIZE) == 0);
    REQUIRE(record->connect_info.video_profile.width == configuration->width);
    REQUIRE(record->connect_info.video_profile.height == configuration->height);
    REQUIRE(record->connect_info.video_profile.max_fps ==
            configuration->maximum_frames_per_second);
    REQUIRE(record->connect_info.video_profile.bitrate == configuration->bitrate_kbps);
    REQUIRE(record->connect_info.video_profile.codec ==
            (configuration->codec == RP_CHIAKI_VIDEO_CODEC_HEVC_HDR
                 ? CHIAKI_CODEC_H265_HDR
                 : CHIAKI_CODEC_H265));
    REQUIRE(record->connect_info.video_profile_auto_downgrade);
    REQUIRE(!record->connect_info.enable_keyboard);
    REQUIRE(record->connect_info.enable_dualsense);
    REQUIRE(record->connect_info.audio_video_disabled == CHIAKI_NONE_DISABLED);
    REQUIRE(!record->connect_info.auto_regist);
    REQUIRE(record->connect_info.holepunch_session == NULL);
    REQUIRE(record->connect_info.rudp_sock == NULL);
    REQUIRE(bytes_are_zero(record->connect_info.psn_account_id,
                           sizeof(record->connect_info.psn_account_id)));
    REQUIRE(record->connect_info.packet_loss_max == 0.05);
    REQUIRE(record->connect_info.enable_idr_on_fec_failure);

    REQUIRE(record->log != NULL);
    REQUIRE(record->log->initialized == 1);
    REQUIRE(record->log->level_mask == CHIAKI_LOG_ERROR);
    REQUIRE(record->log->callback != NULL);
    REQUIRE(record->log->user == NULL);
    REQUIRE(record->callback_install_calls == 1);
    REQUIRE(record->callback_mask_calls == 1);
    REQUIRE(record->callback_mask == 0x1f);
    REQUIRE(record->event_callback != NULL);
    REQUIRE(record->event_user != NULL);
    REQUIRE(record->video_callback != NULL);
    REQUIRE(record->video_user != NULL);
    REQUIRE(record->audio_sink.user != NULL);
    REQUIRE(record->audio_sink.header_cb != NULL);
    REQUIRE(record->audio_sink.frame_cb != NULL);
    REQUIRE(record->display_sink.user != NULL);
    REQUIRE(record->display_sink.cantdisplay_cb != NULL);
    REQUIRE(state->opus_decoder_init_calls == record_index + 1);

    const size_t session_count_after_initialize = state->session_count;
    REQUIRE(initialize_session(handle, configuration, observer) ==
            RP_CHIAKI_BRIDGE_INVALID_STATE);
    REQUIRE(state->session_count == session_count_after_initialize);

    REQUIRE(rp_chiaki_session_start(handle) == RP_CHIAKI_BRIDGE_SUCCESS);
    REQUIRE(record->start_calls == 1);
    REQUIRE(rp_chiaki_session_start(handle) == RP_CHIAKI_BRIDGE_INVALID_STATE);
    REQUIRE(record->start_calls == 1);
    REQUIRE(rp_chiaki_session_handle_destroy(handle) == RP_CHIAKI_BRIDGE_INVALID_STATE);
    REQUIRE(record->stop_calls == 0);
    REQUIRE(record->join_calls == 0);
    REQUIRE(record->fini_calls == 0);

    RPChiakiControllerState controller_state = {
        .buttons = RP_CHIAKI_CONTROLLER_BUTTON_CROSS |
            RP_CHIAKI_CONTROLLER_BUTTON_DPAD_LEFT |
            RP_CHIAKI_CONTROLLER_BUTTON_L1 |
            RP_CHIAKI_CONTROLLER_BUTTON_R3 |
            RP_CHIAKI_CONTROLLER_BUTTON_OPTIONS |
            RP_CHIAKI_CONTROLLER_BUTTON_CREATE |
            RP_CHIAKI_CONTROLLER_BUTTON_TOUCHPAD |
            RP_CHIAKI_CONTROLLER_BUTTON_PS |
            RP_CHIAKI_CONTROLLER_BUTTON_L2 |
            RP_CHIAKI_CONTROLLER_BUTTON_R2,
        .l2_state = 51,
        .r2_state = 229,
        .left_x = -24575,
        .left_y = -8191,
        .right_x = 16383,
        .right_y = 16383,
        .touch_active = 1,
        .touch_x = 634,
        .touch_y = 621,
    };
    REQUIRE(rp_chiaki_session_set_controller_state(handle, &controller_state) ==
            RP_CHIAKI_BRIDGE_SUCCESS);
    REQUIRE(record->controller_state_calls == 1);
    REQUIRE(record->last_controller_state.buttons == controller_state.buttons);
    REQUIRE(record->last_controller_state.l2_state == controller_state.l2_state);
    REQUIRE(record->last_controller_state.r2_state == controller_state.r2_state);
    REQUIRE(record->last_controller_state.left_x == controller_state.left_x);
    REQUIRE(record->last_controller_state.left_y == controller_state.left_y);
    REQUIRE(record->last_controller_state.right_x == controller_state.right_x);
    REQUIRE(record->last_controller_state.right_y == controller_state.right_y);
    REQUIRE(record->last_controller_state.touch_id_next == 1);
    REQUIRE(record->last_controller_state.touches[0].id == 0);
    REQUIRE(record->last_controller_state.touches[0].x == controller_state.touch_x);
    REQUIRE(record->last_controller_state.touches[0].y == controller_state.touch_y);
    REQUIRE(record->last_controller_state.touches[1].id == -1);
    REQUIRE(record->last_controller_state.orient_w == 1.0f);

    RPChiakiControllerState invalid_controller_state = controller_state;
    invalid_controller_state.buttons |= 1u << 31;
    REQUIRE(rp_chiaki_session_set_controller_state(handle, &invalid_controller_state) ==
            RP_CHIAKI_BRIDGE_INVALID_ARGUMENT);
    invalid_controller_state = controller_state;
    invalid_controller_state.touch_active = 2;
    REQUIRE(rp_chiaki_session_set_controller_state(handle, &invalid_controller_state) ==
            RP_CHIAKI_BRIDGE_INVALID_ARGUMENT);
    invalid_controller_state = controller_state;
    invalid_controller_state.reserved = 1;
    REQUIRE(rp_chiaki_session_set_controller_state(handle, &invalid_controller_state) ==
            RP_CHIAKI_BRIDGE_INVALID_ARGUMENT);
    invalid_controller_state = controller_state;
    invalid_controller_state.touch_x = RP_CHIAKI_TOUCHPAD_WIDTH + 1;
    REQUIRE(rp_chiaki_session_set_controller_state(handle, &invalid_controller_state) ==
            RP_CHIAKI_BRIDGE_INVALID_ARGUMENT);
    invalid_controller_state = controller_state;
    invalid_controller_state.touch_y = RP_CHIAKI_TOUCHPAD_HEIGHT + 1;
    REQUIRE(rp_chiaki_session_set_controller_state(handle, &invalid_controller_state) ==
            RP_CHIAKI_BRIDGE_INVALID_ARGUMENT);
    REQUIRE(record->controller_state_calls == 1);

    fake_chiaki_set_next_controller_state_result(CHIAKI_ERR_UNKNOWN);
    REQUIRE(rp_chiaki_session_set_controller_state(handle, &controller_state) ==
            CHIAKI_ERR_UNKNOWN);
    REQUIRE(rp_chiaki_session_set_controller_state(handle, &controller_state) ==
            RP_CHIAKI_BRIDGE_SUCCESS);
    REQUIRE(record->controller_state_calls == 3);

    REQUIRE(rp_chiaki_session_go_home(handle) == RP_CHIAKI_BRIDGE_SUCCESS);
    fake_chiaki_set_next_go_home_result(CHIAKI_ERR_UNKNOWN);
    REQUIRE(rp_chiaki_session_go_home(handle) == CHIAKI_ERR_UNKNOWN);
    REQUIRE(rp_chiaki_session_go_home(handle) == RP_CHIAKI_BRIDGE_SUCCESS);
    REQUIRE(record->go_home_calls == 3);

    REQUIRE(rp_chiaki_session_go_to_bed(handle) == RP_CHIAKI_BRIDGE_SUCCESS);
    fake_chiaki_set_next_go_to_bed_result(CHIAKI_ERR_UNKNOWN);
    REQUIRE(rp_chiaki_session_go_to_bed(handle) == CHIAKI_ERR_UNKNOWN);
    REQUIRE(rp_chiaki_session_go_to_bed(handle) == RP_CHIAKI_BRIDGE_SUCCESS);
    REQUIRE(record->go_to_bed_calls == 3);

    REQUIRE(fake_chiaki_emit_event(
        record_index,
        CHIAKI_EVENT_LOGIN_PIN_REQUEST,
        CHIAKI_QUIT_REASON_NONE));
    REQUIRE(observer->call_count == 0);
    REQUIRE(fake_chiaki_emit_event(
        record_index,
        CHIAKI_EVENT_CONNECTED,
        CHIAKI_QUIT_REASON_NONE));
    REQUIRE(observer->call_count == 1);
    REQUIRE(observer->event_types[0] == RP_CHIAKI_SESSION_EVENT_TRANSPORT_READY);
    REQUIRE(observer->detail_codes[0] == 0);
    REQUIRE(fake_chiaki_emit_event(
        record_index,
        CHIAKI_EVENT_QUIT,
        CHIAKI_QUIT_REASON_CTRL_CONNECT_FAILED));
    REQUIRE(observer->call_count == 2);
    REQUIRE(observer->event_types[1] == RP_CHIAKI_SESSION_EVENT_QUIT);
    REQUIRE(observer->detail_codes[1] == CHIAKI_QUIT_REASON_CTRL_CONNECT_FAILED);

    observer->accept_video = false;
    uint8_t profile_header[] = { 0x00, 0x00, 0x00, 0x01, 0x40, 0x01 };
    bool accepted = true;
    REQUIRE(fake_chiaki_emit_video(
        record_index,
        profile_header,
        sizeof(profile_header),
        2,
        true,
        &accepted));
    REQUIRE(!accepted);
    REQUIRE(observer->video_call_count == 1);
    REQUIRE(observer->video_size == sizeof(profile_header));
    REQUIRE(observer->video_frames_lost == 2);
    REQUIRE(observer->video_frame_recovered);
    profile_header[4] = 0xff;
    REQUIRE(observer->video_bytes[4] == 0x40);

    observer->accept_video = true;
    uint8_t access_unit[] = { 0x00, 0x00, 0x01, 0x26, 0xaa, 0xbb };
    REQUIRE(fake_chiaki_emit_video(
        record_index,
        access_unit,
        sizeof(access_unit),
        0,
        false,
        &accepted));
    REQUIRE(accepted);
    REQUIRE(observer->video_call_count == 2);
    REQUIRE(memcmp(observer->video_bytes, access_unit, sizeof(access_unit)) == 0);

    ChiakiAudioHeader audio_header = {
        .channels = 2,
        .bits = 16,
        .rate = 48000,
        .frame_size = 4,
        .unknown = 7,
    };
    REQUIRE(fake_chiaki_emit_audio_header(record_index, &audio_header));
    REQUIRE(observer->audio_format_call_count == 1);
    REQUIRE(observer->audio_channels == 2);
    REQUIRE(observer->audio_bits_per_sample == 16);
    REQUIRE(observer->audio_sample_rate == 48000);
    REQUIRE(observer->audio_frame_size == 4);

    int16_t pcm_samples[] = { 100, -100, 200, -200, 300, -300, 400, -400 };
    REQUIRE(fake_chiaki_emit_audio_frame(
        record_index,
        (uint8_t *)pcm_samples,
        sizeof(pcm_samples)));
    REQUIRE(observer->decoded_audio_call_count == 1);
    REQUIRE(observer->decoded_audio_frame_count == 4);
    REQUIRE(observer->decoded_audio_samples[0] == 100);
    REQUIRE(observer->decoded_audio_samples[7] == -400);
    pcm_samples[0] = 999;
    REQUIRE(observer->decoded_audio_samples[0] == 100);

    REQUIRE(fake_chiaki_emit_display_state(record_index, true));
    REQUIRE(observer->display_state_call_count == 1);
    REQUIRE(observer->cannot_display);
    REQUIRE(fake_chiaki_emit_display_state(record_index, false));
    REQUIRE(observer->display_state_call_count == 2);
    REQUIRE(!observer->cannot_display);

    *handle_out = handle;
    *record_index_out = record_index;
    return 0;
}

static int verify_multi_handle_isolation_and_teardown(
    RPChiakiSessionHandle *first_handle,
    size_t first_record_index,
    EventObserver *first_observer,
    const RPChiakiConnectConfiguration *second_configuration,
    const uint8_t second_registration_key[RP_CHIAKI_REGISTRATION_KEY_SIZE],
    const uint8_t second_remote_play_key[RP_CHIAKI_REMOTE_PLAY_KEY_SIZE])
{
    EventObserver second_observer = { 0 };
    RPChiakiSessionHandle *second_handle = NULL;
    size_t second_record_index = 0;
    REQUIRE(verify_exact_configuration_and_callbacks(
                second_configuration,
                second_registration_key,
                second_remote_play_key,
                &second_observer,
                &second_handle,
                &second_record_index) == 0);
    REQUIRE(first_handle != second_handle);
    REQUIRE(first_record_index != second_record_index);
    REQUIRE(first_observer->call_count == 2);
    REQUIRE(second_observer.call_count == 2);

    REQUIRE(fake_chiaki_emit_event(
        first_record_index,
        CHIAKI_EVENT_CONNECTED,
        CHIAKI_QUIT_REASON_NONE));
    REQUIRE(first_observer->call_count == 3);
    REQUIRE(second_observer.call_count == 2);
    REQUIRE(fake_chiaki_emit_event(
        second_record_index,
        CHIAKI_EVENT_CONNECTED,
        CHIAKI_QUIT_REASON_NONE));
    REQUIRE(first_observer->call_count == 3);
    REQUIRE(second_observer.call_count == 3);

    const unsigned int first_video_calls = first_observer->video_call_count;
    const unsigned int second_video_calls = second_observer.video_call_count;
    uint8_t isolated_sample[] = { 0x00, 0x00, 0x01, 0x26, 0x55 };
    bool accepted = false;
    REQUIRE(fake_chiaki_emit_video(
        second_record_index,
        isolated_sample,
        sizeof(isolated_sample),
        0,
        false,
        &accepted));
    REQUIRE(accepted);
    REQUIRE(first_observer->video_call_count == first_video_calls);
    REQUIRE(second_observer.video_call_count == second_video_calls + 1);

    const FakeChiakiSessionRecord *first_record =
        fake_chiaki_session_record(first_record_index);
    const FakeChiakiSessionRecord *second_record =
        fake_chiaki_session_record(second_record_index);
    REQUIRE(first_record != NULL && second_record != NULL);

    REQUIRE(rp_chiaki_session_request_stop(first_handle) == RP_CHIAKI_BRIDGE_SUCCESS);
    REQUIRE(rp_chiaki_session_request_stop(first_handle) == RP_CHIAKI_BRIDGE_SUCCESS);
    REQUIRE(first_record->stop_calls == 1);
    RPChiakiControllerState neutral_controller_state = { 0 };
    REQUIRE(rp_chiaki_session_set_controller_state(
                first_handle,
                &neutral_controller_state) == RP_CHIAKI_BRIDGE_INVALID_STATE);
    REQUIRE(rp_chiaki_session_go_home(first_handle) == RP_CHIAKI_BRIDGE_INVALID_STATE);
    REQUIRE(rp_chiaki_session_go_to_bed(first_handle) == RP_CHIAKI_BRIDGE_INVALID_STATE);
    REQUIRE(rp_chiaki_session_join(first_handle) == RP_CHIAKI_BRIDGE_SUCCESS);
    REQUIRE(rp_chiaki_session_join(first_handle) == RP_CHIAKI_BRIDGE_SUCCESS);
    REQUIRE(rp_chiaki_session_request_stop(first_handle) == RP_CHIAKI_BRIDGE_SUCCESS);
    REQUIRE(first_record->stop_calls == 1);
    REQUIRE(first_record->join_calls == 1);
    REQUIRE(first_record->fini_calls == 1);
    REQUIRE(!fake_chiaki_emit_event(
        first_record_index,
        CHIAKI_EVENT_CONNECTED,
        CHIAKI_QUIT_REASON_NONE));
    REQUIRE(!fake_chiaki_emit_video(
        first_record_index,
        isolated_sample,
        sizeof(isolated_sample),
        0,
        false,
        &accepted));

    const size_t first_stop = call_position(first_record_index, FAKE_CHIAKI_CALL_SESSION_STOP);
    const size_t first_join = call_position(first_record_index, FAKE_CHIAKI_CALL_SESSION_JOIN);
    const size_t first_fini = call_position(first_record_index, FAKE_CHIAKI_CALL_SESSION_FINI);
    REQUIRE(first_stop != SIZE_MAX && first_join != SIZE_MAX && first_fini != SIZE_MAX);
    REQUIRE(first_stop < first_join && first_join < first_fini);

    REQUIRE(rp_chiaki_session_join(second_handle) == RP_CHIAKI_BRIDGE_SUCCESS);
    REQUIRE(rp_chiaki_session_join(second_handle) == RP_CHIAKI_BRIDGE_SUCCESS);
    REQUIRE(second_record->stop_calls == 1);
    REQUIRE(second_record->join_calls == 1);
    REQUIRE(second_record->fini_calls == 1);
    const size_t second_stop = call_position(second_record_index, FAKE_CHIAKI_CALL_SESSION_STOP);
    const size_t second_join = call_position(second_record_index, FAKE_CHIAKI_CALL_SESSION_JOIN);
    const size_t second_fini = call_position(second_record_index, FAKE_CHIAKI_CALL_SESSION_FINI);
    REQUIRE(second_stop < second_join && second_join < second_fini);

    REQUIRE(rp_chiaki_session_handle_destroy(first_handle) == RP_CHIAKI_BRIDGE_SUCCESS);
    REQUIRE(rp_chiaki_session_handle_destroy(second_handle) == RP_CHIAKI_BRIDGE_SUCCESS);
    REQUIRE(first_record->fini_calls == 1);
    REQUIRE(second_record->fini_calls == 1);
    return 0;
}

static int verify_callback_install_failure(
    const RPChiakiConnectConfiguration *configuration,
    EventObserver *observer)
{
    RPChiakiSessionHandle *handle = rp_chiaki_session_handle_create();
    REQUIRE(handle != NULL);
    const size_t record_index = fake_chiaki_runtime_state()->session_count;
    const unsigned int decoder_init_before =
        fake_chiaki_runtime_state()->opus_decoder_init_calls;
    const unsigned int decoder_fini_before =
        fake_chiaki_runtime_state()->opus_decoder_fini_calls;
    fake_chiaki_set_callback_mask_override(true, 1u << 0);
    REQUIRE(initialize_session(handle, configuration, observer) ==
            RP_CHIAKI_BRIDGE_CALLBACK_INSTALLATION_FAILED);
    fake_chiaki_set_callback_mask_override(false, 0);

    const FakeChiakiSessionRecord *record = fake_chiaki_session_record(record_index);
    REQUIRE(record != NULL);
    REQUIRE(record->callback_install_calls == 1);
    REQUIRE(record->callback_mask_calls == 1);
    REQUIRE(record->callback_mask == 0x1f);
    REQUIRE(record->fini_calls == 1);
    REQUIRE(fake_chiaki_runtime_state()->opus_decoder_init_calls ==
            decoder_init_before + 1);
    REQUIRE(fake_chiaki_runtime_state()->opus_decoder_fini_calls ==
            decoder_fini_before + 1);
    REQUIRE(rp_chiaki_session_start(handle) == RP_CHIAKI_BRIDGE_INVALID_STATE);
    REQUIRE(rp_chiaki_session_join(handle) == RP_CHIAKI_BRIDGE_SUCCESS);
    REQUIRE(rp_chiaki_session_handle_destroy(handle) == RP_CHIAKI_BRIDGE_SUCCESS);
    REQUIRE(record->fini_calls == 1);
    return 0;
}

static int verify_start_failure_cleanup(
    const RPChiakiConnectConfiguration *configuration,
    EventObserver *observer)
{
    RPChiakiSessionHandle *handle = rp_chiaki_session_handle_create();
    REQUIRE(handle != NULL);
    const size_t record_index = fake_chiaki_runtime_state()->session_count;
    const unsigned int decoder_init_before =
        fake_chiaki_runtime_state()->opus_decoder_init_calls;
    const unsigned int decoder_fini_before =
        fake_chiaki_runtime_state()->opus_decoder_fini_calls;
    REQUIRE(initialize_session(handle, configuration, observer) ==
            RP_CHIAKI_BRIDGE_SUCCESS);
    fake_chiaki_set_next_session_start_result(CHIAKI_ERR_UNKNOWN);
    REQUIRE(rp_chiaki_session_start(handle) == CHIAKI_ERR_UNKNOWN);

    const FakeChiakiSessionRecord *record = fake_chiaki_session_record(record_index);
    REQUIRE(record != NULL);
    REQUIRE(record->start_calls == 1);
    REQUIRE(record->stop_calls == 0);
    REQUIRE(record->join_calls == 0);
    REQUIRE(record->fini_calls == 1);
    REQUIRE(fake_chiaki_runtime_state()->opus_decoder_init_calls ==
            decoder_init_before + 1);
    REQUIRE(fake_chiaki_runtime_state()->opus_decoder_fini_calls ==
            decoder_fini_before + 1);
    REQUIRE(rp_chiaki_session_request_stop(handle) == RP_CHIAKI_BRIDGE_SUCCESS);
    REQUIRE(rp_chiaki_session_join(handle) == RP_CHIAKI_BRIDGE_SUCCESS);
    REQUIRE(rp_chiaki_session_handle_destroy(handle) == RP_CHIAKI_BRIDGE_SUCCESS);
    REQUIRE(record->fini_calls == 1);
    return 0;
}

static int verify_teardown_failures_retain_media_ownership(
    const RPChiakiConnectConfiguration *configuration)
{
    EventObserver stop_observer = { .accept_video = true };
    RPChiakiSessionHandle *stop_handle = rp_chiaki_session_handle_create();
    REQUIRE(stop_handle != NULL);
    const size_t stop_record_index = fake_chiaki_runtime_state()->session_count;
    const unsigned int decoder_fini_before =
        fake_chiaki_runtime_state()->opus_decoder_fini_calls;
    REQUIRE(initialize_session(stop_handle, configuration, &stop_observer) ==
            RP_CHIAKI_BRIDGE_SUCCESS);
    REQUIRE(rp_chiaki_session_start(stop_handle) == RP_CHIAKI_BRIDGE_SUCCESS);
    fake_chiaki_set_next_session_stop_result(CHIAKI_ERR_UNKNOWN);
    REQUIRE(rp_chiaki_session_join(stop_handle) == CHIAKI_ERR_UNKNOWN);

    const FakeChiakiSessionRecord *stop_record =
        fake_chiaki_session_record(stop_record_index);
    REQUIRE(stop_record != NULL);
    REQUIRE(stop_record->stop_calls == 1);
    REQUIRE(stop_record->join_calls == 0);
    REQUIRE(stop_record->fini_calls == 0);
    REQUIRE(fake_chiaki_runtime_state()->opus_decoder_fini_calls ==
            decoder_fini_before);
    REQUIRE(rp_chiaki_session_handle_destroy(stop_handle) ==
            RP_CHIAKI_BRIDGE_INVALID_STATE);

    uint8_t sample[] = { 0x00, 0x00, 0x01, 0x26, 0x77 };
    bool accepted = false;
    REQUIRE(fake_chiaki_emit_video(
        stop_record_index,
        sample,
        sizeof(sample),
        0,
        false,
        &accepted));
    REQUIRE(accepted);
    REQUIRE(stop_observer.video_call_count == 1);
    REQUIRE(rp_chiaki_session_join(stop_handle) == RP_CHIAKI_BRIDGE_SUCCESS);
    REQUIRE(stop_record->stop_calls == 2);
    REQUIRE(stop_record->join_calls == 1);
    REQUIRE(stop_record->fini_calls == 1);
    REQUIRE(fake_chiaki_runtime_state()->opus_decoder_fini_calls ==
            decoder_fini_before + 1);
    REQUIRE(rp_chiaki_session_handle_destroy(stop_handle) ==
            RP_CHIAKI_BRIDGE_SUCCESS);

    EventObserver join_observer = { .accept_video = true };
    RPChiakiSessionHandle *join_handle = rp_chiaki_session_handle_create();
    REQUIRE(join_handle != NULL);
    const size_t join_record_index = fake_chiaki_runtime_state()->session_count;
    const unsigned int join_decoder_fini_before =
        fake_chiaki_runtime_state()->opus_decoder_fini_calls;
    REQUIRE(initialize_session(join_handle, configuration, &join_observer) ==
            RP_CHIAKI_BRIDGE_SUCCESS);
    REQUIRE(rp_chiaki_session_start(join_handle) == RP_CHIAKI_BRIDGE_SUCCESS);
    fake_chiaki_set_next_session_join_result(CHIAKI_ERR_UNKNOWN);
    REQUIRE(rp_chiaki_session_join(join_handle) == CHIAKI_ERR_UNKNOWN);

    const FakeChiakiSessionRecord *join_record =
        fake_chiaki_session_record(join_record_index);
    REQUIRE(join_record != NULL);
    REQUIRE(join_record->stop_calls == 1);
    REQUIRE(join_record->join_calls == 1);
    REQUIRE(join_record->fini_calls == 0);
    REQUIRE(fake_chiaki_runtime_state()->opus_decoder_fini_calls ==
            join_decoder_fini_before);
    REQUIRE(fake_chiaki_emit_video(
        join_record_index,
        sample,
        sizeof(sample),
        0,
        false,
        &accepted));
    REQUIRE(accepted);
    REQUIRE(join_observer.video_call_count == 1);
    REQUIRE(rp_chiaki_session_join(join_handle) == RP_CHIAKI_BRIDGE_SUCCESS);
    REQUIRE(join_record->stop_calls == 1);
    REQUIRE(join_record->join_calls == 2);
    REQUIRE(join_record->fini_calls == 1);
    REQUIRE(fake_chiaki_runtime_state()->opus_decoder_fini_calls ==
            join_decoder_fini_before + 1);
    REQUIRE(rp_chiaki_session_handle_destroy(join_handle) ==
            RP_CHIAKI_BRIDGE_SUCCESS);
    return 0;
}

static int verify_init_failure_cleanup(
    const RPChiakiConnectConfiguration *configuration,
    EventObserver *observer)
{
    RPChiakiSessionHandle *handle = rp_chiaki_session_handle_create();
    REQUIRE(handle != NULL);
    const size_t record_index = fake_chiaki_runtime_state()->session_count;
    fake_chiaki_set_next_session_init_result(CHIAKI_ERR_UNKNOWN);
    REQUIRE(initialize_session(handle, configuration, observer) ==
            CHIAKI_ERR_UNKNOWN);

    const FakeChiakiSessionRecord *record = fake_chiaki_session_record(record_index);
    REQUIRE(record != NULL);
    REQUIRE(record->callback_install_calls == 0);
    REQUIRE(record->start_calls == 0);
    REQUIRE(record->fini_calls == 0);
    REQUIRE(rp_chiaki_session_start(handle) == RP_CHIAKI_BRIDGE_INVALID_STATE);
    REQUIRE(rp_chiaki_session_handle_destroy(handle) == RP_CHIAKI_BRIDGE_SUCCESS);
    REQUIRE(record->fini_calls == 0);
    return 0;
}

/*
 * Console feedback must reach the optional slot with exact payloads, and a
 * session that leaves the slot null must still run every other callback.
 */
static int verify_controller_feedback_delivery(
    const RPChiakiConnectConfiguration *configuration)
{
    EventObserver observer = { 0 };
    RPChiakiSessionHandle *handle = rp_chiaki_session_handle_create();
    REQUIRE(handle != NULL);
    const size_t record_index = fake_chiaki_runtime_state()->session_count;
    REQUIRE(initialize_session(handle, configuration, &observer) ==
            RP_CHIAKI_BRIDGE_SUCCESS);
    REQUIRE(rp_chiaki_session_start(handle) == RP_CHIAKI_BRIDGE_SUCCESS);

    ChiakiEvent rumble = { .type = CHIAKI_EVENT_RUMBLE };
    rumble.rumble.unknown = 0xff;
    rumble.rumble.left = 0x40;
    rumble.rumble.right = 0xc0;
    REQUIRE(fake_chiaki_emit_raw_event(record_index, &rumble));
    REQUIRE(observer.feedback_call_count == 1);
    REQUIRE(observer.feedback[0].type == RP_CHIAKI_CONTROLLER_FEEDBACK_RUMBLE);
    REQUIRE(observer.feedback[0].rumble_left == 0x40);
    REQUIRE(observer.feedback[0].rumble_right == 0xc0);

    ChiakiEvent led = { .type = CHIAKI_EVENT_LED_COLOR };
    led.led_state[0] = 0x11;
    led.led_state[1] = 0x22;
    led.led_state[2] = 0x33;
    REQUIRE(fake_chiaki_emit_raw_event(record_index, &led));
    REQUIRE(observer.feedback_call_count == 2);
    REQUIRE(observer.feedback[1].type == RP_CHIAKI_CONTROLLER_FEEDBACK_LIGHT_BAR);
    REQUIRE(observer.feedback[1].light_bar_red == 0x11);
    REQUIRE(observer.feedback[1].light_bar_green == 0x22);
    REQUIRE(observer.feedback[1].light_bar_blue == 0x33);
    REQUIRE(observer.feedback[1].rumble_left == 0);
    REQUIRE(observer.feedback[1].rumble_right == 0);

    ChiakiEvent triggers = { .type = CHIAKI_EVENT_TRIGGER_EFFECTS };
    triggers.trigger_effects.type_left = 0x21;
    triggers.trigger_effects.type_right = 0x26;
    for(uint8_t i = 0; i < RP_CHIAKI_TRIGGER_EFFECT_PARAMETER_SIZE; i++)
    {
        triggers.trigger_effects.left[i] = (uint8_t)(i + 1);
        triggers.trigger_effects.right[i] = (uint8_t)(0x80 + i);
    }
    REQUIRE(fake_chiaki_emit_raw_event(record_index, &triggers));
    REQUIRE(observer.feedback_call_count == 3);
    REQUIRE(observer.feedback[2].type ==
            RP_CHIAKI_CONTROLLER_FEEDBACK_TRIGGER_EFFECTS);
    REQUIRE(observer.feedback[2].trigger_effect_type_left == 0x21);
    REQUIRE(observer.feedback[2].trigger_effect_type_right == 0x26);
    REQUIRE(memcmp(observer.feedback[2].trigger_effect_left,
                   triggers.trigger_effects.left,
                   RP_CHIAKI_TRIGGER_EFFECT_PARAMETER_SIZE) == 0);
    REQUIRE(memcmp(observer.feedback[2].trigger_effect_right,
                   triggers.trigger_effects.right,
                   RP_CHIAKI_TRIGGER_EFFECT_PARAMETER_SIZE) == 0);

    ChiakiEvent haptic_intensity = { .type = CHIAKI_EVENT_HAPTIC_INTENSITY };
    haptic_intensity.intensity = ChiakiDualSenseWeak;
    REQUIRE(fake_chiaki_emit_raw_event(record_index, &haptic_intensity));
    REQUIRE(observer.feedback_call_count == 4);
    REQUIRE(observer.feedback[3].type ==
            RP_CHIAKI_CONTROLLER_FEEDBACK_HAPTIC_INTENSITY);
    REQUIRE(observer.feedback[3].intensity == RP_CHIAKI_EFFECT_INTENSITY_WEAK);

    ChiakiEvent trigger_intensity = { .type = CHIAKI_EVENT_TRIGGER_INTENSITY };
    trigger_intensity.intensity = ChiakiDualSenseStrong;
    REQUIRE(fake_chiaki_emit_raw_event(record_index, &trigger_intensity));
    REQUIRE(observer.feedback_call_count == 5);
    REQUIRE(observer.feedback[4].type ==
            RP_CHIAKI_CONTROLLER_FEEDBACK_TRIGGER_INTENSITY);
    REQUIRE(observer.feedback[4].intensity == RP_CHIAKI_EFFECT_INTENSITY_STRONG);

    ChiakiEvent player_index = { .type = CHIAKI_EVENT_PLAYER_INDEX };
    player_index.player_index = 3;
    REQUIRE(fake_chiaki_emit_raw_event(record_index, &player_index));
    REQUIRE(observer.feedback_call_count == 6);
    REQUIRE(observer.feedback[5].type ==
            RP_CHIAKI_CONTROLLER_FEEDBACK_PLAYER_INDEX);
    REQUIRE(observer.feedback[5].player_index == 3);

    /* An event with no feedback meaning must not reach the slot. */
    ChiakiEvent motion_reset = { .type = CHIAKI_EVENT_MOTION_RESET };
    REQUIRE(fake_chiaki_emit_raw_event(record_index, &motion_reset));
    REQUIRE(observer.feedback_call_count == 6);

    REQUIRE(rp_chiaki_session_request_stop(handle) == RP_CHIAKI_BRIDGE_SUCCESS);
    REQUIRE(rp_chiaki_session_join(handle) == RP_CHIAKI_BRIDGE_SUCCESS);
    REQUIRE(rp_chiaki_session_handle_destroy(handle) == RP_CHIAKI_BRIDGE_SUCCESS);

    /* The feedback slot is optional: a null slot drops feedback silently. */
    EventObserver silent_observer = { 0 };
    RPChiakiSessionHandle *silent_handle = rp_chiaki_session_handle_create();
    REQUIRE(silent_handle != NULL);
    const size_t silent_index = fake_chiaki_runtime_state()->session_count;
    RPChiakiSessionCallbacks silent_callbacks = make_callbacks(&silent_observer);
    silent_callbacks.controller_feedback = NULL;
    REQUIRE(rp_chiaki_session_initialize(
                silent_handle,
                configuration,
                &silent_callbacks) == RP_CHIAKI_BRIDGE_SUCCESS);
    REQUIRE(rp_chiaki_session_start(silent_handle) == RP_CHIAKI_BRIDGE_SUCCESS);
    REQUIRE(fake_chiaki_emit_raw_event(silent_index, &rumble));
    REQUIRE(silent_observer.feedback_call_count == 0);
    REQUIRE(fake_chiaki_emit_event(
        silent_index,
        CHIAKI_EVENT_CONNECTED,
        CHIAKI_QUIT_REASON_NONE));
    REQUIRE(silent_observer.call_count == 1);
    REQUIRE(silent_observer.event_types[0] ==
            RP_CHIAKI_SESSION_EVENT_TRANSPORT_READY);
    REQUIRE(rp_chiaki_session_request_stop(silent_handle) ==
            RP_CHIAKI_BRIDGE_SUCCESS);
    REQUIRE(rp_chiaki_session_join(silent_handle) == RP_CHIAKI_BRIDGE_SUCCESS);
    REQUIRE(rp_chiaki_session_handle_destroy(silent_handle) ==
            RP_CHIAKI_BRIDGE_SUCCESS);
    return 0;
}

int main(void)
{
    fake_chiaki_runtime_reset();

    const uint8_t first_registration_key[RP_CHIAKI_REGISTRATION_KEY_SIZE] = {
        0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
        0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f,
    };
    const uint8_t first_remote_play_key[RP_CHIAKI_REMOTE_PLAY_KEY_SIZE] = {
        0xf0, 0xe1, 0xd2, 0xc3, 0xb4, 0xa5, 0x96, 0x87,
        0x78, 0x69, 0x5a, 0x4b, 0x3c, 0x2d, 0x1e, 0x0f,
    };
    const uint8_t second_registration_key[RP_CHIAKI_REGISTRATION_KEY_SIZE] = {
        '1', '2', '3', '4', '5', '6', '7', '8', 0, 0, 0, 0, 0, 0, 0, 0,
    };
    const uint8_t second_remote_play_key[RP_CHIAKI_REMOTE_PLAY_KEY_SIZE] = {
        0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17,
        0x18, 0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e, 0x1f,
    };

    RPChiakiConnectConfiguration first_configuration = make_configuration(
        "192.0.2.80",
        first_registration_key,
        first_remote_play_key,
        RP_CHIAKI_VIDEO_CODEC_HEVC_HDR);
    RPChiakiConnectConfiguration second_configuration = make_configuration(
        "198.51.100.42",
        second_registration_key,
        second_remote_play_key,
        RP_CHIAKI_VIDEO_CODEC_HEVC);
    second_configuration.width = 1280;
    second_configuration.height = 720;
    second_configuration.maximum_frames_per_second = 30;
    second_configuration.bitrate_kbps = 10000;

    EventObserver first_observer = { 0 };
    REQUIRE(verify_invalid_inputs(&first_configuration, &first_observer) == 0);

    RPChiakiSessionHandle *first_handle = NULL;
    size_t first_record_index = 0;
    REQUIRE(verify_exact_configuration_and_callbacks(
                &first_configuration,
                first_registration_key,
                first_remote_play_key,
                &first_observer,
                &first_handle,
                &first_record_index) == 0);
    REQUIRE(memcmp(first_configuration.registration_key,
                   first_registration_key,
                   sizeof(first_registration_key)) == 0);
    REQUIRE(memcmp(first_configuration.remote_play_key,
                   first_remote_play_key,
                   sizeof(first_remote_play_key)) == 0);

    REQUIRE(verify_multi_handle_isolation_and_teardown(
                first_handle,
                first_record_index,
                &first_observer,
                &second_configuration,
                second_registration_key,
                second_remote_play_key) == 0);

    EventObserver failure_observer = { 0 };
    REQUIRE(verify_callback_install_failure(&first_configuration, &failure_observer) == 0);
    REQUIRE(verify_start_failure_cleanup(&first_configuration, &failure_observer) == 0);
    REQUIRE(verify_teardown_failures_retain_media_ownership(&first_configuration) == 0);
    REQUIRE(verify_init_failure_cleanup(&first_configuration, &failure_observer) == 0);
    REQUIRE(verify_controller_feedback_delivery(&first_configuration) == 0);

    printf("SESSION BRIDGE VERIFIED  exact PS5 media/control callbacks, isolation, retry-safe lifecycle\n");
    return 0;
}
