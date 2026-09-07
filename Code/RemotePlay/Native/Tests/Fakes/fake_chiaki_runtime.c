#include "fake_chiaki_runtime.h"

#include <chiaki/opusdecoder.h>
#include <stdio.h>
#include <string.h>

static FakeChiakiRuntimeState runtime_state;
static ChiakiErrorCode next_session_init_result = CHIAKI_ERR_SUCCESS;
static ChiakiErrorCode next_session_start_result = CHIAKI_ERR_SUCCESS;
static ChiakiErrorCode next_session_stop_result = CHIAKI_ERR_SUCCESS;
static ChiakiErrorCode next_session_join_result = CHIAKI_ERR_SUCCESS;
static ChiakiErrorCode next_controller_state_result = CHIAKI_ERR_SUCCESS;
static ChiakiErrorCode next_go_home_result = CHIAKI_ERR_SUCCESS;
static ChiakiErrorCode next_go_to_bed_result = CHIAKI_ERR_SUCCESS;
static ChiakiErrorCode next_registration_start_result = CHIAKI_ERR_SUCCESS;
static bool callback_mask_override_enabled;
static uint32_t callback_mask_override;

static void record_call(FakeChiakiCallType type, size_t session_record_index)
{
    if(runtime_state.call_count >= FAKE_CHIAKI_MAX_CALLS)
        return;
    runtime_state.calls[runtime_state.call_count++] = (FakeChiakiCall) {
        .type = type,
        .session_record_index = session_record_index,
    };
}

static size_t latest_record_index_for_session(ChiakiSession *session)
{
    for(size_t index = runtime_state.session_count; index > 0; index--)
    {
        if(runtime_state.sessions[index - 1].session == session)
            return index - 1;
    }
    return SIZE_MAX;
}

static FakeChiakiSessionRecord *latest_record_for_session(ChiakiSession *session)
{
    const size_t index = latest_record_index_for_session(session);
    return index == SIZE_MAX ? NULL : &runtime_state.sessions[index];
}

void fake_chiaki_runtime_reset(void)
{
    memset(&runtime_state, 0, sizeof(runtime_state));
    next_session_init_result = CHIAKI_ERR_SUCCESS;
    next_session_start_result = CHIAKI_ERR_SUCCESS;
    next_session_stop_result = CHIAKI_ERR_SUCCESS;
    next_session_join_result = CHIAKI_ERR_SUCCESS;
    next_controller_state_result = CHIAKI_ERR_SUCCESS;
    next_go_home_result = CHIAKI_ERR_SUCCESS;
    next_go_to_bed_result = CHIAKI_ERR_SUCCESS;
    next_registration_start_result = CHIAKI_ERR_SUCCESS;
    callback_mask_override_enabled = false;
    callback_mask_override = 0;
}

void fake_chiaki_set_next_registration_start_result(ChiakiErrorCode result)
{
    next_registration_start_result = result;
}

const FakeChiakiRegistrationRecord *fake_chiaki_registration_record(size_t index)
{
    if(index >= runtime_state.registration_count)
        return NULL;
    return &runtime_state.registrations[index];
}

bool fake_chiaki_emit_registration(
    size_t registration_record_index,
    ChiakiRegistEventType event_type,
    ChiakiRegisteredHost *registered_host)
{
    if(registration_record_index >= runtime_state.registration_count)
        return false;
    FakeChiakiRegistrationRecord *record =
        &runtime_state.registrations[registration_record_index];
    if(record->fini_calls != 0 || !record->callback || !record->callback_user)
        return false;
    ChiakiRegistEvent event = {
        .type = event_type,
        .registered_host = registered_host,
    };
    record->callback(&event, record->callback_user);
    return true;
}

const FakeChiakiRuntimeState *fake_chiaki_runtime_state(void)
{
    return &runtime_state;
}

const FakeChiakiSessionRecord *fake_chiaki_session_record(size_t index)
{
    if(index >= runtime_state.session_count)
        return NULL;
    return &runtime_state.sessions[index];
}

void fake_chiaki_set_next_session_init_result(ChiakiErrorCode result)
{
    next_session_init_result = result;
}

