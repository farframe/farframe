#ifndef REMOTE_PLAY_TEST_FAKE_CHIAKI_REGIST_H
#define REMOTE_PLAY_TEST_FAKE_CHIAKI_REGIST_H

#include "common.h"
#include "log.h"

#include <stdbool.h>
#include <stdint.h>

#ifndef CHIAKI_PSN_ACCOUNT_ID_SIZE
#define CHIAKI_PSN_ACCOUNT_ID_SIZE 8u
#endif
#ifndef CHIAKI_SESSION_AUTH_SIZE
#define CHIAKI_SESSION_AUTH_SIZE 16u
#endif

typedef struct ChiakiRegistInfo {
    ChiakiTarget target;
    const char *host;
    bool broadcast;
    const char *psn_online_id;
    uint8_t psn_account_id[CHIAKI_PSN_ACCOUNT_ID_SIZE];
    uint32_t pin;
    uint32_t console_pin;
    void *holepunch_info;
    void *rudp;
} ChiakiRegistInfo;

typedef struct ChiakiRegisteredHost {
    ChiakiTarget target;
    char ap_ssid[0x30];
    char ap_bssid[0x20];
    char ap_key[0x50];
    char ap_name[0x20];
    uint8_t server_mac[6];
    char server_nickname[0x20];
    char rp_regist_key[CHIAKI_SESSION_AUTH_SIZE];
    uint32_t rp_key_type;
    uint8_t rp_key[0x10];
    uint32_t console_pin;
} ChiakiRegisteredHost;

typedef enum ChiakiRegistEventType {
    CHIAKI_REGIST_EVENT_TYPE_FINISHED_CANCELED,
    CHIAKI_REGIST_EVENT_TYPE_FINISHED_FAILED,
    CHIAKI_REGIST_EVENT_TYPE_FINISHED_SUCCESS,
} ChiakiRegistEventType;

typedef struct ChiakiRegistEvent {
    ChiakiRegistEventType type;
    ChiakiRegisteredHost *registered_host;
} ChiakiRegistEvent;

typedef void (*ChiakiRegistCb)(ChiakiRegistEvent *event, void *user);

typedef struct ChiakiRegist {
    ChiakiLog *log;
    ChiakiRegistInfo info;
    ChiakiRegistCb callback;
    void *callback_user;
} ChiakiRegist;

ChiakiErrorCode chiaki_regist_start(
    ChiakiRegist *registration,
    ChiakiLog *log,
    const ChiakiRegistInfo *info,
    ChiakiRegistCb callback,
    void *callback_user);
void chiaki_regist_fini(ChiakiRegist *registration);
void chiaki_regist_stop(ChiakiRegist *registration);

#endif
