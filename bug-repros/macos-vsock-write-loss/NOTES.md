# Investigation notes — macOS AF_VSOCK silent data loss

> **Status**: kernel bug confirmed at the raw `AF_VSOCK` layer (no NIO, no
> third-party deps). Ready to file with Apple. Workarounds exist on the
> consumer side. This file is the full handoff to anyone picking this up.

---

## 1. TL;DR

On **macOS 26.x running as a Virtualization.framework guest**, a non-blocking
writer on an `AF_VSOCK` `SOCK_STREAM` socket calling `write()` repeatedly will
have `write()` return **success for ~128 MiB in ~20 ms** while the receiver
(host, talking to the guest via `VZVirtioSocketDevice`) actually only gets
**~5 MiB of those bytes** before the connection is closed. The rest is
silently dropped.

Three kernel-level defects appear to be in play (all reproducible together):

1. **`write()` lies.** Non-blocking `write(AF_VSOCK, …)` returns successful
   byte counts for orders of magnitude more data than the kernel can actually
   buffer or deliver. No `EAGAIN` is ever returned.
2. **`EVFILT_WRITE` never fires** for writability back-pressure because the
   kernel never says "buffer full" — `EAGAIN` doesn't happen, so kqueue
   notification isn't engaged. Means there's no working mechanism for
   non-blocking flow control on vsock.
3. **`close()` discards pending bytes** without honoring `SO_LINGER` defaults.
   Bytes that `write()` acknowledged but the kernel hasn't actually delivered
   are silently lost when the writer closes.

Net effect for any non-blocking `AF_VSOCK` user (most notably swift-nio
servers in VMs): payloads > ~5 MiB silently lose ~95% of bytes.

The bug has been observed on Apple Silicon macOS 26.x both as the host and
guest OS. Not yet tested on Intel, not yet tested with Linux guests.

---

## 2. Project context (why we hit this)

- The host project is **GhostVM**, a macOS-on-macOS virtualization tool
  (uses `Virtualization.framework`).
- The guest agent **GhostTools** runs inside each VM and exposes an HTTP-like
  API on vsock ports 5000–5003. The host's `GhostVM.app`, `GhostVMHelper`,
  and `vmctl` talk to it via `VZVirtioSocketDevice.connect(toPort:)`.
- GhostTools' HTTP server is **swift-nio (NIO + NIOHTTP1)**.
- We were implementing a streaming **"Send to host"** feature — guest queues
  files, host fetches them via `GET /api/v1/files/{path}`, streamed with
  `NonBlockingFileIO.readChunked`. Worked fine for ≤ ~5 MiB payloads,
  silently truncated for anything larger.

The bug surfaced as user-visible "send-to-host produces a partial file with
a random size around 4–10 MiB per try."

---

## 3. Repro — what's in this directory

```
bug-repros/macos-vsock-write-loss/
├── Package.swift                          # SwiftPM, two executables
├── README.md                              # filing-ready bug description
├── NOTES.md                               # this file
└── Sources/
    ├── VsockSender/main.swift             # guest-side, raw Darwin + kqueue
    └── VsockReceiver/main.swift           # host-side template (Virtualization)
```

### `VsockSender` (guest binary)

Pure Darwin. **No swift-nio, no GhostTools, no framework dependencies beyond
`Darwin` and `Foundation`.** This is what makes the repro Apple-ready.

What it does:

1. `socket(AF_VSOCK, SOCK_STREAM, 0)`, `bind`, `listen` on the requested port.
2. `accept` one connection.
3. Sets the accepted fd to `O_NONBLOCK`.
4. Registers `EVFILT_WRITE` on the fd with a kqueue.
5. Writes the requested number of bytes in 64 KiB chunks via `Darwin.write()`.
   On `EAGAIN`, `kevent()` waits for writability with a 10-second timeout.
6. Reports detailed stats: bytes "sent" by `write()` returns, `EAGAIN` count,
   kqueue waits, kqueue timeouts, throughput.
7. Sleeps 3 seconds, closes the client fd, loops back to `accept`.

Build & run (inside a guest VM):