void fake_chiaki_set_next_session_start_result(ChiakiErrorCode result)
{
    next_session_start_result = result;
}

void fake_chiaki_set_next_session_stop_result(ChiakiErrorCode result)
{
    next_session_stop_result = result;
}

void fake_chiaki_set_next_session_join_result(ChiakiErrorCode result)
{
    next_session_join_result = result;
}

void fake_chiaki_set_next_controller_state_result(ChiakiErrorCode result)
{
    next_controller_state_result = result;
}

void fake_chiaki_set_next_go_home_result(ChiakiErrorCode result)
{
    next_go_home_result = result;
}

void fake_chiaki_set_next_go_to_bed_result(ChiakiErrorCode result)
{
    next_go_to_bed_result = result;
}

void fake_chiaki_set_callback_mask_override(bool enabled, uint32_t callback_mask)
{
    callback_mask_override_enabled = enabled;
    callback_mask_override = callback_mask;
}

bool fake_chiaki_emit_event(
    size_t session_record_index,
    ChiakiEventType event_type,
    ChiakiQuitReason quit_reason)
{
    if(session_record_index >= runtime_state.session_count)
        return false;

    FakeChiakiSessionRecord *record = &runtime_state.sessions[session_record_index];
    if(record->fini_calls != 0 || !record->event_callback || !record->event_user)
        return false;

    ChiakiEvent event = { .type = event_type };
    if(event_type == CHIAKI_EVENT_QUIT)
        event.quit.reason = quit_reason;
    record->event_callback(&event, record->event_user);
    return true;
}

bool fake_chiaki_emit_raw_event(
    size_t session_record_index,
    const ChiakiEvent *event)
{
    if(session_record_index >= runtime_state.session_count || !event)
        return false;

    FakeChiakiSessionRecord *record = &runtime_state.sessions[session_record_index];
    if(record->fini_calls != 0 || !record->event_callback || !record->event_user)
        return false;

    ChiakiEvent copy = *event;
    record->event_callback(&copy, record->event_user);
    return true;
}

bool fake_chiaki_emit_video(
    size_t session_record_index,
    uint8_t *buffer,
    size_t buffer_size,
    int32_t frames_lost,
    bool frame_recovered,
    bool *accepted)
{
    if(session_record_index >= runtime_state.session_count || !accepted)
        return false;
    FakeChiakiSessionRecord *record = &runtime_state.sessions[session_record_index];
    if(record->fini_calls != 0 || !record->video_callback || !record->video_user)
        return false;
    *accepted = record->video_callback(
        buffer,
        buffer_size,
        frames_lost,
        frame_recovered,
        record->video_user);
    return true;
}

bool fake_chiaki_emit_audio_header(
    size_t session_record_index,
    ChiakiAudioHeader *header)
{
    if(session_record_index >= runtime_state.session_count || !header)
        return false;
    FakeChiakiSessionRecord *record = &runtime_state.sessions[session_record_index];
    if(record->fini_calls != 0 || !record->audio_sink.header_cb ||
       !record->audio_sink.user)
        return false;
    record->audio_sink.header_cb(header, record->audio_sink.user);
    return true;
}

bool fake_chiaki_emit_audio_frame(
    size_t session_record_index,
    uint8_t *buffer,
    size_t buffer_size)
{
    if(session_record_index >= runtime_state.session_count || !buffer || buffer_size == 0)
        return false;
    FakeChiakiSessionRecord *record = &runtime_state.sessions[session_record_index];
    if(record->fini_calls != 0 || !record->audio_sink.frame_cb ||
       !record->audio_sink.user)
        return false;
    record->audio_sink.frame_cb(buffer, buffer_size, record->audio_sink.user);
    return true;
}

bool fake_chiaki_emit_display_state(
    size_t session_record_index,
    bool cannot_display)
{
    if(session_record_index >= runtime_state.session_count)
        return false;
    FakeChiakiSessionRecord *record = &runtime_state.sessions[session_record_index];
    if(record->fini_calls != 0 || !record->display_sink.cantdisplay_cb ||
       !record->display_sink.user)
        return false;
    record->display_sink.cantdisplay_cb(record->display_sink.user, cannot_display);
    return true;
}

