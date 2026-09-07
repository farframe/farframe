#include "RemotePlayChiakiBridge.h"

#include <chiaki/common.h>
#include <chiaki/controller.h>
#include <chiaki/discovery.h>
#include <chiaki/log.h>
#include <chiaki/opusdecoder.h>
#include <chiaki/regist.h>
#include <chiaki/session.h>
#include <ctype.h>
#include <errno.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

struct RPChiakiSessionHandle {
    void *storage;
    size_t allocation_size;
    ChiakiLog log;
    RPChiakiSessionCallbacks callbacks;
    ChiakiOpusDecoder opus_decoder;
    ChiakiAudioSink opus_sink;
    bool opus_decoder_initialized;
    uint32_t audio_channels;
    uint32_t audio_bits_per_sample;
    uint32_t audio_sample_rate;
    uint32_t audio_frame_size;
    bool initialized;
    bool started;
    bool stop_requested;
};

struct RPChiakiRegistrationHandle {
    ChiakiRegist registration;
    ChiakiLog log;
    RPChiakiRegistrationCallbacks callbacks;
    bool initialized;
    bool stop_requested;
};

#define RP_CHIAKI_REQUIRED_SESSION_CALLBACK_MASK 0x1fu

static pthread_once_t library_init_once = PTHREAD_ONCE_INIT;
static ChiakiErrorCode library_init_result = CHIAKI_ERR_UNINITIALIZED;

static void initialize_library_once(void)
{
    library_init_result = chiaki_lib_init();
}

static void discard_log(ChiakiLogLevel level, const char *message, void *user)
{
    (void)level;
    (void)message;
    (void)user;
}

static void clear_sensitive(void *buffer, size_t size)
{
    volatile uint8_t *bytes = buffer;
    while(size-- > 0)
        *bytes++ = 0;
}

static ChiakiSession *session_for_handle(RPChiakiSessionHandle *handle)
{
    return handle ? (ChiakiSession *)handle->storage : NULL;
}

static void clear_session_state(RPChiakiSessionHandle *handle)
{
    if(!handle)
        return;

    memset(&handle->callbacks, 0, sizeof(handle->callbacks));
    memset(&handle->opus_sink, 0, sizeof(handle->opus_sink));
    handle->audio_channels = 0;
    handle->audio_bits_per_sample = 0;
    handle->audio_sample_rate = 0;
    handle->audio_frame_size = 0;
    handle->initialized = false;
    handle->started = false;
    handle->stop_requested = false;
    if(handle->storage)
        clear_sensitive(handle->storage, handle->allocation_size);
}

static int32_t ensure_library_initialized(void)
{
    if(pthread_once(&library_init_once, initialize_library_once) != 0)
        return CHIAKI_ERR_THREAD;
    return library_init_result;
}

static bool valid_session_callbacks(const RPChiakiSessionCallbacks *callbacks)
{
    return callbacks && callbacks->user && callbacks->event &&
        callbacks->encoded_video && callbacks->audio_format &&
        callbacks->decoded_audio && callbacks->display_state;
}

static void finalize_opus_decoder(RPChiakiSessionHandle *handle)
{
    if(!handle || !handle->opus_decoder_initialized)
        return;
    chiaki_opus_decoder_fini(&handle->opus_decoder);
    memset(&handle->opus_decoder, 0, sizeof(handle->opus_decoder));
    handle->opus_decoder_initialized = false;
}

/*
 * Controller feedback is best-effort and strictly additive: the slot is
 * optional, every payload is copied onto this thread's stack, and nothing here
 * can fail in a way that reaches the transport or media path.
 */
static void publish_controller_feedback(
    RPChiakiSessionHandle *handle,
    const RPChiakiControllerFeedback *feedback)
{
    if(!handle->callbacks.controller_feedback || !handle->callbacks.user)
        return;
    handle->callbacks.controller_feedback(handle->callbacks.user, feedback);
}

