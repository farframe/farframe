#ifndef REMOTE_PLAY_TEST_FAKE_CHIAKI_LOG_H
#define REMOTE_PLAY_TEST_FAKE_CHIAKI_LOG_H

#include <stdint.h>

typedef int32_t ChiakiLogLevel;

enum {
    CHIAKI_LOG_ERROR = 1,
};

typedef void (*ChiakiLogCallback)(ChiakiLogLevel level, const char *message, void *user);

typedef struct ChiakiLog {
    uint32_t initialized;
    uint32_t level_mask;
    ChiakiLogCallback callback;
    void *user;
} ChiakiLog;

void chiaki_log_init(
    ChiakiLog *log,
    uint32_t level_mask,
    ChiakiLogCallback callback,
    void *user);

#endif