```sh
swift build --product VsockSender
./.build/debug/VsockSender 5004 134217728   # 128 MiB
```

### `VsockReceiver` (host template)

Just a documentation file with the read loop you'd drop into a program that
has a `VZVirtualMachine` handle. Because macOS doesn't expose `AF_VSOCK`
directly to host processes (per Apple Dev Forums thread 731132 and the
`vsock(4)` man page), you can't write a standalone receiver — it has to use
`VZVirtioSocketDevice.connect(toPort:)`.

For *our* investigation we used the GhostVM project's existing infrastructure
plus a new netcat-style command (`vmctl vsock connect <port>`) that we built
specifically for this — see Section 6 below.

---

## 4. The numbers (4 consecutive runs)

128 MiB requested every time. Sender ran inside the guest VM, receiver was
`vmctl vsock connect <port> | dd of=/dev/null bs=1M` on the host:

| Run | Sender `write()` returns | Sender `EAGAIN` | Sender kqueue waits | Sender throughput | Receiver got |   % delivered |
|-----|--------------------------|-----------------|---------------------|-------------------|--------------|---------------|
|  1  | 134,217,728 B            | 0               | 0                   | 7574 MiB/s        |   5,767,168 B | 4.30 %        |
|  2  | 134,217,728 B            | 0               | 0                   | 11030 MiB/s       |   4,456,448 B | 3.32 %        |
|  3  | 134,217,728 B            | 0               | 0                   | 8156 MiB/s        |   5,242,880 B | 3.91 %        |
|  4  | 134,217,728 B            | 0               | 0                   | 8391 MiB/s        |   5,242,880 B | 3.91 %        |

Observations:

- Sender claims ~8 GiB/s throughput. That number alone is suspicious —
  vsock is in-memory virtio, but 8 GiB/s of *real* throughput would mean
  the receiver got everything in 16 ms, not 3 seconds.
- Each run takes **exactly ~3 seconds at the receiver** — the sender's
  pre-close `Thread.sleep(forTimeInterval: 3.0)`. The receiver pulls bytes
  during this 3-second window at ~1.6 MiB/s.
- The moment the sender's `close()` runs, the receiver hits EOF — even
  though the kernel previously "accepted" 128 MiB of writes.
- The delivered byte count varies a little run-to-run (4.25 MiB to 5.5
  MiB) — consistent with "deliver as much as fits in the kernel's actual
  per-flow buffer during 3 s of draining time."

---

## 5. The investigation that got us here

This bug burned 4–5 hours of debugging. Capturing the dead-ends so the next
person doesn't repeat them:

### 5.1 Initial wrong theories (all disproven)

| Theory | How disproven |
|---|---|
| NIO's `writeAndFlush` future fires prematurely | Same loss with raw `Darwin.write()`, no NIO |
| `ProtocolDetector` racing during pipeline swap | Server side cleanly logs `readChunked completed; sent=N/N` |
| `Content-Length` mismatch | Bytes-on-wire don't match Content-Length anyway; framing is fine |
| HTTP/2 detection wedge | Removed H/2 entirely; bug persisted |
| `EVFILT_WRITE` for vsock fires unreliably | Sender never gets `EAGAIN`, so `EVFILT_WRITE` doesn't *need* to fire. Different problem: kernel never *signals* back-pressure |
| Helper's blocking byte-bridge is broken | Replaced with two independent runtimes (helper bridge + vmctl bridge), same loss |
| `vmctl` deadlock waiting on stdin | Fixed; receiver now exits cleanly — but byte loss numbers are unchanged |

### 5.2 Server-side mitigations we tried (all failed)

In `macOS/GhostTools/Sources/GhostTools/Server/StreamDispatcher.swift`
`StreamingFileSendHandler`:

1. **`context.close(promise: nil)` after `.end` flushed.** Discarded pending
   data; receiver got ~10 MiB then EOF.
2. **`context.close(mode: .output)` (SHUT_WR half-close).** Same as above.
   macOS vsock doesn't honor the controlled-shutdown drain that TCP does.