static void session_controller_feedback_event(
    RPChiakiSessionHandle *handle,
    ChiakiEvent *event)
{
    RPChiakiControllerFeedback feedback;
    memset(&feedback, 0, sizeof(feedback));

    switch(event->type)
    {
        case CHIAKI_EVENT_RUMBLE:
            feedback.type = RP_CHIAKI_CONTROLLER_FEEDBACK_RUMBLE;
            feedback.rumble_left = event->rumble.left;
            feedback.rumble_right = event->rumble.right;
            break;
        case CHIAKI_EVENT_LED_COLOR:
            feedback.type = RP_CHIAKI_CONTROLLER_FEEDBACK_LIGHT_BAR;
            feedback.light_bar_red = event->led_state[0];
            feedback.light_bar_green = event->led_state[1];
            feedback.light_bar_blue = event->led_state[2];
            break;
        case CHIAKI_EVENT_TRIGGER_EFFECTS:
            feedback.type = RP_CHIAKI_CONTROLLER_FEEDBACK_TRIGGER_EFFECTS;
            feedback.trigger_effect_type_left = event->trigger_effects.type_left;
            feedback.trigger_effect_type_right = event->trigger_effects.type_right;
            memcpy(feedback.trigger_effect_left, event->trigger_effects.left,
                   RP_CHIAKI_TRIGGER_EFFECT_PARAMETER_SIZE);
            memcpy(feedback.trigger_effect_right, event->trigger_effects.right,
                   RP_CHIAKI_TRIGGER_EFFECT_PARAMETER_SIZE);
            break;
        case CHIAKI_EVENT_HAPTIC_INTENSITY:
            feedback.type = RP_CHIAKI_CONTROLLER_FEEDBACK_HAPTIC_INTENSITY;
            feedback.intensity = (uint8_t)event->intensity;
            break;
        case CHIAKI_EVENT_TRIGGER_INTENSITY:
            feedback.type = RP_CHIAKI_CONTROLLER_FEEDBACK_TRIGGER_INTENSITY;
            feedback.intensity = (uint8_t)event->intensity;
            break;
        case CHIAKI_EVENT_PLAYER_INDEX:
            feedback.type = RP_CHIAKI_CONTROLLER_FEEDBACK_PLAYER_INDEX;
            feedback.player_index = event->player_index;
            break;
        default:
            return;
    }

    publish_controller_feedback(handle, &feedback);
}

static void session_event_callback(ChiakiEvent *event, void *user)
{
    RPChiakiSessionHandle *handle = user;
    if(!handle || !event || !handle->callbacks.event || !handle->callbacks.user)
        return;

    switch(event->type)
    {
        case CHIAKI_EVENT_CONNECTED:
            handle->callbacks.event(
                handle->callbacks.user,
                RP_CHIAKI_SESSION_EVENT_TRANSPORT_READY,
                0);
            break;
        case CHIAKI_EVENT_QUIT:
            handle->callbacks.event(
                handle->callbacks.user,
                RP_CHIAKI_SESSION_EVENT_QUIT,
                (int32_t)event->quit.reason);
            break;
        case CHIAKI_EVENT_RUMBLE:
        case CHIAKI_EVENT_LED_COLOR:
        case CHIAKI_EVENT_TRIGGER_EFFECTS:
        case CHIAKI_EVENT_HAPTIC_INTENSITY:
        case CHIAKI_EVENT_TRIGGER_INTENSITY:
        case CHIAKI_EVENT_PLAYER_INDEX:
            session_controller_feedback_event(handle, event);
            break;
        default:
            break;
    }
}

static bool session_video_callback(
    uint8_t *buffer,
    size_t buffer_size,
    int32_t frames_lost,
    bool frame_recovered,
    void *user)
{
    RPChiakiSessionHandle *handle = user;
    if(!handle || !handle->callbacks.encoded_video || !handle->callbacks.user)
        return false;
    if(!buffer || buffer_size == 0)
        return true;
    return handle->callbacks.encoded_video(
        handle->callbacks.user,
        buffer,
        buffer_size,
        frames_lost,
        frame_recovered);
}

