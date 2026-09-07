#ifndef REMOTE_PLAY_CHIAKI_BRIDGE_H
#define REMOTE_PLAY_CHIAKI_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define RP_CHIAKI_NATIVE_ABI_VERSION 7u
#define RP_CHIAKI_CAPABILITY_WAKE_PS5 (1u << 0)
#define RP_CHIAKI_CAPABILITY_CONNECT_PS5 (1u << 1)
#define RP_CHIAKI_CAPABILITY_MEDIA_CALLBACKS (1u << 2)
#define RP_CHIAKI_CAPABILITY_CONTROLLER_INPUT (1u << 3)
#define RP_CHIAKI_CAPABILITY_REST_PS5 (1u << 4)
#define RP_CHIAKI_CAPABILITY_GO_HOME (1u << 5)
#define RP_CHIAKI_CAPABILITY_REGISTER_PS5 (1u << 6)
#define RP_CHIAKI_CAPABILITY_CONTROLLER_FEEDBACK (1u << 7)
#define RP_CHIAKI_REGISTRATION_KEY_SIZE 16u
#define RP_CHIAKI_REMOTE_PLAY_KEY_SIZE 16u
#define RP_CHIAKI_PSN_ACCOUNT_ID_SIZE 8u
#define RP_CHIAKI_SERVER_MAC_SIZE 6u
#define RP_CHIAKI_SERVER_NICKNAME_SIZE 33u
#define RP_CHIAKI_TOUCHPAD_WIDTH 1920u
#define RP_CHIAKI_TOUCHPAD_HEIGHT 942u

#define RP_CHIAKI_CONTROLLER_BUTTON_CROSS (1u << 0)
#define RP_CHIAKI_CONTROLLER_BUTTON_CIRCLE (1u << 1)
#define RP_CHIAKI_CONTROLLER_BUTTON_SQUARE (1u << 2)
#define RP_CHIAKI_CONTROLLER_BUTTON_TRIANGLE (1u << 3)
#define RP_CHIAKI_CONTROLLER_BUTTON_DPAD_LEFT (1u << 4)
#define RP_CHIAKI_CONTROLLER_BUTTON_DPAD_RIGHT (1u << 5)
#define RP_CHIAKI_CONTROLLER_BUTTON_DPAD_UP (1u << 6)
#define RP_CHIAKI_CONTROLLER_BUTTON_DPAD_DOWN (1u << 7)
#define RP_CHIAKI_CONTROLLER_BUTTON_L1 (1u << 8)
#define RP_CHIAKI_CONTROLLER_BUTTON_R1 (1u << 9)
#define RP_CHIAKI_CONTROLLER_BUTTON_L3 (1u << 10)
#define RP_CHIAKI_CONTROLLER_BUTTON_R3 (1u << 11)
#define RP_CHIAKI_CONTROLLER_BUTTON_OPTIONS (1u << 12)
#define RP_CHIAKI_CONTROLLER_BUTTON_CREATE (1u << 13)
#define RP_CHIAKI_CONTROLLER_BUTTON_TOUCHPAD (1u << 14)
#define RP_CHIAKI_CONTROLLER_BUTTON_PS (1u << 15)
#define RP_CHIAKI_CONTROLLER_BUTTON_L2 (1u << 16)
#define RP_CHIAKI_CONTROLLER_BUTTON_R2 (1u << 17)
#define RP_CHIAKI_CONTROLLER_BUTTON_MASK ((1u << 18) - 1u)

typedef enum RPChiakiBridgeResult {
    RP_CHIAKI_BRIDGE_SUCCESS = 0,
    RP_CHIAKI_BRIDGE_INVALID_ARGUMENT = -1,
    RP_CHIAKI_BRIDGE_INVALID_REGISTRATION_KEY = -2,
    RP_CHIAKI_BRIDGE_INVALID_STATE = -3,
    RP_CHIAKI_BRIDGE_CALLBACK_INSTALLATION_FAILED = -4,
    RP_CHIAKI_BRIDGE_INVALID_CONNECT_CONFIGURATION = -5,
    RP_CHIAKI_BRIDGE_INVALID_REGISTRATION_CONFIGURATION = -6,
} RPChiakiBridgeResult;

typedef enum RPChiakiVideoCodec {
    RP_CHIAKI_VIDEO_CODEC_HEVC = 1,
    RP_CHIAKI_VIDEO_CODEC_HEVC_HDR = 2,
} RPChiakiVideoCodec;

typedef enum RPChiakiSessionEventType {
    RP_CHIAKI_SESSION_EVENT_TRANSPORT_READY = 1,
    RP_CHIAKI_SESSION_EVENT_QUIT = 2,
} RPChiakiSessionEventType;