static void fake_opus_header(ChiakiAudioHeader *header, void *user)
{
    ChiakiOpusDecoder *decoder = user;
    if(!decoder || !decoder->initialized || !header)
        return;
    decoder->audio_header = *header;
    if(decoder->settings_callback)
        decoder->settings_callback(
            header->channels,
            header->rate,
            decoder->callback_user);
}

static void fake_opus_frame(uint8_t *buffer, size_t buffer_size, void *user)
{
    ChiakiOpusDecoder *decoder = user;
    if(!decoder || !decoder->initialized || !buffer ||
       decoder->audio_header.channels == 0 || !decoder->frame_callback)
        return;
    const size_t bytes_per_frame =
        (size_t)decoder->audio_header.channels * sizeof(int16_t);
    if(bytes_per_frame == 0 || buffer_size % bytes_per_frame != 0)
        return;
    decoder->frame_callback(
        (int16_t *)buffer,
        buffer_size / bytes_per_frame,
        decoder->callback_user);
}

void chiaki_opus_decoder_init(ChiakiOpusDecoder *decoder, ChiakiLog *log)
{
    if(!decoder)
        return;
    memset(decoder, 0, sizeof(*decoder));
    decoder->log = log;
    decoder->initialized = true;
    runtime_state.opus_decoder_init_calls++;
}

void chiaki_opus_decoder_fini(ChiakiOpusDecoder *decoder)
{
    if(!decoder || !decoder->initialized)
        return;
    decoder->initialized = false;
    runtime_state.opus_decoder_fini_calls++;
}

void chiaki_opus_decoder_get_sink(ChiakiOpusDecoder *decoder, ChiakiAudioSink *sink)
{
    if(!decoder || !sink)
        return;
    sink->user = decoder;
    sink->header_cb = fake_opus_header;
    sink->frame_cb = fake_opus_frame;
}

ChiakiErrorCode chiaki_lib_init(void)
{
    runtime_state.library_init_calls++;
    return CHIAKI_ERR_SUCCESS;
}

const char *chiaki_error_string(ChiakiErrorCode error)
{
    (void)error;
    return "Fake Chiaki error";
}

void chiaki_log_init(
    ChiakiLog *log,
    uint32_t level_mask,
    ChiakiLogCallback callback,
    void *user)
{
    runtime_state.log_init_calls++;
    runtime_state.last_log_level_mask = level_mask;
    runtime_state.last_log_callback = callback;
    runtime_state.last_log_user = user;
    if(log)
    {
        log->initialized = 1;
        log->level_mask = level_mask;
        log->callback = callback;
        log->user = user;
    }
}

ChiakiErrorCode chiaki_discovery_wakeup(
    ChiakiLog *log,
    ChiakiDiscovery *discovery,
    const char *host,
    uint64_t user_credential,
    bool ps5)
{
    if(!log || log->initialized != 1 || !host)
        return CHIAKI_ERR_UNKNOWN;

    runtime_state.wake_calls++;
    runtime_state.last_wake_credential = user_credential;
    runtime_state.last_wake_was_ps5 = ps5;
    runtime_state.last_wake_discovery_was_null = discovery == NULL;
    snprintf(runtime_state.last_wake_host, sizeof(runtime_state.last_wake_host), "%s", host);
    return CHIAKI_ERR_SUCCESS;
}

ChiakiErrorCode chiaki_regist_start(
    ChiakiRegist *registration,
    ChiakiLog *log,
    const ChiakiRegistInfo *info,
    ChiakiRegistCb callback,
    void *callback_user)
{
    if(!registration || !log || !info || !info->host || !callback || !callback_user ||
       runtime_state.registration_count >= FAKE_CHIAKI_MAX_REGISTRATION_RECORDS)
        return CHIAKI_ERR_UNKNOWN;

    const size_t index = runtime_state.registration_count++;
    FakeChiakiRegistrationRecord *record = &runtime_state.registrations[index];
    memset(record, 0, sizeof(*record));
    record->registration = registration;
    record->info = *info;
    snprintf(record->host, sizeof(record->host), "%s", info->host);
    record->info.host = record->host;
    record->callback = callback;
    record->callback_user = callback_user;
    record->start_result = next_registration_start_result;
    next_registration_start_result = CHIAKI_ERR_SUCCESS;

    registration->log = log;
    registration->info = record->info;
    registration->callback = callback;
    registration->callback_user = callback_user;
    record_call(FAKE_CHIAKI_CALL_REGISTRATION_START, index);
    return record->start_result;
}

