/* Diagnostic only: synthetic keys, no console/account data. Never an app entry point. */
#include <chiaki/ecdh.h>
#include <curl/curl.h>
#include <stdio.h>
#include <string.h>

static size_t discard(void *data, size_t size, size_t count, void *user) {
    (void)data; (void)user; return size * count;
}
int main(int argc, char **argv) {
    if(argc == 3 && strcmp(argv[1], "trust") == 0) {
        curl_global_init(CURL_GLOBAL_DEFAULT);
        CURL *request = curl_easy_init();
        if(!request) return 10;
        curl_easy_setopt(request, CURLOPT_URL, argv[2]);
        curl_easy_setopt(request, CURLOPT_PROTOCOLS_STR, "https");
        curl_easy_setopt(request, CURLOPT_NOBODY, 1L);
        curl_easy_setopt(request, CURLOPT_WRITEFUNCTION, discard);
        curl_easy_setopt(request, CURLOPT_TIMEOUT, 15L);
        curl_easy_setopt(request, CURLOPT_CONNECTTIMEOUT, 10L);
        curl_easy_setopt(request, CURLOPT_FOLLOWLOCATION, 0L);
        /* Preserve the native recipe's default trust. No custom CA or bypass. */
        CURLcode result = curl_easy_perform(request);
        printf("native-default-TLS result=%d (%s)\n", (int)result, curl_easy_strerror(result));
        curl_easy_cleanup(request); curl_global_cleanup();
        return result == CURLE_OK ? 0 : 4;
    }
    ChiakiECDH first, second;
    if(chiaki_ecdh_init(&first) || chiaki_ecdh_init(&second)) return 10;
    unsigned char key[128], signature[64], handshake[16] = {1}, good[32] = {0}, changed[32] = {0};
    size_t key_size = sizeof(key), signature_size = sizeof(signature);
    if(chiaki_ecdh_get_local_pub_key(&second, key, &key_size, handshake, signature, &signature_size)) return 11;
    int valid = chiaki_ecdh_derive_secret(&first, good, key, key_size, handshake, signature, signature_size);
    signature[0] ^= 0xff;
    int altered = chiaki_ecdh_derive_secret(&first, changed, key, key_size, handshake, signature, signature_size);
    int equal = memcmp(good, changed, sizeof(good)) == 0;
    printf("synthetic-ECDH valid=%d altered-signature=%d equal-secret=%d\n", valid, altered, equal);
    chiaki_ecdh_fini(&first); chiaki_ecdh_fini(&second);
    memset(good, 0, sizeof(good)); memset(changed, 0, sizeof(changed));
    /* A success with a modified signature is a failed expansion gate. It does
       not by itself establish exploitability of the complete wire protocol. */
    return valid == 0 && altered != 0 ? 0 : 3;
}
