#ifndef REMOTE_PLAY_TEST_FAKE_CHIAKI_RUNTIME_H
#define REMOTE_PLAY_TEST_FAKE_CHIAKI_RUNTIME_H

#include <chiaki/discovery.h>
#include <chiaki/regist.h>
#include <chiaki/session.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define FAKE_CHIAKI_MAX_SESSION_RECORDS 16u
#define FAKE_CHIAKI_MAX_CALLS 128u
#define FAKE_CHIAKI_MAX_REGISTRATION_RECORDS 16u

typedef enum FakeChiakiCallType {
    FAKE_CHIAKI_CALL_SESSION_INIT = 1,
    FAKE_CHIAKI_CALL_SET_CALLBACKS = 2,
    FAKE_CHIAKI_CALL_CALLBACK_MASK = 3,
    FAKE_CHIAKI_CALL_SESSION_START = 4,
    FAKE_CHIAKI_CALL_SESSION_STOP = 5,
    FAKE_CHIAKI_CALL_SESSION_JOIN = 6,
    FAKE_CHIAKI_CALL_SESSION_FINI = 7,
    FAKE_CHIAKI_CALL_CONTROLLER_STATE = 8,
    FAKE_CHIAKI_CALL_GO_HOME = 9,
    FAKE_CHIAKI_CALL_GO_TO_BED = 10,
    FAKE_CHIAKI_CALL_REGISTRATION_START = 11,
    FAKE_CHIAKI_CALL_REGISTRATION_STOP = 12,
    FAKE_CHIAKI_CALL_REGISTRATION_FINI = 13,
} FakeChiakiCallType;

typedef struct FakeChiakiCall {
    FakeChiakiCallType type;
    size_t session_record_index;
} FakeChiakiCall;

typedef struct FakeChiakiSessionRecord {
    ChiakiSession *session;
    ChiakiConnectInfo connect_info;
    char host[128];
    ChiakiLog *log;
    ChiakiEventCallback event_callback;
    void *event_user;
    ChiakiVideoSampleCallback video_callback;
    void *video_user;
    ChiakiAudioSink audio_sink;
    ChiakiCtrlDisplaySink display_sink;
    uint32_t callback_mask;
    ChiakiErrorCode init_result;
    ChiakiErrorCode start_result;
    unsigned int callback_install_calls;
    unsigned int callback_mask_calls;
    unsigned int start_calls;
    unsigned int stop_calls;
    unsigned int join_calls;
    unsigned int fini_calls;
    unsigned int controller_state_calls;
    unsigned int go_home_calls;
    unsigned int go_to_bed_calls;
    ChiakiControllerState last_controller_state;
} FakeChiakiSessionRecord;

typedef struct FakeChiakiRegistrationRecord {
    ChiakiRegist *registration;
    ChiakiRegistInfo info;
    char host[128];
    ChiakiRegistCb callback;
    void *callback_user;
    ChiakiErrorCode start_result;
    unsigned int stop_calls;
    unsigned int fini_calls;
} FakeChiakiRegistrationRecord;

typedef struct FakeChiakiRuntimeState {
    unsigned int library_init_calls;
    unsigned int log_init_calls;
    uint32_t last_log_level_mask;
    ChiakiLogCallback last_log_callback;
    void *last_log_user;
    unsigned int wake_calls;
    uint64_t last_wake_credential;
    bool last_wake_was_ps5;
    bool last_wake_discovery_was_null;
    char last_wake_host[128];
    unsigned int opus_decoder_init_calls;
    unsigned int opus_decoder_fini_calls;
    FakeChiakiSessionRecord sessions[FAKE_CHIAKI_MAX_SESSION_RECORDS];
    size_t session_count;
    FakeChiakiRegistrationRecord registrations[FAKE_CHIAKI_MAX_REGISTRATION_RECORDS];
    size_t registration_count;
    FakeChiakiCall calls[FAKE_CHIAKI_MAX_CALLS];
    size_t call_count;
} FakeChiakiRuntimeState;

void fake_chiaki_runtime_reset(void);
const FakeChiakiRuntimeState *fake_chiaki_runtime_state(void);
const FakeChiakiSessionRecord *fake_chiaki_session_record(size_t index);
void fake_chiaki_set_next_session_init_result(ChiakiErrorCode result);
void fake_chiaki_set_next_session_start_result(ChiakiErrorCode result);
void fake_chiaki_set_next_session_stop_result(ChiakiErrorCode result);
void fake_chiaki_set_next_session_join_result(ChiakiErrorCode result);
void fake_chiaki_set_next_controller_state_result(ChiakiErrorCode result);
void fake_chiaki_set_next_go_home_result(ChiakiErrorCode result);
void fake_chiaki_set_next_go_to_bed_result(ChiakiErrorCode result);
void fake_chiaki_set_callback_mask_override(bool enabled, uint32_t callback_mask);
void fake_chiaki_set_next_registration_start_result(ChiakiErrorCode result);
const FakeChiakiRegistrationRecord *fake_chiaki_registration_record(size_t index);
bool fake_chiaki_emit_registration(
    size_t registration_record_index,
    ChiakiRegistEventType event_type,
    ChiakiRegisteredHost *registered_host);
bool fake_chiaki_emit_event(
    size_t session_record_index,
    ChiakiEventType event_type,
    ChiakiQuitReason quit_reason);
bool fake_chiaki_emit_raw_event(
    size_t session_record_index,
    const ChiakiEvent *event);
bool fake_chiaki_emit_video(
    size_t session_record_index,
    uint8_t *buffer,
    size_t buffer_size,
    int32_t frames_lost,
    bool frame_recovered,
    bool *accepted);
bool fake_chiaki_emit_audio_header(
    size_t session_record_index,
    ChiakiAudioHeader *header);
bool fake_chiaki_emit_audio_frame(
    size_t session_record_index,
    uint8_t *buffer,
    size_t buffer_size);
bool fake_chiaki_emit_display_state(
    size_t session_record_index,
    bool cannot_display);

#endif
