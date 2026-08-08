#ifndef GHOST_HTTP3_H
#define GHOST_HTTP3_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "quiche.h"

#ifdef __cplusplus
extern "C" {
#endif

/// The stable GhostHTTP3 wrapper API version.
#define GHOST_HTTP3_API_VERSION 1

/// Returns the GhostHTTP3 wrapper API version.
uint32_t ghost_http3_api_version(void);

/// Returns the version string reported by the linked quiche backend.
const char *ghost_http3_backend_version(void);

/// Returns quiche's length-prefixed HTTP/3 ALPN list (currently `h3`).
/// The returned bytes have static storage duration.
const uint8_t *ghost_http3_application_protocol(size_t *length);

/// Performs a lightweight runtime check that both QUIC and HTTP/3
/// configuration objects can be created by the linked backend.
bool ghost_http3_backend_is_ready(void);

#ifdef __cplusplus
} // extern "C"
#endif

#endif // GHOST_HTTP3_H
