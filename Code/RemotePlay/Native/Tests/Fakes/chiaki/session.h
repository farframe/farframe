#ifndef REMOTE_PLAY_TEST_FAKE_CHIAKI_SESSION_H
#define REMOTE_PLAY_TEST_FAKE_CHIAKI_SESSION_H

#include <chiaki/common.h>
#include <chiaki/audio.h>
#include <chiaki/controller.h>
#include <chiaki/log.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define CHIAKI_SESSION_AUTH_SIZE 16u
#define CHIAKI_PSN_ACCOUNT_ID_SIZE 8u

typedef struct ChiakiConnectVideoProfile {
    unsigned int width;
    unsigned int height;
    unsigned int max_fps;
    unsigned int bitrate;
    ChiakiCodec codec;
} ChiakiConnectVideoProfile;

typedef enum ChiakiDisableAudioVideo {
    CHIAKI_NONE_DISABLED = 0,
    CHIAKI_AUDIO_DISABLED = 1,
    CHIAKI_VIDEO_DISABLED = 2,
    CHIAKI_AUDIO_VIDEO_DISABLED = 3,
} ChiakiDisableAudioVideo;

typedef void *ChiakiHolepunchSession;

typedef struct ChiakiConnectInfo {
    bool ps5;
    const char *host;
    char regist_key[CHIAKI_SESSION_AUTH_SIZE];
    uint8_t morning[16];
    ChiakiConnectVideoProfile video_profile;
    bool video_profile_auto_downgrade;
    bool enable_keyboard;
    bool enable_dualsense;
    ChiakiDisableAudioVideo audio_video_disabled;
    bool auto_regist;
    ChiakiHolepunchSession holepunch_session;
    void *rudp_sock;
    uint8_t psn_account_id[CHIAKI_PSN_ACCOUNT_ID_SIZE];
    double packet_loss_max;
    bool enable_idr_on_fec_failure;
} ChiakiConnectInfo;

typedef enum ChiakiQuitReason {
    CHIAKI_QUIT_REASON_NONE = 0,
    CHIAKI_QUIT_REASON_STOPPED = 1,
    CHIAKI_QUIT_REASON_SESSION_REQUEST_UNKNOWN = 2,
    CHIAKI_QUIT_REASON_CTRL_CONNECT_FAILED = 8,
} ChiakiQuitReason;

typedef struct ChiakiQuitEvent {
    ChiakiQuitReason reason;
    const char *reason_str;
} ChiakiQuitEvent;

/* Mirrors the payloads of the pinned chiaki-ng controller feedback events. */
typedef struct ChiakiRumbleEvent {
    uint8_t unknown;
    uint8_t left;
    uint8_t right;
} ChiakiRumbleEvent;

typedef struct ChiakiTriggerEffectsEvent {
    uint8_t type_left;
    uint8_t type_right;
    uint8_t left[10];
    uint8_t right[10];
} ChiakiTriggerEffectsEvent;

typedef enum ChiakiDualSenseEffectIntensity {
    ChiakiDualSenseOff = 0,
    ChiakiDualSenseStrong = 1,
    ChiakiDualSenseMedium = 2,
    ChiakiDualSenseWeak = 3,
} ChiakiDualSenseEffectIntensity;

typedef enum ChiakiEventType {
    CHIAKI_EVENT_CONNECTED = 0,
    CHIAKI_EVENT_LOGIN_PIN_REQUEST = 1,
    CHIAKI_EVENT_RUMBLE = 8,
    CHIAKI_EVENT_QUIT = 9,
    CHIAKI_EVENT_TRIGGER_EFFECTS = 10,
    CHIAKI_EVENT_MOTION_RESET = 11,
    CHIAKI_EVENT_LED_COLOR = 12,
    CHIAKI_EVENT_PLAYER_INDEX = 13,
    CHIAKI_EVENT_HAPTIC_INTENSITY = 14,
    CHIAKI_EVENT_TRIGGER_INTENSITY = 15,
} ChiakiEventType;

typedef struct ChiakiEvent {
    ChiakiEventType type;
    union {
        ChiakiQuitEvent quit;
        ChiakiRumbleEvent rumble;
        ChiakiTriggerEffectsEvent trigger_effects;
        uint8_t led_state[3];
        uint8_t player_index;
        ChiakiDualSenseEffectIntensity intensity;
    };
} ChiakiEvent;

typedef void (*ChiakiEventCallback)(ChiakiEvent *event, void *user);
typedef bool (*ChiakiVideoSampleCallback)(
    uint8_t *buffer,
    size_t buffer_size,
    int32_t frames_lost,
    bool frame_recovered,
    void *user);
typedef void (*ChiakiCantDisplayCb)(void *user, bool cannot_display);
typedef void (*ChiakiAudioSinkHeader)(ChiakiAudioHeader *header, void *user);
typedef void (*ChiakiAudioSinkFrame)(uint8_t *buffer, size_t buffer_size, void *user);

typedef struct ChiakiAudioSink {
    void *user;
    ChiakiAudioSinkHeader header_cb;
    ChiakiAudioSinkFrame frame_cb;
} ChiakiAudioSink;

typedef struct ChiakiCtrlDisplaySink {
    void *user;
    ChiakiCantDisplayCb cantdisplay_cb;
} ChiakiCtrlDisplaySink;

typedef struct ChiakiSession {
    uint8_t opaque_test_storage[128];
} ChiakiSession;

ChiakiErrorCode chiaki_session_init(
    ChiakiSession *session,
    ChiakiConnectInfo *connect_info,
    ChiakiLog *log);
void chiaki_session_fini(ChiakiSession *session);
ChiakiErrorCode chiaki_session_start(ChiakiSession *session);
ChiakiErrorCode chiaki_session_stop(ChiakiSession *session);
ChiakiErrorCode chiaki_session_join(ChiakiSession *session);
ChiakiErrorCode chiaki_session_set_controller_state(
    ChiakiSession *session,
    ChiakiControllerState *state);
ChiakiErrorCode chiaki_session_goto_bed(ChiakiSession *session);
ChiakiErrorCode chiaki_session_go_home(ChiakiSession *session);
void chiaki_session_set_callbacks_runtime(
    ChiakiSession *session,
    ChiakiEventCallback event_callback,
    void *event_user,
    ChiakiVideoSampleCallback video_callback,
    void *video_user,
    ChiakiAudioSink *audio_sink,
    ChiakiCtrlDisplaySink *display_sink);
uint32_t chiaki_session_callback_mask_runtime(ChiakiSession *session);

size_t chiaki_session_runtime_size(void);
size_t chiaki_session_runtime_offset_video_sample_cb(void);
size_t chiaki_session_runtime_offset_audio_sink(void);
size_t chiaki_session_runtime_offset_display_sink(void);

#endif
