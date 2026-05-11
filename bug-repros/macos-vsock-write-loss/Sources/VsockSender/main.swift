// VsockSender — runs inside a macOS guest VM.
//
// Binds an AF_VSOCK listener on the given port, accepts one connection, then
// writes N bytes of filler data using non-blocking write() + kqueue's
// EVFILT_WRITE for back-pressure. Logs stats at the end.
//
// The reproducer demonstrates whether macOS's AF_VSOCK reliably signals
// writability via EVFILT_WRITE during sustained non-blocking writes, and
// whether the full byte count delivered matches what write() returns.
//
// Usage (inside the VM):
//   VsockSender <port> <bytes>
// Example:
//   VsockSender 5000 134217728   # listen on vsock port 5000, write 128 MiB
//
// No external deps — pure Darwin.

import Darwin
import Foundation

// Unbuffer stdout so `tail -f` / piped progress shows up live.
setbuf(stdout, nil)

let args = CommandLine.arguments
guard args.count == 3,
      let port = UInt32(args[1]),
      let totalBytes = Int(args[2]),
      totalBytes > 0 else {
    FileHandle.standardError.write(Data("Usage: \(args[0]) <vsock-port> <total-bytes>\n".utf8))
    exit(2)
}

// MARK: - Vsock listen socket

let listenFD = socket(AF_VSOCK, SOCK_STREAM, 0)
guard listenFD >= 0 else {
    perror("socket(AF_VSOCK)"); exit(1)
}

var one: Int32 = 1
setsockopt(listenFD, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))

var addr = sockaddr_vm()
addr.svm_family = sa_family_t(AF_VSOCK)
addr.svm_cid = VMADDR_CID_ANY
addr.svm_port = port

let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_vm>.size))
    }
}
guard bindResult == 0 else { perror("bind"); exit(1) }
guard listen(listenFD, 1) == 0 else { perror("listen"); exit(1) }

print("VsockSender: listening on vsock port \(port), will write \(totalBytes) bytes per connection")

// MARK: - Accept loop

while true {
    var clientAddr = sockaddr_vm()
    var clientAddrLen = socklen_t(MemoryLayout<sockaddr_vm>.size)
    let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr -> Int32 in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            accept(listenFD, $0, &clientAddrLen)
        }
    }
    guard clientFD >= 0 else {
        perror("accept"); continue
    }
    print("VsockSender: accepted client (fd=\(clientFD))")

    runWriteTest(clientFD: clientFD, totalBytes: totalBytes)
    close(clientFD)
}

// MARK: - The write test

func runWriteTest(clientFD: Int32, totalBytes: Int) {
    // Make the socket non-blocking — this is the mode NIO uses, and the
    // mode where this bug manifests.
    let flags = fcntl(clientFD, F_GETFL, 0)
    _ = fcntl(clientFD, F_SETFL, flags | O_NONBLOCK)

    // Set up a kqueue with EVFILT_WRITE on clientFD.
    let kq = kqueue()
    guard kq >= 0 else { perror("kqueue"); return }
    defer { close(kq) }

    var addEvent = kevent(
        ident: UInt(clientFD),
        filter: Int16(EVFILT_WRITE),
        flags: UInt16(EV_ADD | EV_CLEAR),
        fflags: 0, data: 0, udata: nil
    )
    if kevent(kq, &addEvent, 1, nil, 0, nil) < 0 {
        perror("kevent(EV_ADD,EVFILT_WRITE)"); return
    }

    // Fixed payload — 0xAB so any byte loss is obvious in a hex dump.
    let chunkSize = 65536
    var chunk = [UInt8](repeating: 0xAB, count: chunkSize)

    var bytesSent = 0
    var writeCalls = 0
    var eagainCount = 0
    var kqueueWaits = 0
    var kqueueTimeouts = 0
    let started = Date()
    var lastLog = started

    while bytesSent < totalBytes {
        let toSend = min(chunkSize, totalBytes - bytesSent)
        let n = chunk.withUnsafeBytes { ptr -> Int in
            Darwin.write(clientFD, ptr.baseAddress, toSend)
        }
        writeCalls += 1

        if n > 0 {
            bytesSent += n
            if Date().timeIntervalSince(lastLog) > 1.0 {
                let mb = Double(bytesSent) / 1_048_576
                print(String(format: "  …sent %.2f MiB (%d/%d), writeCalls=%d, EAGAIN=%d, kqueueWaits=%d, kqueueTimeouts=%d",
                             mb, bytesSent, totalBytes, writeCalls, eagainCount, kqueueWaits, kqueueTimeouts))
                lastLog = Date()
            }
        } else if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
            eagainCount += 1
            // Wait for writability with a generous 10-second timeout per wait.
            // If EVFILT_WRITE never fires, kevent() will time out and we'll
            // know the kernel didn't tell us the socket became writable.
            var event = kevent()
            var ts = timespec(tv_sec: 10, tv_nsec: 0)
            let r = kevent(kq, nil, 0, &event, 1, &ts)
            kqueueWaits += 1
            if r < 0 {
                perror("kevent(wait)"); break
            }
            if r == 0 {
                kqueueTimeouts += 1
                print("  !! kqueue WAIT TIMEOUT at bytesSent=\(bytesSent)/\(totalBytes) — EVFILT_WRITE never fired")
                // Try a write anyway, in case the buffer drained without us being notified.
            }
        } else if n < 0 && errno == EINTR {
            continue
        } else {
            perror("write")
            break
        }
    }

    let elapsed = Date().timeIntervalSince(started)
    let mbps = Double(bytesSent) / 1_048_576 / elapsed
    print("""
        VsockSender: FINISHED writing
          requested:      \(totalBytes) bytes
          actually sent:  \(bytesSent) bytes (via successful write() returns)
          missing:        \(totalBytes - bytesSent) bytes
          time:           \(String(format: "%.2f", elapsed)) s
          throughput:     \(String(format: "%.2f", mbps)) MiB/s
          write() calls:  \(writeCalls)
          EAGAIN count:   \(eagainCount)
          kqueue waits:   \(kqueueWaits)
          kqueue timeouts:\(kqueueTimeouts)
        """)

    // Keep the connection open briefly so the receiver has time to read the
    // last bytes from its kernel buffer, then close.
    print("VsockSender: pausing 3 s before close")
    Thread.sleep(forTimeInterval: 3.0)
}