static void opus_decoder_settings_callback(
    uint32_t channels,
    uint32_t rate,
    void *user)
{
    RPChiakiSessionHandle *handle = user;
    if(!handle || !handle->callbacks.audio_format || !handle->callbacks.user)
        return;
    handle->audio_channels = channels;
    handle->audio_sample_rate = rate;
    handle->callbacks.audio_format(
        handle->callbacks.user,
        channels,
        handle->audio_bits_per_sample,
        rate,
        handle->audio_frame_size);
}

static void opus_decoder_frame_callback(
    int16_t *samples,
    size_t frame_count,
    void *user)
{
    RPChiakiSessionHandle *handle = user;
    if(!handle || !samples || frame_count == 0 ||
       !handle->callbacks.decoded_audio || !handle->callbacks.user)
        return;
    handle->callbacks.decoded_audio(
        handle->callbacks.user,
        samples,
        frame_count,
        handle->audio_channels,
        handle->audio_sample_rate);
}

static void session_audio_header_callback(ChiakiAudioHeader *header, void *user)
{
    RPChiakiSessionHandle *handle = user;
    if(!handle || !header || !handle->opus_sink.header_cb || !handle->opus_sink.user)
        return;
    handle->audio_channels = header->channels;
    handle->audio_bits_per_sample = header->bits;
    handle->audio_sample_rate = header->rate;
    handle->audio_frame_size = header->frame_size;
    handle->opus_sink.header_cb(header, handle->opus_sink.user);
}

static void session_audio_frame_callback(uint8_t *buffer, size_t buffer_size, void *user)
{
    RPChiakiSessionHandle *handle = user;
    if(!handle || !buffer || buffer_size == 0 ||
       !handle->opus_sink.frame_cb || !handle->opus_sink.user)
        return;
    handle->opus_sink.frame_cb(buffer, buffer_size, handle->opus_sink.user);
}

static void session_display_state_callback(void *user, bool cannot_display)
{
    RPChiakiSessionHandle *handle = user;
    if(!handle || !handle->callbacks.display_state || !handle->callbacks.user)
        return;
    handle->callbacks.display_state(handle->callbacks.user, cannot_display);
}

static bool valid_connect_configuration(const RPChiakiConnectConfiguration *configuration)
{
    if(!configuration || !configuration->host || configuration->host[0] == '\0' ||
       !configuration->registration_key || !configuration->remote_play_key)
        return false;
    if(configuration->registration_key_size != RP_CHIAKI_REGISTRATION_KEY_SIZE ||
       configuration->remote_play_key_size != RP_CHIAKI_REMOTE_PLAY_KEY_SIZE)
        return false;
    if(configuration->width == 0 || configuration->height == 0 ||
       (configuration->maximum_frames_per_second != 30 &&
        configuration->maximum_frames_per_second != 60) ||
       configuration->bitrate_kbps == 0)
        return false;
    return configuration->codec == RP_CHIAKI_VIDEO_CODEC_HEVC ||
        configuration->codec == RP_CHIAKI_VIDEO_CODEC_HEVC_HDR;
}

static bool valid_registration_configuration(
    const RPChiakiRegistrationConfiguration *configuration)
{
    if(!configuration || !configuration->host || configuration->host[0] == '\0' ||
       !configuration->psn_account_id ||
       configuration->psn_account_id_size != RP_CHIAKI_PSN_ACCOUNT_ID_SIZE ||
       !configuration->link_device_pin ||
       configuration->link_device_pin_size != 8u)
        return false;
    for(size_t index = 0; index < configuration->link_device_pin_size; index++)
    {
        if(configuration->link_device_pin[index] < '0' ||
           configuration->link_device_pin[index] > '9')
            return false;
    }
    return true;
}

static uint32_t registration_pin(
    const char link_device_pin[8])
{
    uint32_t pin = 0;
    for(size_t index = 0; index < 8u; index++)
        pin = pin * 10u + (uint32_t)(link_device_pin[index] - '0');
    return pin;
}

static bool valid_registration_callbacks(const RPChiakiRegistrationCallbacks *callbacks)
{
    return callbacks && callbacks->user && callbacks->event;
}

