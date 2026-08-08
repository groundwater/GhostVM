#include <GhostHTTP3/GhostHTTP3.h>

uint32_t ghost_http3_api_version(void) {
    return GHOST_HTTP3_API_VERSION;
}

const char *ghost_http3_backend_version(void) {
    return quiche_version();
}

const uint8_t *ghost_http3_application_protocol(size_t *length) {
    static const uint8_t protocol[] = QUICHE_H3_APPLICATION_PROTOCOL;

    if (length != NULL) {
        *length = sizeof(protocol) - 1;
    }

    return protocol;
}

bool ghost_http3_backend_is_ready(void) {
    quiche_config *quic = quiche_config_new(QUICHE_PROTOCOL_VERSION);
    if (quic == NULL) {
        return false;
    }

    quiche_h3_config *http3 = quiche_h3_config_new();
    if (http3 == NULL) {
        quiche_config_free(quic);
        return false;
    }

    quiche_h3_config_free(http3);
    quiche_config_free(quic);
    return true;
}