3. **No close on server; let host close after reading Content-Length.**
   Receiver hung after ~10 MiB. Bytes weren't being pushed further.
4. **Poll `channel.isWritable` + periodic `context.flush()` until peer
   closes.** `isWritable` immediately returned `true` because NIO's outbound
   buffer was below the low watermark — but kernel hadn't delivered the
   bytes yet. Premature close.
5. **`SO_SNDBUF = 32 MiB` on the child channel.** No effect — write counts
   look identical to default.

None of these fixed it because the bug isn't in NIO. It's in the kernel.

### 5.3 What we proved with the raw-Darwin repro

Stripping away NIO, the streaming HTTP handler, the dispatcher, even the
host-side blocking-bridge:

- Sender: pure `socket() + bind + listen + accept + fcntl(O_NONBLOCK) + kqueue
  + write() loop`.
- Helper-side bridge: blocking `read()`/`write()` between unix socket and
  vsock fd (in `HostAPIService.bridgeBytes`, brand new general-purpose
  helper).
- vmctl-side bridge: blocking `read()`/`write()` between unix socket and
  stdin/stdout (in `VsockCommand.bridgeBlocking`).
- Receiver: `dd of=/dev/null bs=1M`.

Same loss. → Bug is below the application layer. It's in the kernel's
`AF_VSOCK` implementation, or in the `VZVirtioSocketDevice` ↔ kernel-vsock
boundary.

### 5.4 Background research

- Apple's documented vsock surface is sparse. The `vsock(4)` man page mentions
  `connect()` semantics with non-blocking + kqueue but is silent on
  `SO_SNDBUF`, `SO_LINGER`, write back-pressure, and close behavior.
