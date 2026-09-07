#ifndef REMOTE_PLAY_TEST_FAKE_CHIAKI_OPUS_DECODER_H
#define REMOTE_PLAY_TEST_FAKE_CHIAKI_OPUS_DECODER_H

#include <chiaki/audio.h>
#include <chiaki/log.h>
#include <chiaki/session.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef void (*ChiakiOpusDecoderSettingsCallback)(
    uint32_t channels,
    uint32_t rate,
    void *user);
typedef void (*ChiakiOpusDecoderFrameCallback)(
    int16_t *buffer,
    size_t frame_count,
    void *user);

typedef struct chiaki_opus_decoder_t {
    ChiakiLog *log;
    ChiakiAudioHeader audio_header;
    ChiakiOpusDecoderSettingsCallback settings_callback;
    ChiakiOpusDecoderFrameCallback frame_callback;
    void *callback_user;
    bool initialized;
} ChiakiOpusDecoder;

void chiaki_opus_decoder_init(ChiakiOpusDecoder *decoder, ChiakiLog *log);
void chiaki_opus_decoder_fini(ChiakiOpusDecoder *decoder);
void chiaki_opus_decoder_get_sink(ChiakiOpusDecoder *decoder, ChiakiAudioSink *sink);

static inline void chiaki_opus_decoder_set_cb(
    ChiakiOpusDecoder *decoder,
    ChiakiOpusDecoderSettingsCallback settings_callback,
    ChiakiOpusDecoderFrameCallback frame_callback,
    void *user)
{
    decoder->settings_callback = settings_callback;
    decoder->frame_callback = frame_callback;
    decoder->callback_user = user;
}

#endif