static void registration_event_callback(ChiakiRegistEvent *event, void *user)
{
    RPChiakiRegistrationHandle *handle = user;
    if(!handle || !event || !handle->callbacks.user || !handle->callbacks.event)
        return;

    switch(event->type)
    {
        case CHIAKI_REGIST_EVENT_TYPE_FINISHED_SUCCESS:
        {
            if(!event->registered_host)
            {
                handle->callbacks.event(
                    handle->callbacks.user,
                    RP_CHIAKI_REGISTRATION_EVENT_FAILED,
                    NULL);
                return;
            }

            RPChiakiRegistrationResult result;
            memset(&result, 0, sizeof(result));
            memcpy(
                result.registration_key,
                event->registered_host->rp_regist_key,
                RP_CHIAKI_REGISTRATION_KEY_SIZE);
            memcpy(
                result.remote_play_key,
                event->registered_host->rp_key,
                RP_CHIAKI_REMOTE_PLAY_KEY_SIZE);
            memcpy(
                result.server_mac,
                event->registered_host->server_mac,
                RP_CHIAKI_SERVER_MAC_SIZE);
            memcpy(
                result.server_nickname,
                event->registered_host->server_nickname,
                RP_CHIAKI_SERVER_NICKNAME_SIZE - 1u);
            result.server_nickname[RP_CHIAKI_SERVER_NICKNAME_SIZE - 1u] = '\0';
            handle->callbacks.event(
                handle->callbacks.user,
                RP_CHIAKI_REGISTRATION_EVENT_SUCCEEDED,
                &result);
            clear_sensitive(&result, sizeof(result));
            break;
        }
        case CHIAKI_REGIST_EVENT_TYPE_FINISHED_FAILED:
            handle->callbacks.event(
                handle->callbacks.user,
                RP_CHIAKI_REGISTRATION_EVENT_FAILED,
                NULL);
            break;
        case CHIAKI_REGIST_EVENT_TYPE_FINISHED_CANCELED:
            handle->callbacks.event(
                handle->callbacks.user,
                RP_CHIAKI_REGISTRATION_EVENT_CANCELED,
                NULL);
            break;
        default:
            break;
    }
}

static bool valid_controller_state(const RPChiakiControllerState *state)
{
    if(!state || (state->buttons & ~RP_CHIAKI_CONTROLLER_BUTTON_MASK) != 0 ||
       state->touch_active > 1 || state->reserved != 0)
        return false;
    if(state->touch_active &&
       (state->touch_x > RP_CHIAKI_TOUCHPAD_WIDTH ||
        state->touch_y > RP_CHIAKI_TOUCHPAD_HEIGHT))
        return false;
    return true;
}

static bool active_session_handle(const RPChiakiSessionHandle *handle)
{
    return handle && handle->initialized && handle->started &&
        !handle->stop_requested;
}

static bool parse_wake_credential(
    const uint8_t registration_key[RP_CHIAKI_REGISTRATION_KEY_SIZE],
    uint64_t *credential)
{
    if(!registration_key || !credential)
        return false;

    char digits[RP_CHIAKI_REGISTRATION_KEY_SIZE + 1] = { 0 };
    size_t count = 0;
    for(size_t i = 0; i < RP_CHIAKI_REGISTRATION_KEY_SIZE; i++)
    {
        const uint8_t byte = registration_key[i];
        if(byte == 0)
            break;
        if(!isxdigit((unsigned char)byte))
        {
            clear_sensitive(digits, sizeof(digits));
            return false;
        }
        digits[count++] = (char)byte;
    }
    if(count == 0 || count > 8)
    {
        clear_sensitive(digits, sizeof(digits));
        return false;
    }

    errno = 0;
    char *end = NULL;
    const unsigned long long parsed = strtoull(digits, &end, 16);
    const bool valid = errno != ERANGE && end == digits + count;
    if(valid)
        *credential = (uint64_t)parsed;
    clear_sensitive(digits, sizeof(digits));
    return valid;
}

