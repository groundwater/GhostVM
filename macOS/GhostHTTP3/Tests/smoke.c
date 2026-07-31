#include <GhostHTTP3/GhostHTTP3.h>

#include <stdio.h>
#include <string.h>

int main(void) {
    size_t alpn_length = 0;
    const uint8_t *alpn = ghost_http3_application_protocol(&alpn_length);

    if (ghost_http3_api_version() != GHOST_HTTP3_API_VERSION) {
        fprintf(stderr, "GhostHTTP3 API version mismatch\n");
        return 1;
    }

    if (!ghost_http3_backend_is_ready()) {
        fprintf(stderr, "quiche QUIC/HTTP3 backend failed its runtime check\n");
        return 2;
    }

    if (alpn_length != 3 || alpn[0] != 2 || memcmp(alpn + 1, "h3", 2) != 0) {
        fprintf(stderr, "unexpected HTTP/3 ALPN bytes\n");
        return 3;
    }

    printf("GhostHTTP3 API %u, quiche %s, ALPN h3\n",
           ghost_http3_api_version(), ghost_http3_backend_version());
    return 0;
}
