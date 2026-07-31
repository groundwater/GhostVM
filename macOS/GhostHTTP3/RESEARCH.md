# HTTP/3 implementation selection

Decision recorded 2026-07-31: package Cloudflare quiche behind the standalone
GhostHTTP3 framework boundary.

## Candidates

### Google QUICHE

[Google QUICHE](https://quiche.googlesource.com/quiche/) is Google's
production-ready QUIC and HTTP/3 implementation and powers Google servers,
Chromium, and Envoy. It is reputable, but its upstream embedding instructions
say that embedders currently need to implement platform APIs and create build
files. Its documented standalone binaries target Linux. That makes it a poor
first fit for a small, signed macOS app framework despite the strength of the
implementation.

### Mozilla Neqo

[Mozilla Neqo](https://github.com/mozilla/neqo) is Firefox's Rust QUIC, HTTP/3,
and QPACK implementation. Mozilla states that its server functionality is
experimental, not used in production by Mozilla, not optimized for performance
or resource use, and should not be used in production. GhostFile needs a server
as a primary role, so Neqo was not selected.

### Cloudflare quiche

[Cloudflare quiche](https://github.com/cloudflare/quiche) implements IETF QUIC
and HTTP/3, powers Cloudflare's production edge, is used by Android's DNS
resolver, and can be integrated into curl. Its supported build emits native
library targets, including a `cdylib`, with a thin C FFI. The FFI includes the complete
HTTP/3 surface needed here: ALPN `h3`, SETTINGS, QPACK, request/response HEADERS,
DATA bodies, GOAWAY, stream events, and transport statistics.

This combination gives GhostFile a production-proven implementation with a
small and testable macOS integration surface. GhostHTTP3 builds quiche's
supported `cdylib` output for arm64 and packages that one dylib as a dynamic
framework; the backend can be upgraded or replaced without changing
GhostFile's HTTP resource model.

## GhostFile integration boundary

GhostFile will use regular RFC 9114 semantics over UDP/QUIC:

- standard HTTP methods and pseudoheaders;
- HTTP status codes and response headers;
- request and response bodies in HTTP/3 DATA frames;
- one HTTP request stream per independent filesystem operation;
- no GhostFile transport framing inside QUIC streams.

The existing mDNS discovery remains appropriate for the LAN. Its service
metadata should advertise `alpn=h3` and `transport=http3`; the discovered
endpoint feeds either this framework's client API or Apple's HTTP/3-capable
`URLSession` client.
