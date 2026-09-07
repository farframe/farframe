#ifndef REMOTE_PLAY_TEST_FAKE_CHIAKI_COMMON_H
#define REMOTE_PLAY_TEST_FAKE_CHIAKI_COMMON_H

#include <stdbool.h>
#include <stdint.h>

typedef int32_t ChiakiErrorCode;

enum {
    CHIAKI_ERR_SUCCESS = 0,
    CHIAKI_ERR_UNKNOWN = 1,
    CHIAKI_ERR_THREAD = 2,
    CHIAKI_ERR_UNINITIALIZED = 3,
};

typedef enum ChiakiTarget {
    CHIAKI_TARGET_PS4_UNKNOWN = 0,
    CHIAKI_TARGET_PS5_1 = 1000,
} ChiakiTarget;

typedef enum ChiakiCodec {
    CHIAKI_CODEC_H264 = 0,
    CHIAKI_CODEC_H265 = 1,
    CHIAKI_CODEC_H265_HDR = 2,
} ChiakiCodec;

ChiakiErrorCode chiaki_lib_init(void);
const char *chiaki_error_string(ChiakiErrorCode error);

#endif