void chiaki_regist_stop(ChiakiRegist *registration)
{
    for(size_t index = runtime_state.registration_count; index > 0; index--)
    {
        FakeChiakiRegistrationRecord *record = &runtime_state.registrations[index - 1];
        if(record->registration == registration)
        {
            record->stop_calls++;
            record_call(FAKE_CHIAKI_CALL_REGISTRATION_STOP, index - 1);
            return;
        }
    }
}

void chiaki_regist_fini(ChiakiRegist *registration)
{
    for(size_t index = runtime_state.registration_count; index > 0; index--)
    {
        FakeChiakiRegistrationRecord *record = &runtime_state.registrations[index - 1];
        if(record->registration == registration)
        {
            record->fini_calls++;
            record_call(FAKE_CHIAKI_CALL_REGISTRATION_FINI, index - 1);
            return;
        }
    }
}

ChiakiErrorCode chiaki_session_init(
    ChiakiSession *session,
    ChiakiConnectInfo *connect_info,
    ChiakiLog *log)
{
    if(!session || !connect_info || !log ||
       runtime_state.session_count >= FAKE_CHIAKI_MAX_SESSION_RECORDS)
        return CHIAKI_ERR_UNKNOWN;

    const size_t index = runtime_state.session_count++;
    FakeChiakiSessionRecord *record = &runtime_state.sessions[index];
    memset(record, 0, sizeof(*record));
    record->session = session;
    record->connect_info = *connect_info;
    snprintf(record->host, sizeof(record->host), "%s", connect_info->host);
    record->connect_info.host = record->host;
    record->log = log;
    record->init_result = next_session_init_result;
    next_session_init_result = CHIAKI_ERR_SUCCESS;
    record_call(FAKE_CHIAKI_CALL_SESSION_INIT, index);
    return record->init_result;
}

void chiaki_session_fini(ChiakiSession *session)
{
    const size_t index = latest_record_index_for_session(session);
    FakeChiakiSessionRecord *record = latest_record_for_session(session);
    if(!record)
        return;
    record->fini_calls++;
    record_call(FAKE_CHIAKI_CALL_SESSION_FINI, index);
}

ChiakiErrorCode chiaki_session_start(ChiakiSession *session)
{
    const size_t index = latest_record_index_for_session(session);
    FakeChiakiSessionRecord *record = latest_record_for_session(session);
    if(!record)
        return CHIAKI_ERR_UNKNOWN;
    record->start_calls++;
    record->start_result = next_session_start_result;
    next_session_start_result = CHIAKI_ERR_SUCCESS;
    record_call(FAKE_CHIAKI_CALL_SESSION_START, index);
    return record->start_result;
}

ChiakiErrorCode chiaki_session_stop(ChiakiSession *session)
{
    const size_t index = latest_record_index_for_session(session);
    FakeChiakiSessionRecord *record = latest_record_for_session(session);
    if(!record)
        return CHIAKI_ERR_UNKNOWN;
    record->stop_calls++;
    record_call(FAKE_CHIAKI_CALL_SESSION_STOP, index);
    const ChiakiErrorCode result = next_session_stop_result;
    next_session_stop_result = CHIAKI_ERR_SUCCESS;
    return result;
}

ChiakiErrorCode chiaki_session_join(ChiakiSession *session)
{
    const size_t index = latest_record_index_for_session(session);
    FakeChiakiSessionRecord *record = latest_record_for_session(session);
    if(!record)
        return CHIAKI_ERR_UNKNOWN;
    record->join_calls++;
    record_call(FAKE_CHIAKI_CALL_SESSION_JOIN, index);
    const ChiakiErrorCode result = next_session_join_result;
    next_session_join_result = CHIAKI_ERR_SUCCESS;
    return result;
}