RPChiakiRuntimeInfo rp_chiaki_runtime_info(void)
{
    RPChiakiRuntimeInfo info = {
        .abi_version = RP_CHIAKI_NATIVE_ABI_VERSION,
        .session_size = chiaki_session_runtime_size(),
        .video_callback_offset = chiaki_session_runtime_offset_video_sample_cb(),
        .audio_sink_offset = chiaki_session_runtime_offset_audio_sink(),
        .display_sink_offset = chiaki_session_runtime_offset_display_sink(),
        .capability_mask = RP_CHIAKI_CAPABILITY_WAKE_PS5 |
            RP_CHIAKI_CAPABILITY_CONNECT_PS5 |
            RP_CHIAKI_CAPABILITY_MEDIA_CALLBACKS |
            RP_CHIAKI_CAPABILITY_CONTROLLER_INPUT |
            RP_CHIAKI_CAPABILITY_REST_PS5 |
            RP_CHIAKI_CAPABILITY_GO_HOME |
            RP_CHIAKI_CAPABILITY_REGISTER_PS5 |
            RP_CHIAKI_CAPABILITY_CONTROLLER_FEEDBACK,
    };
    return info;
}

RPChiakiRegistrationHandle *rp_chiaki_registration_handle_create(void)
{
    return calloc(1, sizeof(RPChiakiRegistrationHandle));
}

int32_t rp_chiaki_registration_handle_destroy(RPChiakiRegistrationHandle *handle)
{
    if(!handle)
        return RP_CHIAKI_BRIDGE_SUCCESS;
    if(handle->initialized)
        return RP_CHIAKI_BRIDGE_INVALID_STATE;
    clear_sensitive(handle, sizeof(*handle));
    free(handle);
    return RP_CHIAKI_BRIDGE_SUCCESS;
}

int32_t rp_chiaki_registration_start(
    RPChiakiRegistrationHandle *handle,
    const RPChiakiRegistrationConfiguration *configuration,
    const RPChiakiRegistrationCallbacks *callbacks)
{
    if(!handle || !valid_registration_callbacks(callbacks))
        return RP_CHIAKI_BRIDGE_INVALID_ARGUMENT;
    if(handle->initialized)
        return RP_CHIAKI_BRIDGE_INVALID_STATE;
    if(!valid_registration_configuration(configuration))
        return RP_CHIAKI_BRIDGE_INVALID_REGISTRATION_CONFIGURATION;

    const int32_t library_result = ensure_library_initialized();
    if(library_result != CHIAKI_ERR_SUCCESS)
        return library_result;

    ChiakiRegistInfo info;
    memset(&info, 0, sizeof(info));
    info.target = CHIAKI_TARGET_PS5_1;
    info.host = configuration->host;
    info.broadcast = false;
    info.psn_online_id = NULL;
    memcpy(
        info.psn_account_id,
        configuration->psn_account_id,
        RP_CHIAKI_PSN_ACCOUNT_ID_SIZE);
    info.pin = registration_pin(configuration->link_device_pin);
    info.holepunch_info = NULL;

    chiaki_log_init(&handle->log, CHIAKI_LOG_ERROR, discard_log, NULL);
    handle->callbacks = *callbacks;
    const int32_t result = chiaki_regist_start(
        &handle->registration,
        &handle->log,
        &info,
        registration_event_callback,
        handle);
    clear_sensitive(&info, sizeof(info));
    if(result != CHIAKI_ERR_SUCCESS)
    {
        memset(&handle->callbacks, 0, sizeof(handle->callbacks));
        return result;
    }

    handle->initialized = true;
    handle->stop_requested = false;
    return RP_CHIAKI_BRIDGE_SUCCESS;
}

int32_t rp_chiaki_registration_request_stop(RPChiakiRegistrationHandle *handle)
{
    if(!handle)
        return RP_CHIAKI_BRIDGE_INVALID_ARGUMENT;
    if(!handle->initialized || handle->stop_requested)
        return RP_CHIAKI_BRIDGE_SUCCESS;
    chiaki_regist_stop(&handle->registration);
    handle->stop_requested = true;
    return RP_CHIAKI_BRIDGE_SUCCESS;
}

int32_t rp_chiaki_registration_join(RPChiakiRegistrationHandle *handle)
{
    if(!handle)
        return RP_CHIAKI_BRIDGE_INVALID_ARGUMENT;
    if(!handle->initialized)
        return RP_CHIAKI_BRIDGE_SUCCESS;

    chiaki_regist_fini(&handle->registration);
    clear_sensitive(&handle->registration, sizeof(handle->registration));
    memset(&handle->callbacks, 0, sizeof(handle->callbacks));
    handle->initialized = false;
    handle->stop_requested = false;
    return RP_CHIAKI_BRIDGE_SUCCESS;
}

