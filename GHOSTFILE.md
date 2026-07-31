# GhostFile

GhostFile is a standalone macOS demo for sharing and mounting folders over a
local network with FSKit.

One `GhostFile.app` instance shares a selected folder through a versioned,
read-only HTTP/3 filesystem API and advertises it with Bonjour. Another instance
discovers that share (or accepts its URL manually) and mounts it through the
embedded `GhostFileFS.appex` extension.

```text
GhostFile.app (Share)                 GhostFile.app (Mount)
        |                                      |
        +-- _ghostfile._udp via mDNS ----------+
        |                                      |
        +-- GhostFile v1 over HTTP/3 ---------->+-- GhostFileFS.appex
                                                        |
                                                        +-- native mount
```

## Build and run

The extension uses the restricted `com.apple.developer.fskit.fsmodule`
entitlement. Select an Apple Developer team that has this capability before
running the signed app.

```bash
make ghostfile DEVELOPMENT_TEAM=YOUR_TEAM_ID
make run-ghostfile DEVELOPMENT_TEAM=YOUR_TEAM_ID
```

Use `open -n build/xcode/Build/Products/Debug/GhostFile.app` to launch a second
instance. Enable **GhostFileFS** under **System Settings > General > Login Items
& Extensions > File System Extensions** before mounting.

The mounted volume appears under `~/GhostFile Mounts` and can be revealed in
Finder from the app.

## Protocol

Version 1 exposes bounded, WebDAV-like operations for each share:

- `capabilities`
- `metadata(path)`
- `directory(path)`
- `content(path, offset, length)`
- `readlink(path)`

The wire protocol uses normal HTTP semantics: `GET` requests, HTTPS pseudo
headers, bearer authorization, status codes, content lengths, and byte ranges.
Each request uses an independent bidirectional HTTP/3 stream on one persistent
QUIC connection. Directory responses contain a stable verifier for FSKit
pagination, and file reads are limited to 1 MiB per request. Paths are relative
to the selected share and both lexical traversal and symlink escapes are
rejected.

GhostHTTP3 embeds Cloudflare's quiche library in a dynamically linked arm64
framework. Network.framework carries its UDP datagrams, while quiche implements
the QUIC transport, TLS 1.3 handshake, QPACK, HTTP/3 request/response framing,
flow control, and multiplexing. Integration tests cover 32 concurrent 64 KiB
range reads and verify that a two-second paused request doesn't delay an
independent request on the same connection.

The service is advertised as `_ghostfile._udp` with `transport=http3` and
`alpn=h3` TXT values. Peers negotiate the standard `h3` ALPN over TLS 1.3 and
QUIC. The server uses an ephemeral certificate whose DER SHA-256 pin is carried
in the share URL, so the self-signed local connection is still authenticated.

## Current scope

- Read-only shares and mounts.
- Local-network discovery with Bonjour/mDNS.
- Manual URL mounting for environments where multicast discovery is
  unavailable, including VM-to-host networking.
- Access keys and the server public-key pin are passed to the extension in the
  FSKit resource URL for this demo. A production version should move credentials
  into a shared Keychain access group and persist/pair TLS identities.
- New directory entries and metadata are fetched from the server. macOS may
  retain already-read file pages in its unified buffer cache; remount a share to
  guarantee a fresh snapshot after an existing source file is overwritten.

## Verification

```bash
make test-ghostfile DEVELOPMENT_TEAM=YOUR_TEAM_ID
scripts/stress-ghostfile.sh /path/to/mount /path/to/shared/folder
python3 scripts/benchmark-ghostfile.py \
  /path/to/shared/folder/large-file /path/to/mount/large-file
```

The stress script checks parallel reads, checksums, directory enumeration,
spaces and UTF-8 names, symlinks, and enforcement of the read-only mount.