typedef enum RPChiakiRegistrationEventType {
    RP_CHIAKI_REGISTRATION_EVENT_SUCCEEDED = 1,
    RP_CHIAKI_REGISTRATION_EVENT_FAILED = 2,
    RP_CHIAKI_REGISTRATION_EVENT_CANCELED = 3,
} RPChiakiRegistrationEventType;

typedef struct RPChiakiRegistrationResult {
    uint8_t registration_key[RP_CHIAKI_REGISTRATION_KEY_SIZE];
    uint8_t remote_play_key[RP_CHIAKI_REMOTE_PLAY_KEY_SIZE];
    uint8_t server_mac[RP_CHIAKI_SERVER_MAC_SIZE];
    char server_nickname[RP_CHIAKI_SERVER_NICKNAME_SIZE];
} RPChiakiRegistrationResult;

/*
 * A successful result is owned by the bridge and remains valid only until the
 * callback returns. Consumers must copy it synchronously. Failure and cancel
 * events carry a null result.
 */
typedef void (*RPChiakiRegistrationCallback)(
    void *user,
    RPChiakiRegistrationEventType event_type,
    const RPChiakiRegistrationResult *result);

typedef struct RPChiakiRegistrationCallbacks {
    void *user;
    RPChiakiRegistrationCallback event;
} RPChiakiRegistrationCallbacks;

typedef struct RPChiakiRegistrationConfiguration {
    const char *host;
    const uint8_t *psn_account_id;
    size_t psn_account_id_size;
    const char *link_device_pin;
    size_t link_device_pin_size;
} RPChiakiRegistrationConfiguration;

typedef void (*RPChiakiSessionEventCallback)(
    void *user,
    RPChiakiSessionEventType event_type,
    int32_t detail_code);

/*
 * Media buffers are owned by Chiaki and remain valid only until the callback
 * returns. A consumer that retains a sample must copy it synchronously.
 */
typedef bool (*RPChiakiEncodedVideoCallback)(
    void *user,
    const uint8_t *buffer,
    size_t buffer_size,
    int32_t frames_lost,
    bool frame_recovered);

typedef void (*RPChiakiAudioFormatCallback)(
    void *user,
    uint32_t channels,
    uint32_t bits_per_sample,
    uint32_t sample_rate,
    uint32_t frame_size);

typedef void (*RPChiakiDecodedAudioCallback)(
    void *user,
    const int16_t *samples,
    size_t frame_count,
    uint32_t channels,
    uint32_t sample_rate);

typedef void (*RPChiakiDisplayStateCallback)(
    void *user,
    bool cannot_display);

#define RP_CHIAKI_TRIGGER_EFFECT_PARAMETER_SIZE 10u

/*
 * Console-driven controller feedback. Each event carries exactly one kind of
 * payload, named by `type`; every other field is zero and must be ignored.
 */
typedef enum RPChiakiControllerFeedbackType {
    RP_CHIAKI_CONTROLLER_FEEDBACK_RUMBLE = 1,
    RP_CHIAKI_CONTROLLER_FEEDBACK_LIGHT_BAR = 2,
    RP_CHIAKI_CONTROLLER_FEEDBACK_TRIGGER_EFFECTS = 3,
    RP_CHIAKI_CONTROLLER_FEEDBACK_HAPTIC_INTENSITY = 4,
    RP_CHIAKI_CONTROLLER_FEEDBACK_TRIGGER_INTENSITY = 5,
    RP_CHIAKI_CONTROLLER_FEEDBACK_PLAYER_INDEX = 6,
} RPChiakiControllerFeedbackType;

/*
 * Mirrors Chiaki's DualSense effect intensity, whose wire values are ordered
 * strongest-first and are deliberately not a monotonic scale.
 */
typedef enum RPChiakiEffectIntensity {
    RP_CHIAKI_EFFECT_INTENSITY_OFF = 0,
    RP_CHIAKI_EFFECT_INTENSITY_STRONG = 1,
    RP_CHIAKI_EFFECT_INTENSITY_MEDIUM = 2,
    RP_CHIAKI_EFFECT_INTENSITY_WEAK = 3,
} RPChiakiEffectIntensity;

typedef struct RPChiakiControllerFeedback {
    uint32_t type;
    uint8_t rumble_left;  /* low-frequency actuator, 0...255 */
    uint8_t rumble_right; /* high-frequency actuator, 0...255 */
    uint8_t light_bar_red;
    uint8_t light_bar_green;
    uint8_t light_bar_blue;
    uint8_t player_index;
    uint8_t intensity; /* RPChiakiEffectIntensity */
    uint8_t trigger_effect_type_left;
    uint8_t trigger_effect_type_right;
    uint8_t reserved[3];
    uint8_t trigger_effect_left[RP_CHIAKI_TRIGGER_EFFECT_PARAMETER_SIZE];
    uint8_t trigger_effect_right[RP_CHIAKI_TRIGGER_EFFECT_PARAMETER_SIZE];
} RPChiakiControllerFeedback;

