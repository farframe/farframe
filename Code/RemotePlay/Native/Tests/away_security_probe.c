/* Diagnostic only: synthetic keys, no console/account data. Never an app entry point. */
#include <chiaki/ecdh.h>
#include <curl/curl.h>
#include <stdio.h>
#include <string.h>

static size_t discard(void *data, size_t size, size_t count, void *user) {
    (void)data; (void)user; return size * count;
}

/* https:// only, no userinfo. Do not print the argument; it may be sensitive. */
static int https_url_without_userinfo(const char *url) {
    const char *host, *slash, *at;
    if(!url || strncmp(url, "https://", 8) != 0)
        return 0;
    host = url + 8;
    if(!*host || *host == '/' || *host == '?' || *host == '#')
        return 0;
    slash = strpbrk(host, "/?#");
    at = strchr(host, '@');
    if(at && (!slash || at < slash))
        return 0;
    return 1;
}

static int tls_proof(const char *url) {
    curl_version_info_data *info;
    CURL *request;
    CURLcode result;
    long verify_result = -1;
    if(!https_url_without_userinfo(url)) {
        fprintf(stderr, "tls-proof rejected URL: require https without credentials\n");
        return 2;
    }
    if(curl_global_init(CURL_GLOBAL_DEFAULT))
        return 10;
    request = curl_easy_init();
    if(!request) {
        curl_global_cleanup();
        return 10;
    }
    info = curl_version_info(CURLVERSION_NOW);
    printf("tls-proof (not Away-ready)\n");
    printf("ssl-backend=%s\n", (info && info->ssl_version && info->ssl_version[0]) ? info->ssl_version : "unknown");
    printf("curl-version=%s\n", (info && info->version) ? info->version : "unknown");
    printf("verify-peer=1 verify-host=2 protocols=https followlocation=0\n");
    if(curl_easy_setopt(request, CURLOPT_URL, url) ||
       curl_easy_setopt(request, CURLOPT_PROTOCOLS_STR, "https") ||
       curl_easy_setopt(request, CURLOPT_REDIR_PROTOCOLS_STR, "https") ||
       curl_easy_setopt(request, CURLOPT_SSL_VERIFYPEER, 1L) ||
       curl_easy_setopt(request, CURLOPT_SSL_VERIFYHOST, 2L) ||
       curl_easy_setopt(request, CURLOPT_NOBODY, 1L) ||
       curl_easy_setopt(request, CURLOPT_WRITEFUNCTION, discard) ||
       curl_easy_setopt(request, CURLOPT_HEADERFUNCTION, discard) ||
       curl_easy_setopt(request, CURLOPT_TIMEOUT, 15L) ||
       curl_easy_setopt(request, CURLOPT_CONNECTTIMEOUT, 10L) ||
       curl_easy_setopt(request, CURLOPT_FOLLOWLOCATION, 0L) ||
       curl_easy_setopt(request, CURLOPT_USERPWD, NULL) ||
       curl_easy_setopt(request, CURLOPT_COOKIE, NULL) ||
       curl_easy_setopt(request, CURLOPT_NETRC, (long)CURL_NETRC_IGNORED)) {
        curl_easy_cleanup(request);
        curl_global_cleanup();
        return 10;
    }
    /* Default trust of this linked backend. No CAINFO, CAPATH, or verify bypass. */
    result = curl_easy_perform(request);
    curl_easy_getinfo(request, CURLINFO_SSL_VERIFYRESULT, &verify_result);
    printf("native-TLS result=%d (%s) ssl-verify-result=%ld\n",
           (int)result, curl_easy_strerror(result), verify_result);
    curl_easy_cleanup(request);
    curl_global_cleanup();
    return result == CURLE_OK ? 0 : 4;
}

int main(int argc, char **argv) {
    ChiakiECDH first, second;
    unsigned char key[128], signature[64], handshake[16] = {1}, good[32] = {0}, changed[32] = {0};
    size_t key_size = sizeof(key), signature_size = sizeof(signature);
    int valid, altered, equal;
    if(argc >= 2 && strcmp(argv[1], "trust") == 0) {
        if(argc != 3) {
            fprintf(stderr, "Usage: %s trust HTTPS_URL\n", argv[0]);
            return 64;
        }
        return tls_proof(argv[2]);
    }
    if(argc != 1) {
        fprintf(stderr, "Usage: %s\n       %s trust HTTPS_URL\n", argv[0], argv[0]);
        return 64;
    }
    if(chiaki_ecdh_init(&first) || chiaki_ecdh_init(&second)) return 10;
    if(chiaki_ecdh_get_local_pub_key(&second, key, &key_size, handshake, signature, &signature_size)) return 11;
    valid = chiaki_ecdh_derive_secret(&first, good, key, key_size, handshake, signature, signature_size);
    signature[0] ^= 0xff;
    altered = chiaki_ecdh_derive_secret(&first, changed, key, key_size, handshake, signature, signature_size);
    equal = memcmp(good, changed, sizeof(good)) == 0;
    printf("synthetic-ECDH valid=%d altered-signature=%d equal-secret=%d\n", valid, altered, equal);
    chiaki_ecdh_fini(&first); chiaki_ecdh_fini(&second);
    memset(good, 0, sizeof(good)); memset(changed, 0, sizeof(changed));
    /* A success with a modified signature is a failed expansion gate. It does
       not by itself establish exploitability of the complete wire protocol. */
    return valid == 0 && altered != 0 ? 0 : 3;
}
