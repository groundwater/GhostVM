# GhostFile benchmarks

## 2026-08-02: installed writable FSKit prototype

The earlier read-only benchmark established read performance only; it was not
evidence that filesystem mutations worked. This pass used the signed
`/Applications/GhostFile.app` extension and a real FSKit mount backed by the
workspace share. Every mounted mutation was checked against the source path.

Functional results:

- one 3 MiB `write(2)` path split into concurrent FSKit callbacks: passed;
- three simultaneous 1 MiB writes at disjoint offsets in one file: passed;
- create, mkdir, chmod, same- and cross-directory rename, truncate, symlink,
  unlink, and rmdir: passed;
- live read-only enable rejected create and chmod with `EROFS`; disabling it
  restored writes on the existing mount;
- writable stress: 25 checks, including 200 parallel operation batches, with
  zero failures;
- XCTest: 48 tests, one intentional skip, zero failures.

Mounted-versus-native results use the existing 75.5 MiB and 8,192-file
fixtures. Values are medians of three samples.

| Test | Previous FSKit | Current FSKit | Change |
| --- | ---: | ---: | ---: |
| Random 4 KiB read (`F_NOCACHE`) | 1,302.8 us/op | 1,216.7 us/op | 6.6% lower latency |
| Sequential read (`F_NOCACHE`) | 12.7 MiB/s | 123.4 MiB/s | 9.7x |
| Warm sequential read | 17,215.5 MiB/s | 18,058.5 MiB/s | 1.05x |
| Recursive enumeration | 26,284 entries/s | 173,472 entries/s | 6.6x |
| Small-file open + read | 2,318.8 IOPS | 1,110.9 IOPS | 0.48x |
| Directory listing | 513.3 IOPS | 3,933.0 IOPS | 7.7x |

Sequential mounted writes of a 64 MiB file measured 135.3, 136.0, and
135.2 MiB/s (about 135.3 MiB/s median). There is no valid previous write
number because the old mounted path was read-only. Hard links remain explicitly
unsupported (`ENOTSUP`) rather than being reported as functional.

## 2026-07-31: receive-side QUIC datagram batching

The remaining throughput ceiling was a serialized per-datagram feedback loop,
not file I/O or HTTP/3 stream head-of-line blocking. Although each
`NWConnection` registered 64 concurrent `receiveMessage` calls, every callback
created an actor task that independently performed QUIC receive, HTTP/3 event
polling, and an awaited outgoing flush. That made ACK/control processing and
response progress pay the Swift task, actor, quiche, and Network.framework
costs once per UDP packet.

The client and server now re-arm the receive immediately, queue completed UDP
datagrams on their connection actor, and drain up to 64 datagrams before one
HTTP/3 event poll and outgoing flush.

### Direct HTTP/3 result

The same 75.5 MiB fixture and 1,350-byte QUIC payload were used before and
after. The after values are medians of three runs without diagnostic logging.

| Test | Before batching | After batching | Improvement |
| --- | ---: | ---: | ---: |
| Sequential 1 MiB ranges | 16.8 MiB/s | 167.7 MiB/s | 10.0x |
| 16 concurrent streams | 27.4 MiB/s | 192.8 MiB/s | 7.0x |

After samples:

- Sequential: 148.6, 168.4, 167.7 MiB/s
- 16-stream: 192.8, 189.5, 193.8 MiB/s

### Diagnostic evidence

Opt-in `GHOSTFILE_HTTP3_DIAGNOSTICS=1` sampling showed the pre-fix client
spending about 490 ms of each 500 ms interval waiting on single-packet UDP
sends, while the server's loopback QUIC RTT inflated to roughly 28 ms. The
server emitted only about 7,250 packets per half-second. After receive-side
batching, RTT fell to roughly 1.2 ms and the server emitted about 57,000 packets
in a half-second with only five packets reported lost across the transfer.

As a separate isolation test, increasing only the loopback QUIC payload from
1,350 to 8,000 bytes raised the pre-fix result to 83.3 MiB/s sequential and
93.1 MiB/s with 16 streams. That confirmed the ceiling scaled with UDP packet
count. Jumbo payloads are not the production fix because real network paths
must retain a conservative MTU; receive-side batching removes the per-packet
serialization while keeping the 1,350-byte payload.

## 2026-07-31: synchronous body producer to DispatchIO

These measurements use the same 75.5 MiB fixture on one Apple Silicon Mac.
Direct HTTP/3 runs use one persistent loopback QUIC connection. Mounted runs
compare the source file with the FSKit mount and use `F_NOCACHE` where noted.
Values are medians; the raw direct HTTP/3 samples are included because the
16-stream result has occasional low outliers.

### Direct HTTP/3

| Test | Before | After |
| --- | ---: | ---: |
| Sequential 1 MiB ranges | 16.8 MiB/s | 16.8 MiB/s |
| 16 concurrent streams | 27.8 MiB/s | 27.4 MiB/s |

Before samples:

- Sequential: 16.7, 16.8, 16.9 MiB/s
- 16-stream: 28.1, 19.6, 27.8 MiB/s

After samples:

- Sequential: 16.5, 16.5, 17.1, 16.8, 17.0 MiB/s
- 16-stream: 29.0, 27.2, 29.2, 27.4, 16.8 MiB/s

### FSKit mount versus native I/O

| Test | Before | After |
| --- | ---: | ---: |
| Random 4 KiB read | 1,250.1 us/op | 1,302.8 us/op |
| Sequential `F_NOCACHE` | 13.2 MiB/s | 12.7 MiB/s |
| Warm sequential | 17,944.1 MiB/s | 17,215.5 MiB/s |
| `stat` | 0.8 us/op | 0.8 us/op |
| `readdir` | 515.2 us/op | 524.4 us/op |
| Recursive enumeration | 27,105 entries/s | 26,284 entries/s |
| Small-file open + read | 2,437.7 IOPS | 2,318.8 IOPS |
| Directory listing | 536.2 IOPS | 513.3 IOPS |

A fresh-mount random-read scaling check after the change measured 768 IOPS
with one worker and 1,869 IOPS with 16 workers, a 2.43x throughput increase.

### Interpretation

DispatchIO removes regular-file reads and byte copying from the serialized
HTTP/3 connection actor. Routing operations such as `lstat` and directory
enumeration run on a separate Dispatch queue. This prevents file I/O from
stalling QUIC packet, ACK, and timeout processing, but it does not materially
raise throughput: the before/after differences above are within run-to-run
variance. The remaining performance ceiling is in the shared HTTP/3 packet
pump rather than synchronous file reads.

The after measurements also include reducing the per-datagram output buffer
from 65,535 bytes to the configured 1,350-byte QUIC payload size. Without that
change, 16-stream runs frequently collapsed to approximately 16--18 MiB/s.