void chiaki_controller_state_set_idle(ChiakiControllerState *state)
{
    if(!state)
        return;
    memset(state, 0, sizeof(*state));
    for(size_t index = 0; index < CHIAKI_CONTROLLER_TOUCHES_MAX; index++)
        state->touches[index].id = -1;
    state->orient_w = 1.0f;
}

ChiakiErrorCode chiaki_session_set_controller_state(
    ChiakiSession *session,
    ChiakiControllerState *state)
{
    const size_t index = latest_record_index_for_session(session);
    FakeChiakiSessionRecord *record = latest_record_for_session(session);
    if(!record || !state)
        return CHIAKI_ERR_UNKNOWN;
    record->controller_state_calls++;
    record->last_controller_state = *state;
    record_call(FAKE_CHIAKI_CALL_CONTROLLER_STATE, index);
    const ChiakiErrorCode result = next_controller_state_result;
    next_controller_state_result = CHIAKI_ERR_SUCCESS;
    return result;
}

ChiakiErrorCode chiaki_session_go_home(ChiakiSession *session)
{
    const size_t index = latest_record_index_for_session(session);
    FakeChiakiSessionRecord *record = latest_record_for_session(session);
    if(!record)
        return CHIAKI_ERR_UNKNOWN;
    record->go_home_calls++;
    record_call(FAKE_CHIAKI_CALL_GO_HOME, index);
    const ChiakiErrorCode result = next_go_home_result;
    next_go_home_result = CHIAKI_ERR_SUCCESS;
    return result;
}

ChiakiErrorCode chiaki_session_goto_bed(ChiakiSession *session)
{
    const size_t index = latest_record_index_for_session(session);
    FakeChiakiSessionRecord *record = latest_record_for_session(session);
    if(!record)
        return CHIAKI_ERR_UNKNOWN;
    record->go_to_bed_calls++;
    record_call(FAKE_CHIAKI_CALL_GO_TO_BED, index);
    const ChiakiErrorCode result = next_go_to_bed_result;
    next_go_to_bed_result = CHIAKI_ERR_SUCCESS;
    return result;
}

void chiaki_session_set_callbacks_runtime(
    ChiakiSession *session,
    ChiakiEventCallback event_callback,
    void *event_user,
    ChiakiVideoSampleCallback video_callback,
    void *video_user,
    ChiakiAudioSink *audio_sink,
    ChiakiCtrlDisplaySink *display_sink)
{
    const size_t index = latest_record_index_for_session(session);
    FakeChiakiSessionRecord *record = latest_record_for_session(session);
    if(!record)
        return;

    record->callback_install_calls++;
    record->event_callback = event_callback;
    record->event_user = event_user;
    record->video_callback = video_callback;
    record->video_user = video_user;
    if(audio_sink)
        record->audio_sink = *audio_sink;
    if(display_sink)
        record->display_sink = *display_sink;
    record_call(FAKE_CHIAKI_CALL_SET_CALLBACKS, index);
}

uint32_t chiaki_session_callback_mask_runtime(ChiakiSession *session)
{
    const size_t index = latest_record_index_for_session(session);
    FakeChiakiSessionRecord *record = latest_record_for_session(session);
    if(!record)
        return 0;

    record->callback_mask_calls++;
    uint32_t mask = 0;
    if(record->event_callback && record->event_user)
        mask |= 1u << 0;
    if(record->video_callback && record->video_user)
        mask |= 1u << 1;
    if(record->audio_sink.header_cb && record->audio_sink.user)
        mask |= 1u << 2;
    if(record->audio_sink.frame_cb && record->audio_sink.user)
        mask |= 1u << 3;
    if(record->display_sink.cantdisplay_cb && record->display_sink.user)
        mask |= 1u << 4;
    record->callback_mask = mask;
    record_call(FAKE_CHIAKI_CALL_CALLBACK_MASK, index);
    return callback_mask_override_enabled ? callback_mask_override : mask;
}

size_t chiaki_session_runtime_size(void)
{
    return 256;
}

size_t chiaki_session_runtime_offset_video_sample_cb(void)
{
    return 32;
}

size_t chiaki_session_runtime_offset_audio_sink(void)
{
    return 64;
}

size_t chiaki_session_runtime_offset_display_sink(void)
{
    return 96;
}