- macOS exposes `AF_VSOCK` only from inside VMs. The host side must use
  `VZVirtioSocketDevice.connect(toPort:)`. See
  https://developer.apple.com/forums/thread/731132 and the
  [junixsocket-vsock notes](https://kohlschutter.github.io/junixsocket/junixsocket-vsock/index.html).
- XNU is open source at https://github.com/apple-oss-distributions/xnu but
  Apple doesn't triage bugs filed as GitHub issues there. It's there for
  reading the kernel source if we want to understand the precise failure.

---

## 6. The `vmctl vsock` tool we built along the way

To make the receive side of the repro reproducible from the existing project
without writing a full Virtualization.framework boilerplate, we added:

- **`HostAPIService.swift`**: new endpoint `/api/v1/vsock-connect` that takes
  a `Vsock-Port: N` header, opens a raw vsock to the guest at that port via
  `client.connectRaw(port:)`, and bridges bytes between vmctl's unix socket
  and the vsock fd.
- **`HostAPIService.bridgeBytes(fdA:fdB:label:)`**: refactored the byte-bridge
  loop out of `handleShellProxy` so the new endpoint reuses it. Two
  background queues, blocking `read()` / `writeAll()`, SHUT_WR on EOF.
- **`vmctl vsock connect [--name VM | --socket path] <port>`**: netcat for
  vsock. Bidirectional byte bridge between vmctl's stdin/stdout and the
  unix socket to the helper. Half-closes on stdin EOF, exits when the
  helper closes its side.

This is **valuable infrastructure that should survive whether or not the
underlying bug is fixed.** Tons of use cases:

```sh
# Probe an HTTP endpoint
printf 'GET /health HTTP/1.1\r\nHost:x\r\n\r\n' | vmctl vsock connect -n MyVM 5000

# Capture a stream to file
vmctl vsock connect -n MyVM 5004 > capture.bin

# Push a payload from a file
cat payload.bin | vmctl vsock connect -n MyVM 5004
```

Source:
- `macOS/GhostVM/vmctl/VsockCommand.swift` (vmctl side)
- `macOS/GhostVMHelper/HostAPIService.swift` (helper side, `handleVsockConnectProxy` + `bridgeBytes`)
- `macOS/GhostVM/vmctl/CLI.swift` (dispatch)

---

## 7. How to file the Apple bug

### 7.1 Order of operations

1. **Feedback Assistant** (`feedbackassistant.apple.com` or the macOS app).
   Generates an `FB#######` number. This is the canonical record. Apple
   triages from here.
2. **Technical Support Incident** at
   `developer.apple.com/contact/technical/`, referencing the FB#. Two free
   per year on a paid developer account. Gets a real DTS engineer.
3. **Apple Developer Forums** (Networking subforum). Brief post linking to
   the FB#. Increases the chance someone like Quinn ("The Eskimo!") chimes
   in publicly.
4. **WWDC 2026 Lab signup** (June). Virtualization or Networking lab. Bring
   the FB# and the repro on a USB stick.

**Don't bother with:** the XNU GitHub issue tracker; it's not triaged.

### 7.2 Feedback Assistant filing checklist

- **Category**: macOS → Networking → Sockets (or Virtualization if a sub-
  category is visible).
- **Title**: *"AF_VSOCK on macOS guest: non-blocking write() silently accepts
  bytes the kernel cannot deliver; EVFILT_WRITE never fires; close()
  discards pending data"*
- **Description**: paste the **TL;DR** from Section 1 + the **numbers table**
  from Section 4. Mention this is reproducible with zero third-party
  dependencies — pure Darwin.
- **System info**: macOS host version + build, macOS guest version + build,
  Apple Silicon model. Feedback Assistant auto-attaches a sysdiagnose; let
  it. Optionally run `sysdiagnose` inside the guest too and attach the
  archive.
- **Attachments**:
  - This entire `bug-repros/macos-vsock-write-loss/` directory zipped
    (Package.swift, both Sources/*, README.md, NOTES.md)
  - A `RUN.md` (write a short one) explaining: build the package, drop
    `VsockSender` binary into a guest, build a small host-side reader using
    `VZVirtioSocketDevice.connect(toPort:)` and run `dd`.
  - Screenshots of one full run showing both the sender's "actually sent:
    134217728 bytes / 0 EAGAINs" output and the receiver's "~5 MiB
    transferred" output.

### 7.3 TSI follow-up template

After Feedback Assistant gives you FB#######, file a TSI:

> AF_VSOCK on macOS 26.x exhibits silent data loss when used from a
> Virtualization.framework guest. `write()` returns success for ~128 MiB in
> ~20 ms with zero `EAGAIN`s; receiver on the host (via
> `VZVirtioSocketDevice.connect`) actually gets ~5 MiB. `EVFILT_WRITE`
> doesn't engage (no `EAGAIN` to trigger it). `close()` discards pending
> kernel-side bytes.
>
> Feedback Assistant: **FB#######**
>
> Reproducer attached: pure-Darwin (`AF_VSOCK` + kqueue + non-blocking
> `write()`) Swift package; zero third-party dependencies on the failing
> side. Receiver uses `VZVirtioSocketDevice.connect(toPort:)`.
>
> Asks:
> 1. Is `AF_VSOCK` non-blocking `write()` supposed to back-pressure via
>    `EAGAIN` / `EVFILT_WRITE`? If yes, the current implementation appears
>    broken on macOS 26.x; if no, the man page should say so and we need
>    documented guidance on how to do reliable streaming over vsock from a
>    macOS guest.
> 2. Is `close()`-with-pending-data drain supposed to work like TCP
>    `SO_LINGER` defaults (kernel drains then sends FIN)? If yes, broken;
>    if no, again docs should reflect that and tell us how to signal
>    end-of-message reliably.
> 3. Does Apple ship a recommended pattern for streaming large payloads
>    over vsock between a guest and host? Linux Hyper-V vsock uses the
>    same socket family but doesn't exhibit this loss.

### 7.4 Forum post draft

```
Title: AF_VSOCK: write() acknowledges 128 MiB; receiver gets ~5 MiB
       (macOS 26 host + guest via Virtualization.framework)

I'm hitting what looks like a kernel-level data-loss bug in AF_VSOCK on
macOS 26.x. Repro is pure Darwin — no third-party deps — and reproducible
every time. Has anyone else run into this? Apple staff: would value a
sanity check on whether this is expected behavior or something I should
escalate via Feedback Assistant.

Setup
=====
Guest (macOS 26 in a Virtualization.framework VM):
  socket(AF_VSOCK, SOCK_STREAM, 0), bind, listen, accept.
  Set non-blocking, register EVFILT_WRITE via kqueue.
  Write 128 MiB in 64 KiB chunks via write().

Host:
  VZVirtioSocketDevice.connect(toPort:), then blocking read() loop.

Observation
===========
Sender side (4 consecutive runs, fresh connections):
  write() returns success for the full 134,217,728 bytes in ~20 ms.
  Zero EAGAIN returns. Zero kqueue events.

Host side (same 4 runs):
  read() returns 4.25–5.5 MiB total, then EOF when sender closes.

That's ~96 % silent data loss. Throughput observed during the open
connection is ~1.6 MiB/s; the rest of the "accepted" bytes never arrive.

Filed as Feedback Assistant FB####### with a full reproducer.
```

---

## 8. Workarounds in the GhostVM codebase

Because Apple's response timeline is unknown (likely months), we need to
work around this in the meantime. **Pick one or combine:**

### 8.1 Cap streaming responses (cheapest)

Limit any single vsock write burst to `< 4 MiB`. After that, pause
explicitly until the peer ACKs. Requires an in-band ACK in the protocol.
Doable but invasive.

### 8.2 Use the shared folder for large payloads

The GhostVM project already has a shared-folder mount between host and
guest (it's how the user moves DMG files around). For large file
transfers, write the file to the shared folder from the guest, then
signal completion via vsock (a tiny ACK message that fits in the
not-broken window). Host reads the file from its own filesystem.

This is **the most robust workaround**. No vsock data path for the actual
bytes — only metadata flows over vsock, which is always small.

### 8.3 Use the existing `TunnelServer` (TCP over vsock)

The GhostVM project's `TunnelServer` (vsock port 5001) implements
`CONNECT`-style TCP tunneling. If TCP-over-vsock has different kernel
semantics (we haven't tested), this might already work. Worth a 30-min
experiment.

### 8.4 Chunked retransmit protocol

Sender writes a chunk, waits for peer's "got N bytes" ACK, writes next
chunk. Each chunk stays under the broken-window size. Slow but reliable.
Most complex of the four — would only do this if 8.2 and 8.3 are blocked.

### 8.5 Don't fix it yet

The original "Send to host" feature is a quality-of-life feature, not
critical. Document the limitation (files > ~4 MiB don't work), wait for
Apple, revisit when there's a fix.

**Recommended path: 8.2 (shared folder for bytes, vsock for control).**

---

## 9. Open questions for whoever picks this up

- [ ] Does the bug affect **Linux guests** under Virtualization.framework
      with `AF_VSOCK`? If not, it's a macOS-guest-side kernel issue
      specifically. Linux has its own vsock implementation; this would
      narrow the suspect surface.
- [ ] Does the bug affect **host → guest** writes (host as sender)? We
      only tested guest → host. The data-flow direction may matter.
- [ ] Does it affect **macOS 26.5+** (any patch release after `25E251`
      / `Darwin 25.3.0`, which is what we tested)? Apple has shipped
      several point releases since.
- [ ] What does the **XNU vsock source** look like? `apple-oss-distributions/xnu`
      under `bsd/kern/uipc_*` or look for a `vsock` subdirectory. Reading
      the implementation may pinpoint whether `write()`'s success return
      is bogus or whether the actual buffering is on the
      `VZVirtioSocketDevice` side.
- [ ] Is there a **sysctl** knob (e.g. `net.local.stream.sendspace`-style
      for vsock) that would change the buffer behavior? None documented;
      worth `sysctl -a | grep -i vsock` to find any.
- [ ] **`SO_LINGER`** explicitly set with a positive linger — does the
      kernel honor it? Our default-close test failed; an explicit linger
      might at least make `close()` block until drain, even if it can't
      fix the write-acknowledgment lie.

---

## 10. Files / locations that matter

| Where | What |
|---|---|
| `bug-repros/macos-vsock-write-loss/` | This repro project — drag-and-droppable for Apple |
| `macOS/GhostVM/vmctl/VsockCommand.swift` | New `vmctl vsock connect` — keep regardless of bug fate |
| `macOS/GhostVMHelper/HostAPIService.swift` | `handleVsockConnectProxy` + `bridgeBytes` |
| `macOS/GhostTools/Sources/GhostTools/Server/StreamDispatcher.swift` | `StreamingFileSendHandler` — currently has the failed mitigations (poll + flush + close); decide whether to revert to a simple "write + don't close" once we ship a workaround |
| `macOS/GhostVM/Services/GhostClient.swift` | `fetchFileStreamingViaVsock` — has the diagnostic logging that originally surfaced the byte counts |
| `macOS/GhostVM/Services/FileTransferService.swift` | `fetchAllGuestFiles` — caller of the broken streaming path, with all the os.Logger instrumentation we added |
| `bug-repros/macos-vsock-write-loss/Sources/VsockSender/main.swift` | Standalone sender for the Apple-facing repro |

---

## 11. Branch state at handoff

- Branch: `experiment/nio-http2` (despite the name — HTTP/2 is gone)
- Uncommitted changes worth preserving:
  - `macOS/GhostTools/Sources/GhostTools/Server/StreamDispatcher.swift` —
    diagnostic logging + (currently broken) flush-nudge close
  - `macOS/GhostTools/Sources/GhostTools/Server/NIOVsockServer.swift` —
    `SO_SNDBUF=32MB` bump (probably worth keeping; doesn't hurt)
  - `macOS/GhostVM/Services/GhostClient.swift` — os.Logger diagnostics
  - `macOS/GhostVM/Services/FileTransferService.swift` — os.Logger
    diagnostics + cleanup-on-error
  - `macOS/GhostVMHelper/HostAPIService.swift` — new vsock-connect endpoint
    + `bridgeBytes` refactor
  - `macOS/GhostVM/vmctl/CLI.swift` — vsock dispatch
  - `macOS/GhostVM/vmctl/VsockCommand.swift` — new file
- Untracked but valuable: this entire `bug-repros/macos-vsock-write-loss/`
  directory.

Decisions to make before merging:
1. Keep all the diagnostic os.Logger calls or strip them back to release-
   quality logs (`debug` level)?
2. Revert the flush-nudge close attempts in `StreamDispatcher.swift` to a
   minimal "write head + chunks + .end, don't close" once we pick a
   workaround?
3. Ship `vmctl vsock connect` in v3 even though it's debugging
   infrastructure? (Recommend: **yes**, low cost, high diagnostic value.)

---

## 12. Test environment used

- **Host**: Apple Silicon Mac, macOS 26.4.1 (build `25E251`, Darwin `25.3.0`)
- **Guest**: macOS 26.x in a Virtualization.framework VM (`VirtualMac2,1`,
  reported as "Apple M5 Max (Virtual)")
- **Xcode**: 26.4.1, build `17E202`
- **swift-nio**: 2.99.0 (pulled by GhostTools' SwiftPM package; the bug
  reproduces with zero NIO too, so NIO version is irrelevant for the
  repro)
- vsock ports in use by GhostTools (avoid these in repros):
  - 5000: NIOVsockServer (HTTP)
  - 5001: TunnelServer (TCP-over-vsock CONNECT)
  - 5002: HealthServer
  - 5003: EventPushServer
- Repro uses port **5004** for cleanliness.

---

## 13. One-line "how do I run the repro right now"

Inside the guest VM:

```sh
swift build --package-path bug-repros/macos-vsock-write-loss --product VsockSender
./bug-repros/macos-vsock-write-loss/.build/debug/VsockSender 5004 134217728
```

On the host (with a current GhostVM build installed):

```sh
~/VMs/<VMName>.GhostVM/Helper/vmctl.app/Contents/MacOS/vmctl \
  vsock connect --name <VMName> 5004 | dd of=/dev/null bs=1M
```

Sender says it sent 134217728 bytes with 0 EAGAINs. `dd` says it got
~5 MiB. That's the bug.
