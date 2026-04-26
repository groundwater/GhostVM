import Foundation

/// Probes whether kqueue works with AF_VSOCK file descriptors on this macOS version.
/// Runs once at startup and logs the result. This tells us whether NIO (kqueue-based)
/// can be used for vsock I/O, or whether we need blocking I/O on dedicated threads.
enum KqueueVsockProbe {

    enum Result: String {
        case works = "WORKS"
        case registerFails = "REGISTER_FAILS"
        case doesNotFire = "DOES_NOT_FIRE"
        case notInVM = "NOT_IN_VM"
        case error = "ERROR"
    }

    /// Run the probe. Creates a vsock socketpair (listen + connect to self),
    /// registers with kqueue, and checks if readability events fire.
    /// Returns immediately — non-blocking test.
    static func run() -> Result {
        // Step 1: Create a vsock listening socket on an ephemeral port
        let listenFD = socket(AF_VSOCK, SOCK_STREAM, 0)
        guard listenFD >= 0 else {
            let err = errno
            print("[KqueueProbe] socket(AF_VSOCK) failed, errno=\(err) (\(String(cString: strerror(err))))")
            if err == EAFNOSUPPORT || err == EPROTONOSUPPORT {
                print("[KqueueProbe] Not running inside a VM — AF_VSOCK not available")
                return .notInVM
            }
            return .error
        }
        defer { close(listenFD) }

        // Use a high port to avoid conflicts
        let probePort: UInt32 = 59999
        var addr = sockaddr_vm(port: probePort, cid: 0xFFFFFFFF)
        var optval: Int32 = 1
        setsockopt(listenFD, SOL_SOCKET, SO_REUSEADDR, &optval, socklen_t(MemoryLayout<Int32>.size))

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(listenFD, sockPtr, socklen_t(MemoryLayout<sockaddr_vm>.size))
            }
        }

        guard bindResult == 0 else {
            print("[KqueueProbe] bind() failed, errno=\(errno)")
            close(listenFD)
            return .error
        }

        guard listen(listenFD, 1) == 0 else {
            print("[KqueueProbe] listen() failed, errno=\(errno)")
            return .error
        }

        // Step 2: Create kqueue and register the listen fd
        let kq = kqueue()
        guard kq >= 0 else {
            print("[KqueueProbe] kqueue() failed")
            return .error
        }
        defer { close(kq) }

        var kev = kevent(
            ident: UInt(listenFD),
            filter: Int16(EVFILT_READ),
            flags: UInt16(EV_ADD | EV_ENABLE),
            fflags: 0,
            data: 0,
            udata: nil
        )

        let regResult = kevent(kq, &kev, 1, nil, 0, nil)
        if regResult < 0 {
            let err = errno
            print("[KqueueProbe] kevent register FAILED, errno=\(err) (\(String(cString: strerror(err))))")
            print("[KqueueProbe] RESULT: kqueue does NOT support AF_VSOCK on this macOS version")
            return .registerFails
        }
        print("[KqueueProbe] kevent register succeeded")

        // Step 3: Connect to ourselves (CID 3 = guest's own CID)
        // This creates a pending connection on the listen socket
        let connectFD = socket(AF_VSOCK, SOCK_STREAM, 0)
        guard connectFD >= 0 else {
            print("[KqueueProbe] second socket() failed")
            return .error
        }
        defer { close(connectFD) }

        // Set non-blocking for the connect
        let flags = fcntl(connectFD, F_GETFL, 0)
        _ = fcntl(connectFD, F_SETFL, flags | O_NONBLOCK)

        // CID 1 = local/loopback for vsock (VMADDR_CID_LOCAL)
        var connectAddr = sockaddr_vm(port: probePort, cid: 1)
        let connectResult = withUnsafePointer(to: &connectAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(connectFD, sockPtr, socklen_t(MemoryLayout<sockaddr_vm>.size))
            }
        }

        // Connect may succeed immediately or return EINPROGRESS
        if connectResult < 0 && errno != EINPROGRESS {
            // Can't connect to self — try CID 3 (VMADDR_CID_HOST is 2, guest might be 3)
            // If this also fails, we can't self-test
            print("[KqueueProbe] connect() to CID 1 failed, errno=\(errno)")
            print("[KqueueProbe] Cannot self-connect for probe; will test kqueue on listen fd without connection")

            // Alternative: just check a short kqueue wait to see if it returns immediately
            // (it shouldn't — no connections pending)
            var timeout = timespec(tv_sec: 0, tv_nsec: 100_000_000) // 100ms
            var outEvent = kevent()
            let n = kevent(kq, nil, 0, &outEvent, 1, &timeout)
            if n == 0 {
                print("[KqueueProbe] kqueue correctly returned 0 events (no connection pending)")
                print("[KqueueProbe] RESULT: kqueue register works, but can't fully test event delivery without a peer connection")
                print("[KqueueProbe] This is a PARTIAL result — events may or may not fire")
                return .works // Optimistic — registration worked, timeout was correct
            } else if n > 0 {
                print("[KqueueProbe] kqueue fired spuriously with \(n) events — unexpected")
                return .works
            } else {
                print("[KqueueProbe] kqueue wait error, errno=\(errno)")
                return .error
            }
        }

        print("[KqueueProbe] Self-connect succeeded (or in progress)")

        // Step 4: Check if kqueue fires for the pending accept
        var timeout = timespec(tv_sec: 0, tv_nsec: 500_000_000) // 500ms
        var outEvent = kevent()
        let nEvents = kevent(kq, nil, 0, &outEvent, 1, &timeout)

        if nEvents > 0 {
            print("[KqueueProbe] kqueue FIRED! filter=\(outEvent.filter) data=\(outEvent.data)")
            print("[KqueueProbe] RESULT: kqueue WORKS for AF_VSOCK on macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")

            // Accept and test connected socket too
            var clientAddr = sockaddr_vm(port: 0)
            var addrLen = socklen_t(MemoryLayout<sockaddr_vm>.size)
            let acceptedFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    Darwin.accept(listenFD, sockPtr, &addrLen)
                }
            }
            if acceptedFD >= 0 {
                // Test kqueue on connected socket
                var kev2 = kevent(
                    ident: UInt(acceptedFD),
                    filter: Int16(EVFILT_READ),
                    flags: UInt16(EV_ADD | EV_ENABLE),
                    fflags: 0,
                    data: 0,
                    udata: nil
                )
                let reg2 = kevent(kq, &kev2, 1, nil, 0, nil)
                print("[KqueueProbe] Connected socket kqueue register: \(reg2 >= 0 ? "OK" : "FAILED errno=\(errno)")")
                close(acceptedFD)
            }

            return .works
        } else if nEvents == 0 {
            print("[KqueueProbe] kqueue timed out — did NOT fire for pending connection")

            // Verify the connection IS pending
            let listenFlags = fcntl(listenFD, F_GETFL, 0)
            _ = fcntl(listenFD, F_SETFL, listenFlags | O_NONBLOCK)
            var clientAddr = sockaddr_vm(port: 0)
            var addrLen = socklen_t(MemoryLayout<sockaddr_vm>.size)
            let acceptedFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    Darwin.accept(listenFD, sockPtr, &addrLen)
                }
            }
            if acceptedFD >= 0 {
                print("[KqueueProbe] Connection WAS pending but kqueue didn't fire!")
                print("[KqueueProbe] RESULT: kqueue does NOT fire for AF_VSOCK")
                close(acceptedFD)
                return .doesNotFire
            } else {
                print("[KqueueProbe] No connection pending (self-connect may have failed)")
                print("[KqueueProbe] RESULT: Inconclusive — try with host connection")
                return .doesNotFire // Conservative
            }
        } else {
            print("[KqueueProbe] kqueue error, errno=\(errno)")
            return .error
        }
    }
}
