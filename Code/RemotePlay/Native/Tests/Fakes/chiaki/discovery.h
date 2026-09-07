#ifndef REMOTE_PLAY_TEST_FAKE_CHIAKI_DISCOVERY_H
#define REMOTE_PLAY_TEST_FAKE_CHIAKI_DISCOVERY_H

#include <chiaki/common.h>
#include <chiaki/log.h>
#include <stdbool.h>
#include <stdint.h>

typedef struct ChiakiDiscovery {
    uint32_t unused;
} ChiakiDiscovery;

ChiakiErrorCode chiaki_discovery_wakeup(
    ChiakiLog *log,
    ChiakiDiscovery *discovery,
    const char *host,
    uint64_t user_credential,
    bool ps5);

#endif