RPChiakiSessionHandle *rp_chiaki_session_handle_create(void)
{
    const size_t runtime_size = chiaki_session_runtime_size();
    if(runtime_size == 0)
        return NULL;

    RPChiakiSessionHandle *handle = calloc(1, sizeof(*handle));
    if(!handle)
        return NULL;

    handle->storage = calloc(1, runtime_size);
    if(!handle->storage)
    {
        free(handle);
        return NULL;
    }

    handle->allocation_size = runtime_size;
    return handle;
}

size_t rp_chiaki_session_handle_allocation_size(const RPChiakiSessionHandle *handle)
{
    return handle ? handle->allocation_size : 0;
}

int32_t rp_chiaki_session_handle_destroy(RPChiakiSessionHandle *handle)
{
    if(!handle)
        return RP_CHIAKI_BRIDGE_SUCCESS;

    /*
     * Destruction never performs a hidden blocking join. Keeping ownership
     * with the caller makes stop/join failures retryable and prevents a
     * session callback from accidentally attempting to join its own thread.
     */
    if(handle->initialized)
        return RP_CHIAKI_BRIDGE_INVALID_STATE;

    if(handle->storage)
    {
        clear_sensitive(handle->storage, handle->allocation_size);
        free(handle->storage);
    }

    memset(handle, 0, sizeof(*handle));
    free(handle);
    return RP_CHIAKI_BRIDGE_SUCCESS;
}

int32_t rp_chiaki_wake_ps5(
    const char *host,
    const uint8_t *registration_key,
    size_t registration_key_size)
{
    if(!host || host[0] == '\0' || !registration_key ||
       registration_key_size != RP_CHIAKI_REGISTRATION_KEY_SIZE)
        return RP_CHIAKI_BRIDGE_INVALID_ARGUMENT;

    uint64_t credential = 0;
    if(!parse_wake_credential(registration_key, &credential))
        return RP_CHIAKI_BRIDGE_INVALID_REGISTRATION_KEY;

    const int32_t init_result = ensure_library_initialized();
    if(init_result != CHIAKI_ERR_SUCCESS)
    {
        clear_sensitive(&credential, sizeof(credential));
        return init_result;
    }

    ChiakiLog log;
    chiaki_log_init(&log, CHIAKI_LOG_ERROR, discard_log, NULL);
    const int32_t result = chiaki_discovery_wakeup(&log, NULL, host, credential, true);
    clear_sensitive(&credential, sizeof(credential));
    return result;
}

