# macOS AF_VSOCK write loss with non-blocking I/O

## Summary

Under sustained non-blocking writes to an `AF_VSOCK` socket from a macOS guest
to its macOS host (via Virtualization.framework), bytes are silently dropped
once the response exceeds roughly the kernel send buffer size. `write()` returns
success for all bytes written, but the host's `read()` loop blocks after
receiving only a fraction of the data (consistently ~10 MiB regardless of how
much was written), as if the kernel quietly stopped delivering bytes. With the
sender side closing the socket after writing, the host sees `EOF` early at the
same ~10 MiB mark; without closing, the host's `read()` blocks indefinitely.

## Environment

- macOS host: 26.x on Apple Silicon
- macOS guest: 26.x in a Virtualization.framework VM
- vsock between host and guest via `VZVirtioSocketDevice`
- Sender (guest) uses non-blocking `write()` + `kqueue` `EVFILT_WRITE` for back-pressure
- Receiver (host) uses blocking `Darwin.read()` on the fd returned by
  `VZVirtioSocketDevice.connect(toPort:)`

## Hypothesis

`EVFILT_WRITE` on `AF_VSOCK` doesn't fire reliably once the kernel send buffer
is full and starts draining. A non-blocking writer that depends on
`EVFILT_WRITE` (as `swift-nio` does) parks waiting for an event that never
comes, and the bytes still sitting in user-space pending-write buffers (or
maybe the kernel itself — unclear without instrumentation) never make it to
the peer.

The number ~10 MiB is consistent across runs and roughly matches the apparent
`SO_SNDBUF` default for vsock on this system.

## Reproducer

This package contains two executables:

- **`VsockSender`** — runs *inside* the macOS guest VM. Listens on an
  `AF_VSOCK` port and writes a fixed number of bytes to the first connection,
  using non-blocking I/O + `kqueue`/`EVFILT_WRITE`. Reports stats at the end.
- **`VsockReceiver`** — *template* for the host side. Because macOS doesn't
  expose `AF_VSOCK` directly to host processes, the receiver must hold a
  `VZVirtualMachine` reference and use `VZVirtioSocketDevice.connect(toPort:)`
  to get an fd. The receiver source contains the read loop you can drop into
  any program that already has a `VZVirtualMachine` handle (e.g. a
  `vmctl`-style helper or the host app itself).

### Build

```sh
swift build -c release
```

### Run — guest side (inside the VM)

```sh
# Write 128 MiB to whoever connects to vsock port 5000
./.build/release/VsockSender 5000 134217728
```

### Run — host side

Inside any host program that has a running `VZVirtualMachine`, do:

```swift
let socketDevice = vm.socketDevices.first as! VZVirtioSocketDevice
let connection = try await withCheckedThrowingContinuation { c in
    socketDevice.connect(toPort: 5000) { result in c.resume(with: result) }
}
let fd = connection.fileDescriptor

// Make fd blocking so reads don't busy-loop:
let flags = fcntl(fd, F_GETFL, 0)
fcntl(fd, F_SETFL, flags & ~O_NONBLOCK)

var buf = [UInt8](repeating: 0, count: 65536)
var total = 0
let expected = 134217728
while total < expected {
    let n = Darwin.read(fd, &buf, buf.count)
    if n > 0 { total += n }
    else if n == 0 { print("EOF after \(total)/\(expected)"); break }
    else if errno == EINTR { continue }
    else { print("read errno=\(errno) after \(total)/\(expected)"); break }
}
print("FINAL: read=\(total)/\(expected), missing=\(expected - total)")
```

## Expected vs actual

Four consecutive runs, 128 MiB requested each time:

| Run | Sender (`write()` returns) | EAGAINs | kqueue waits | Receiver got | % delivered |
|-----|---------------------------|---------|--------------|--------------|-------------|
| 1   | 134,217,728 bytes         | 0       | 0            | 5,767,168 B  | 4.30 %      |
| 2   | 134,217,728 bytes         | 0       | 0            | 4,456,448 B  | 3.32 %      |
| 3   | 134,217,728 bytes         | 0       | 0            | 5,242,880 B  | 3.91 %      |
| 4   | 134,217,728 bytes         | 0       | 0            | 5,242,880 B  | 3.91 %      |

Every run reproduces the bug. Three things stand out:

1. **`write()` lies.** The sender's non-blocking `write()` returns successful
   byte counts for the entire 128 MiB in ~20 ms — but the kernel never
   actually has anywhere near that much queued. Throughput observed at the
   receiver during the open connection is ~1.6 MiB/s.
2. **`EVFILT_WRITE` is never invoked** because the kernel never returns
   `EAGAIN`, even though it clearly can't deliver bytes that fast.
3. **`close()` discards pending bytes.** Each run takes ~3 seconds — exactly
   the sender's pre-close `Thread.sleep(3.0)`. During those 3 seconds the
   receiver pulls whatever the kernel can actually push (~5 MiB on this
   hardware). The moment `close()` runs, the rest is gone.

## Why this matters

Anything that uses non-blocking vsock I/O from a Virtualization.framework guest
— in particular `swift-nio` based servers — is currently capped at ~10 MiB per
response. This breaks file transfer, large HTTP responses, streamed media, and
anything else that pushes bigger payloads through vsock.

A blocking-I/O server doesn't hit this because blocking `write()` parks the
thread in the kernel until bytes are accepted, sidestepping the need for
`EVFILT_WRITE`.

## What we'd like to know

1. Is `EVFILT_WRITE` on `AF_VSOCK` supposed to behave like it does on TCP
   sockets (fire whenever the buffer drains below the low watermark)?
2. If yes — is the failure to fire a known issue / regression?
3. If no — what's the recommended way to do non-blocking vsock writes that
   handles back-pressure correctly?
4. Are there ways to instrument the vsock kernel side to confirm whether bytes
   are queued vs delivered?
