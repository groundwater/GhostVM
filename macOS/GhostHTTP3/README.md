# GhostHTTP3

GhostHTTP3 packages Cloudflare's production QUIC and RFC 9114 HTTP/3 stack as a
single arm64 dynamic macOS framework. The framework executable is a Mach-O
dylib that exposes quiche's complete C API (QUIC, HTTP/3, and QPACK) plus a
tiny, versioned GhostHTTP3 wrapper API.

This is a transport library, not the GhostFile protocol. GhostFile will use
ordinary HTTP request semantics (`GET`, `HEAD`, status codes, headers, and body
data) over the `h3` ALPN. There is no GhostFile-specific wire framing here.

## Build

Requirements:

- Xcode command-line tools
- Rust 1.88 or newer via `rustup`
- CMake and Ninja (used while building quiche's BoringSSL dependency)
- `libev` and `uthash` for the upstream C interoperability test

The native build/test dependencies can be installed with:

```sh
brew install cmake ninja libev uthash
```

Run:

```sh
macOS/GhostHTTP3/scripts/build-with-rust-dmg.sh
```

That command creates a reusable sparse read/write macOS disk image at
`macOS/GhostHTTP3/.build/toolchains/Rust-1.88.0-macOS-arm64.sparseimage`, mounts it at
`macOS/GhostHTTP3/.build/mount/GhostHTTP3Rust188`, installs the toolchain and the arm64 macOS Rust target
inside the image, then builds and tests the framework. Its logical capacity is
4 GB, but it consumes only the space actually written. It can be detached with:

```sh
hdiutil detach macOS/GhostHTTP3/.build/mount/GhostHTTP3Rust188
```

If an appropriate `rustup` toolchain is already on `PATH`, the lower-level
`build-framework.sh`, `test-framework.sh`, `test-stress.sh`, `test-http3.sh`,
and `test-chaos.sh` scripts can be run directly. The disk-image build command
runs them automatically after building the framework.

`test-http3.sh` compiles Cloudflare's C client and server against the generated
framework, exchanges `GET /` and an HTTP `200` response over loopback UDP, and
asserts that ALPN negotiated `h3`. This exercises HTTP/3 HEADERS, SETTINGS,
QPACK, DATA, and QUIC stream handling through the packaged library.

`test-stress.sh` links a deterministic two-endpoint harness against the same
framework. It establishes TLS over QUIC and exercises a 12 KiB QPACK header
block, an empty response, 96 multiplexed requests while an earlier request is
paused, 16 parallel 512 KiB response bodies with byte-for-byte validation,
single-stream cancellation, server-initiated stream reset, GOAWAY rejection,
bidi stream limit enforcement, application-level CONNECTION_CLOSE with peer-error
inspection, and an oversized-header rejection path that asserts the peer receives
`HTTP_EXCESSIVE_LOAD` (0x107). Application traffic is delivered in reversed
datagram batches to exercise QUIC packet reordering throughout those scenarios.
Set `GHOST_HTTP3_TEST_SANITIZERS=1` to compile the C harness with AddressSanitizer
and UndefinedBehaviorSanitizer.

`test-framework.sh` links and runs C and Swift consumers against the dynamic
framework, verifies its arm64-only architecture and `@rpath` install name, and
checks its ad-hoc build signature. A shipping app should embed the framework in
`Contents/Frameworks` and sign it with the app during the normal code-signing
phase.

`test-chaos.sh` builds a user-space UDP impairment proxy
(`Tests/udp-chaos-proxy.c`) and replays conservative, deterministic, seeded
impairments through the upstream C quiche examples over loopback. The five
gated impairment scenarios are: a transparency baseline, two-sided datagram
loss (4% c2s / 5% s2c), 10% duplication, delay+jitter+reorder, and a
deterministic 1350-byte MTU filter check. Each scenario asserts BOTH ends: the `http3-client` log proves
HTTP/3 success over QUIC (`200 "byez"`) AND the proxy's machine-parseable
`stats` lines prove each impairment actually fired (loss, dup, delayed,
reordered, drop_mtu). The MTU check completes real HTTP/3 exchanges and then
injects a harmless 1400-byte UDP sentinel to prove over-limit packets are
dropped without claiming flaky live-traffic black-hole recovery. The proxy's per-direction delayed-packet queues are
hard-bounded (`--queue`, default 256) with counted overflow drops, and every
test process terminates within `GHOST_HTTP3_CHAOS_PROXY_MAX_DURATION` (300s
default) plus a per-client watchdog. The gate also rejects forwarding errors
and any delayed datagrams still queued at shutdown.

`soak-chaos.sh` is an opt-in seed-progression soak that re-runs the chaos
scenarios across an advancing seed range with a wall-clock budget checked
between seeds. It is
explicitly off the gated path (enable with `GHOST_HTTP3_SOAK=1`).

## Environment variables

`GHOST_HTTP3_TEST_SANITIZERS=1` builds the C harness and the proxy with
AddressSanitizer and UndefinedBehaviorSanitizer.

`GHOST_HTTP3_BUILD_DIR` (all scripts) overrides the default
`.build` directory under the project root.

`GHOST_HTTP3_BUILD_DIR`, `MACOSX_DEPLOYMENT_TARGET`, and the rust toolchain
mount path (`GHOST_HTTP3_RUST_MOUNT`) affect `build-framework.sh` only.

`test-chaos.sh` knobs (read alongside the script for the full list):

| Variable | Default | Purpose |
| --- | --- | --- |
| `GHOST_HTTP3_CHAOS_SEED` | `7` | impairment PRNG seed; seed 7 is validated as stable |
| `GHOST_HTTP3_CHAOS_ITERATIONS` | `3` | client exchanges per scenario |
| `GHOST_HTTP3_CHAOS_PORT_BASE` | PID-derived | first candidate UDP port pair |
| `GHOST_HTTP3_CHAOS_SERVER_PORT` / `GHOST_HTTP3_CHAOS_PROXY_PORT` | unset | pin both ports (skip the scan) |
| `GHOST_HTTP3_CHAOS_CLIENT_TIMEOUT` | `25` | per-client watchdog (must exceed quiche's 5s idle timeout) |
| `GHOST_HTTP3_CHAOS_PROXY_MAX_DURATION` | `300` | proxy self-termination bound |
| `GHOST_HTTP3_CHAOS_HARSH` | `0` | opt-in harsh-loss reproducer documenting the example's idle-timeout limit |
| `GHOST_HTTP3_CHAOS_TOLERATE_STALL` | `0` | diagnostic escape hatch; when 1, stalls are counted and the run is explicitly not reported as a recovery gate |
| `GHOST_HTTP3_TEST_SANITIZERS` | `0` | build the proxy with ASan/UBSan |

`soak-chaos.sh` knobs:

| Variable | Default | Purpose |
| --- | --- | --- |
| `GHOST_HTTP3_SOAK_SEED_START` | `7` | first seed in the advancing range |
| `GHOST_HTTP3_SOAK_SEED_COUNT` | `5` | how many successive seeds to run |
| `GHOST_HTTP3_SOAK_MAX_SECONDS` | `240` | wall-clock budget checked between seeds (one in-flight seed can overshoot) |
| `GHOST_HTTP3_SOAK_MAX_ITERATIONS` | `0` | hard seed-count cap (0 = no cap) |
| `GHOST_HTTP3_SOAK_ITERATIONS` | `3` | per-seed chaos iterations |
| `GHOST_HTTP3_SOAK_SANITIZERS` | `0` | build the proxy with ASan/UBSan |
| `GHOST_HTTP3_SOAK_HARSH` | `0` | also run the harsh reproducer per seed |
| `GHOST_HTTP3_SOAK_QUIET` | `0` | suppress per-seed chaos output |

## Limitations (read before extending)

- The included driver is IPv4 / loopback only; both endpoints are on
  `127.0.0.1`. There is no second host involved and no need for elevated
  privileges. The proxy accepts remote listen/target addresses, but tracks one
  active client address at a time.
- The stock quiche `http3-server.c` / `http3-client.c` examples hard-code
  `max_idle_timeout = 5000ms`. When two-sided loss or an aggressive MTU
  black hole hits a
  handshake-critical flight, the example can stall until that timeout fires;
  `test-chaos.sh` uses a validated conservative profile, and `GHOST_HTTP3_CHAOS_HARSH=1`
  documents the failing edge as a reproducer rather than a regression. The
  soak classifies the same stall mode as STALLED (informational), not as a
  failure, so seed progression can advance across seeds that exercise the
  quiche example's hard limit without false-positive soak alarms.
- quiche's own `lost=` counter is `0` for the very short recovered flows used
  here; it is printed for information but not asserted. The proxy's own
  `drop_loss` counter is the source of truth.
- The combined multi-impairment scenario was pulled from the gated set on
  purpose: as soon as loss, dup, jitter, and MTU drop happen together, any of
  them can land on the 1-RTT flight inside the 5s idle window and stall the
  handshake non-deterministically across OS scheduling jitter. The five
  individual scenarios each prove one impairment class cleanly.
- The soak does not exercise the harsh-loss reproducer unless
  `GHOST_HTTP3_SOAK_HARSH=1` is set; enabling it widens the per-seed timeout.

## What remains for multi-host / GitHub Actions

- Cross-host UDP impairment via the real network (not loopback) would catch
  reception-path behaviors the loopback simulator cannot (OS receive-buffer
  pressure, ICMP source quench, etc.). The proxy already supports
  `--listen-host` / `--target-host`; what is missing is the test driver that
  runs the client on one host and the server on another.
- A "multi-impairment at once" deterministic profile that survives without a
  handshake stall likely needs a request-padding profile or a patched
  example with a longer idle timeout; the harsh reproducer above is the
  placeholder until then.
- For GitHub Actions: gate `test-chaos.sh` (it is already wired into
  `build-with-rust-dmg.sh`); make `GHOST_HTTP3_SOAK=1` opt-in per matrix
  because the seed-progression adds non-trivial wall-clock.
- A long-horizon multi-hour soak run from CI on a quiet dedicated runner
  would further tighten the leak-detection evidence on the proxy.

Artifacts are written to `macOS/GhostHTTP3/.build/artifacts/`:

- `GhostHTTP3.framework`: arm64 dynamic framework. Its executable has install
  name `@rpath/GhostHTTP3.framework/Versions/A/GhostHTTP3`.

There is no x86 slice, static release library, or XCFramework. The build asks
Cargo for a `cdylib` only and links the GhostHTTP3 wrapper into that same dylib.
System dependencies such as libc++ and libiconv are recorded by the dylib and
do not require separate bundled copies.

## Upstream

The build pins quiche 0.29.3 to commit
`55886df3be579579207104c8e645825b6347a209`. The upstream header is copied into
the generated framework so C, Objective-C, C++, and Swift targets can use the
full HTTP/3 API.

quiche intentionally excludes `Cargo.lock` from its repository. This wrapper
checks in the resolved `quiche-0.29.3.Cargo.lock` used by the build and passes
Cargo's `--locked` flag, so transitive Rust dependencies cannot drift.

See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for licensing.
See [RESEARCH.md](RESEARCH.md) for the Google QUICHE, Mozilla Neqo, and
Cloudflare quiche selection rationale.