int32_t rp_chiaki_session_initialize(
    RPChiakiSessionHandle *handle,
    const RPChiakiConnectConfiguration *configuration,
    const RPChiakiSessionCallbacks *callbacks)
{
    if(!handle || !handle->storage || !valid_session_callbacks(callbacks))
        return RP_CHIAKI_BRIDGE_INVALID_ARGUMENT;
    if(handle->initialized || handle->started)
        return RP_CHIAKI_BRIDGE_INVALID_STATE;
    if(!valid_connect_configuration(configuration))
        return RP_CHIAKI_BRIDGE_INVALID_CONNECT_CONFIGURATION;

    const int32_t library_result = ensure_library_initialized();
    if(library_result != CHIAKI_ERR_SUCCESS)
        return library_result;

    ChiakiConnectInfo connect_info;
    memset(&connect_info, 0, sizeof(connect_info));
    connect_info.ps5 = true;
    connect_info.host = configuration->host;
    memcpy(connect_info.regist_key, configuration->registration_key,
           RP_CHIAKI_REGISTRATION_KEY_SIZE);
    memcpy(connect_info.morning, configuration->remote_play_key,
           RP_CHIAKI_REMOTE_PLAY_KEY_SIZE);
    connect_info.video_profile.width = configuration->width;
    connect_info.video_profile.height = configuration->height;
    connect_info.video_profile.max_fps = configuration->maximum_frames_per_second;
    connect_info.video_profile.bitrate = configuration->bitrate_kbps;
    connect_info.video_profile.codec = configuration->codec == RP_CHIAKI_VIDEO_CODEC_HEVC_HDR
        ? CHIAKI_CODEC_H265_HDR
        : CHIAKI_CODEC_H265;
    connect_info.video_profile_auto_downgrade = true;
    connect_info.enable_keyboard = false;
    connect_info.enable_dualsense = true;
    connect_info.audio_video_disabled = CHIAKI_NONE_DISABLED;
    connect_info.auto_regist = false;
    connect_info.holepunch_session = NULL;
    connect_info.rudp_sock = NULL;
    connect_info.packet_loss_max = 0.05;
    connect_info.enable_idr_on_fec_failure = true;

    chiaki_log_init(&handle->log, CHIAKI_LOG_ERROR, discard_log, NULL);
    const int32_t init_result = chiaki_session_init(
        session_for_handle(handle),
        &connect_info,
        &handle->log);
    clear_sensitive(&connect_info, sizeof(connect_info));
    if(init_result != CHIAKI_ERR_SUCCESS)
    {
        clear_session_state(handle);
        return init_result;
    }

    handle->callbacks = *callbacks;
    handle->initialized = true;

    chiaki_opus_decoder_init(&handle->opus_decoder, &handle->log);
    handle->opus_decoder_initialized = true;
    chiaki_opus_decoder_set_cb(
        &handle->opus_decoder,
        opus_decoder_settings_callback,
        opus_decoder_frame_callback,
        handle);
    chiaki_opus_decoder_get_sink(&handle->opus_decoder, &handle->opus_sink);

    ChiakiAudioSink audio_sink = {
        .user = handle,
        .header_cb = session_audio_header_callback,
        .frame_cb = session_audio_frame_callback,
    };

    ChiakiCtrlDisplaySink display_sink = {
        .user = handle,
        .cantdisplay_cb = session_display_state_callback,
    };
    chiaki_session_set_callbacks_runtime(
        session_for_handle(handle),
        session_event_callback,
        handle,
        session_video_callback,
        handle,
        &audio_sink,
        &display_sink);
    const uint32_t callback_mask = chiaki_session_callback_mask_runtime(
        session_for_handle(handle));
    if((callback_mask & RP_CHIAKI_REQUIRED_SESSION_CALLBACK_MASK) !=
       RP_CHIAKI_REQUIRED_SESSION_CALLBACK_MASK)
    {
        chiaki_session_fini(session_for_handle(handle));
        finalize_opus_decoder(handle);
        clear_session_state(handle);
        return RP_CHIAKI_BRIDGE_CALLBACK_INSTALLATION_FAILED;
    }

    return RP_CHIAKI_BRIDGE_SUCCESS;
}

int32_t rp_chiaki_session_start(RPChiakiSessionHandle *handle)
{
    if(!handle)
        return RP_CHIAKI_BRIDGE_INVALID_ARGUMENT;
    if(!handle->initialized || handle->started)
        return RP_CHIAKI_BRIDGE_INVALID_STATE;

    /*
     * The Chiaki thread may publish an event before chiaki_session_start()
     * returns. Mark the handle started first so a callback-triggered teardown
     * cannot skip join and finalize storage while that thread is still alive.
     */
    handle->started = true;
    const int32_t result = chiaki_session_start(session_for_handle(handle));
    if(result != CHIAKI_ERR_SUCCESS)
    {
        handle->started = false;
        chiaki_session_fini(session_for_handle(handle));
        finalize_opus_decoder(handle);
        clear_session_state(handle);
        return result;
    }

    return RP_CHIAKI_BRIDGE_SUCCESS;
}