/*
 * Optional; a null slot simply drops console feedback. The payload is owned by
 * the bridge and valid only until the callback returns, and it arrives on the
 * Chiaki session thread, so a consumer must copy synchronously and must not
 * block. Feedback is unrelated to the media path and never gates it.
 */
typedef void (*RPChiakiControllerFeedbackCallback)(
    void *user,
    const RPChiakiControllerFeedback *feedback);

typedef struct RPChiakiSessionCallbacks {
    void *user;
    RPChiakiSessionEventCallback event;
    RPChiakiEncodedVideoCallback encoded_video;
    RPChiakiAudioFormatCallback audio_format;
    RPChiakiDecodedAudioCallback decoded_audio;
    RPChiakiDisplayStateCallback display_state;
    RPChiakiControllerFeedbackCallback controller_feedback;
} RPChiakiSessionCallbacks;

typedef struct RPChiakiConnectConfiguration {
    const char *host;
    const uint8_t *registration_key;
    size_t registration_key_size;
    const uint8_t *remote_play_key;
    size_t remote_play_key_size;
    uint32_t width;
    uint32_t height;
    uint32_t maximum_frames_per_second;
    uint32_t bitrate_kbps;
    RPChiakiVideoCodec codec;
} RPChiakiConnectConfiguration;

/*
 * Provider-neutral controller state. Stick axes use the full signed 16-bit
 * range, triggers use 0...255, and touch coordinates use the dimensions above.
 * `touch_active` must be exactly 0 or 1. Motion is intentionally deferred.
 */
typedef struct RPChiakiControllerState {
    uint32_t buttons;
    uint8_t l2_state;
    uint8_t r2_state;
    int16_t left_x;
    int16_t left_y;
    int16_t right_x;
    int16_t right_y;
    uint8_t touch_active;
    uint8_t reserved;
    uint16_t touch_x;
    uint16_t touch_y;
} RPChiakiControllerState;

typedef struct RPChiakiSessionHandle RPChiakiSessionHandle;
typedef struct RPChiakiRegistrationHandle RPChiakiRegistrationHandle;

typedef struct RPChiakiRuntimeInfo {
    uint32_t abi_version;
    size_t session_size;
    size_t video_callback_offset;
    size_t audio_sink_offset;
    size_t display_sink_offset;
    uint32_t capability_mask;
} RPChiakiRuntimeInfo;

RPChiakiRuntimeInfo rp_chiaki_runtime_info(void);
RPChiakiRegistrationHandle *rp_chiaki_registration_handle_create(void);
/* Stop and join an initialized registration before destroying its handle. */
int32_t rp_chiaki_registration_handle_destroy(RPChiakiRegistrationHandle *handle);
int32_t rp_chiaki_registration_start(
    RPChiakiRegistrationHandle *handle,
    const RPChiakiRegistrationConfiguration *configuration,
    const RPChiakiRegistrationCallbacks *callbacks);
int32_t rp_chiaki_registration_request_stop(RPChiakiRegistrationHandle *handle);
int32_t rp_chiaki_registration_join(RPChiakiRegistrationHandle *handle);
RPChiakiSessionHandle *rp_chiaki_session_handle_create(void);
size_t rp_chiaki_session_handle_allocation_size(const RPChiakiSessionHandle *handle);
/* Stop and join an initialized session before destroying its handle. */
int32_t rp_chiaki_session_handle_destroy(RPChiakiSessionHandle *handle);
int32_t rp_chiaki_wake_ps5(
    const char *host,
    const uint8_t *registration_key,
    size_t registration_key_size);
int32_t rp_chiaki_session_initialize(
    RPChiakiSessionHandle *handle,
    const RPChiakiConnectConfiguration *configuration,
    const RPChiakiSessionCallbacks *callbacks);
int32_t rp_chiaki_session_start(RPChiakiSessionHandle *handle);
int32_t rp_chiaki_session_set_controller_state(
    RPChiakiSessionHandle *handle,
    const RPChiakiControllerState *state);
int32_t rp_chiaki_session_go_home(RPChiakiSessionHandle *handle);
int32_t rp_chiaki_session_go_to_bed(RPChiakiSessionHandle *handle);
int32_t rp_chiaki_session_request_stop(RPChiakiSessionHandle *handle);
int32_t rp_chiaki_session_join(RPChiakiSessionHandle *handle);
const char *rp_chiaki_result_string(int32_t result);

#ifdef __cplusplus
}
#endif

#endif
