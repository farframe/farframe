#ifndef REMOTE_PLAY_TEST_FAKE_CHIAKI_AUDIO_H
#define REMOTE_PLAY_TEST_FAKE_CHIAKI_AUDIO_H

#include <stdint.h>

typedef struct chiaki_audio_header_t {
    uint8_t channels;
    uint8_t bits;
    uint32_t rate;
    uint32_t frame_size;
    uint32_t unknown;
} ChiakiAudioHeader;

#endif