int32_t rp_chiaki_session_set_controller_state(
    RPChiakiSessionHandle *handle,
    const RPChiakiControllerState *state)
{
    if(!handle || !state)
        return RP_CHIAKI_BRIDGE_INVALID_ARGUMENT;
    if(!active_session_handle(handle))
        return RP_CHIAKI_BRIDGE_INVALID_STATE;
    if(!valid_controller_state(state))
        return RP_CHIAKI_BRIDGE_INVALID_ARGUMENT;

    ChiakiControllerState native_state;
    chiaki_controller_state_set_idle(&native_state);
    native_state.buttons = state->buttons;
    native_state.l2_state = state->l2_state;
    native_state.r2_state = state->r2_state;
    native_state.left_x = state->left_x;
    native_state.left_y = state->left_y;
    native_state.right_x = state->right_x;
    native_state.right_y = state->right_y;
    if(state->touch_active)
    {
        native_state.touch_id_next = 1;
        native_state.touches[0].id = 0;
        native_state.touches[0].x = state->touch_x;
        native_state.touches[0].y = state->touch_y;
    }

    const int32_t result = chiaki_session_set_controller_state(
        session_for_handle(handle),
        &native_state);
    clear_sensitive(&native_state, sizeof(native_state));
    return result;
}

int32_t rp_chiaki_session_go_home(RPChiakiSessionHandle *handle)
{
    if(!handle)
        return RP_CHIAKI_BRIDGE_INVALID_ARGUMENT;
    if(!active_session_handle(handle))
        return RP_CHIAKI_BRIDGE_INVALID_STATE;
    return chiaki_session_go_home(session_for_handle(handle));
}

int32_t rp_chiaki_session_go_to_bed(RPChiakiSessionHandle *handle)
{
    if(!handle)
        return RP_CHIAKI_BRIDGE_INVALID_ARGUMENT;
    if(!active_session_handle(handle))
        return RP_CHIAKI_BRIDGE_INVALID_STATE;
    return chiaki_session_goto_bed(session_for_handle(handle));
}

int32_t rp_chiaki_session_request_stop(RPChiakiSessionHandle *handle)
{
    if(!handle)
        return RP_CHIAKI_BRIDGE_INVALID_ARGUMENT;
    if(!handle->initialized || !handle->started || handle->stop_requested)
        return RP_CHIAKI_BRIDGE_SUCCESS;

    const int32_t result = chiaki_session_stop(session_for_handle(handle));
    if(result == CHIAKI_ERR_SUCCESS)
        handle->stop_requested = true;
    return result;
}

int32_t rp_chiaki_session_join(RPChiakiSessionHandle *handle)
{
    if(!handle)
        return RP_CHIAKI_BRIDGE_INVALID_ARGUMENT;
    if(!handle->initialized)
        return RP_CHIAKI_BRIDGE_SUCCESS;

    if(handle->started)
    {
        const int32_t stop_result = rp_chiaki_session_request_stop(handle);
        if(stop_result != CHIAKI_ERR_SUCCESS)
            return stop_result;
        const int32_t join_result = chiaki_session_join(session_for_handle(handle));
        if(join_result != CHIAKI_ERR_SUCCESS)
            return join_result;
        handle->started = false;
    }

    chiaki_session_fini(session_for_handle(handle));
    finalize_opus_decoder(handle);
    clear_session_state(handle);
    return RP_CHIAKI_BRIDGE_SUCCESS;
}

const char *rp_chiaki_result_string(int32_t result)
{
    switch(result)
    {
        case RP_CHIAKI_BRIDGE_SUCCESS:
            return "Success";
        case RP_CHIAKI_BRIDGE_INVALID_ARGUMENT:
            return "Invalid argument";
        case RP_CHIAKI_BRIDGE_INVALID_REGISTRATION_KEY:
            return "Invalid registration key";
        case RP_CHIAKI_BRIDGE_INVALID_STATE:
            return "Invalid session state";
        case RP_CHIAKI_BRIDGE_CALLBACK_INSTALLATION_FAILED:
            return "Session callback installation failed";
        case RP_CHIAKI_BRIDGE_INVALID_CONNECT_CONFIGURATION:
            return "Invalid connect configuration";
        case RP_CHIAKI_BRIDGE_INVALID_REGISTRATION_CONFIGURATION:
            return "Invalid registration configuration";
        default:
            return result > 0 ? chiaki_error_string((ChiakiErrorCode)result) : "Unknown bridge error";
    }
}
