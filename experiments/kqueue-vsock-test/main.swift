#!/usr/bin/env swift
//
// kqueue-vsock-test: Does kqueue fire for AF_VSOCK on macOS?
//
// Run inside a macOS guest VM. Listens on vsock port 9999,
// then tests whether kqueue/poll/DispatchSource detect readability
// on the accepted connection.
//
// Usage:
//   1. Build & run in the guest:  swift main.swift
//   2. From the host, connect:    vmctl remote --name <VM> exec /usr/bin/true
//      (or any other vsock connection to port 9999)
//

import Foundation
import Darwin

// MARK: - vsock constants & structs

let AF_VSOCK: Int32 = 40
let VMADDR_CID_ANY: UInt32 = 0xFFFFFFFF

struct sockaddr_vm {
    var svm_len: UInt8
    var svm_family: UInt8
    var svm_reserved1: UInt16
    var svm_port: UInt32
    var svm_cid: UInt32
    var svm_zero: (UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 0)

    init(port: UInt32, cid: UInt32 = VMADDR_CID_ANY) {
        self.svm_len = UInt8(MemoryLayout<sockaddr_vm>.size)
        self.svm_family = UInt8(AF_VSOCK)
        self.svm_reserved1 = 0
        self.svm_port = port
        self.svm_cid = cid
    }
}

// MARK: - Create & bind server socket

let testPort: UInt32 = 9999

let serverFD = socket(AF_VSOCK, SOCK_STREAM, 0)
guard serverFD >= 0 else {
    print("FAIL: socket() failed, errno=\(errno) (\(String(cString: strerror(errno))))")
    print("      Are you running inside a macOS VM?")
    exit(1)
}

var optval: Int32 = 1
setsockopt(serverFD, SOL_SOCKET, SO_REUSEADDR, &optval, socklen_t(MemoryLayout<Int32>.size))

var addr = sockaddr_vm(port: testPort)
let bindResult = withUnsafePointer(to: &addr) { ptr in
    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
        Darwin.bind(serverFD, sockPtr, socklen_t(MemoryLayout<sockaddr_vm>.size))
    }
}
guard bindResult == 0 else {
    print("FAIL: bind() failed, errno=\(errno) (\(String(cString: strerror(errno))))")
    close(serverFD)
    exit(1)
}

guard listen(serverFD, 1) == 0 else {
    print("FAIL: listen() failed, errno=\(errno)")
    close(serverFD)
    exit(1)
}

print("Listening on vsock port \(testPort)...")
print("Now connect from the host to trigger the test.")
print("")

// MARK: - Test 1: kqueue on the LISTEN socket (accept readiness)

print("=== Test 1: kqueue on listen socket (waiting for connection) ===")

let kq = kqueue()
guard kq >= 0 else {
    print("FAIL: kqueue() failed, errno=\(errno)")
    close(serverFD)
    exit(1)
}

// Register EVFILT_READ on the server socket
var kev = kevent(
    ident: UInt(serverFD),
    filter: Int16(EVFILT_READ),
    flags: UInt16(EV_ADD | EV_ENABLE),
    fflags: 0,
    data: 0,
    udata: nil
)

let registerResult = kevent(kq, &kev, 1, nil, 0, nil)
if registerResult < 0 {
    print("FAIL: kevent register failed, errno=\(errno) (\(String(cString: strerror(errno))))")
    print("      kqueue does NOT support AF_VSOCK on this macOS version.")
    close(kq)
    close(serverFD)
    exit(1)
}
print("  kevent register: OK (no error)")

// Wait for readability with a 30-second timeout
print("  Waiting up to 30s for kqueue to fire on listen socket...")
var timeout = timespec(tv_sec: 30, tv_nsec: 0)
var outEvent = kevent()
let nEvents = kevent(kq, nil, 0, &outEvent, 1, &timeout)

if nEvents < 0 {
    print("  FAIL: kevent wait failed, errno=\(errno) (\(String(cString: strerror(errno))))")
    close(kq)
    close(serverFD)
    exit(1)
} else if nEvents == 0 {
    print("  TIMEOUT: kqueue did NOT fire within 30s.")
    print("  Trying blocking accept() to see if a connection is actually pending...")

    // Set non-blocking to test
    let flags = fcntl(serverFD, F_GETFL, 0)
    _ = fcntl(serverFD, F_SETFL, flags | O_NONBLOCK)
    var clientAddr = sockaddr_vm(port: 0)
    var addrLen = socklen_t(MemoryLayout<sockaddr_vm>.size)
    let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
            Darwin.accept(serverFD, sockPtr, &addrLen)
        }
    }
    if clientFD >= 0 {
        print("  RESULT: Connection WAS pending but kqueue didn't fire! kqueue BROKEN for vsock.")
        close(clientFD)
    } else {
        print("  RESULT: No connection pending. Timed out waiting for a connection.")
        print("          Connect from host and re-run to test.")
    }
    close(kq)
    close(serverFD)
    exit(1)
} else {
    print("  kqueue FIRED! nEvents=\(nEvents)")
    print("  filter=\(outEvent.filter) flags=\(outEvent.flags) data=\(outEvent.data)")
    print("  RESULT: kqueue WORKS for AF_VSOCK listen sockets!")
}

close(kq)

// MARK: - Accept the connection

var clientAddr = sockaddr_vm(port: 0)
var addrLen = socklen_t(MemoryLayout<sockaddr_vm>.size)
let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
        Darwin.accept(serverFD, sockPtr, &addrLen)
    }
}
guard clientFD >= 0 else {
    print("FAIL: accept() failed, errno=\(errno)")
    close(serverFD)
    exit(1)
}
print("\nAccepted connection (fd=\(clientFD))")

// MARK: - Test 2: kqueue on connected socket (data readiness)

print("\n=== Test 2: kqueue on connected socket (waiting for data) ===")

let kq2 = kqueue()
guard kq2 >= 0 else {
    print("FAIL: kqueue() failed")
    close(clientFD)
    close(serverFD)
    exit(1)
}

var kev2 = kevent(
    ident: UInt(clientFD),
    filter: Int16(EVFILT_READ),
    flags: UInt16(EV_ADD | EV_ENABLE),
    fflags: 0,
    data: 0,
    udata: nil
)

let reg2 = kevent(kq2, &kev2, 1, nil, 0, nil)
if reg2 < 0 {
    print("  FAIL: kevent register on connected socket, errno=\(errno) (\(String(cString: strerror(errno))))")
} else {
    print("  kevent register: OK")
}

// The host should be sending HTTP data, so wait for it
var timeout2 = timespec(tv_sec: 10, tv_nsec: 0)
var outEvent2 = kevent()
let nEvents2 = kevent(kq2, nil, 0, &outEvent2, 1, &timeout2)

if nEvents2 > 0 {
    print("  kqueue FIRED on connected socket! data=\(outEvent2.data)")

    // Try reading
    var buf = [UInt8](repeating: 0, count: 4096)
    let n = read(clientFD, &buf, buf.count)
    if n > 0 {
        let str = String(bytes: buf[0..<n], encoding: .utf8) ?? "<binary \(n) bytes>"
        print("  Read \(n) bytes: \(str.prefix(200))")
    }
    print("  RESULT: kqueue WORKS for AF_VSOCK connected sockets!")
} else if nEvents2 == 0 {
    print("  TIMEOUT: kqueue did NOT fire on connected socket within 10s")

    // Check if data is actually available via blocking read
    let flags = fcntl(clientFD, F_GETFL, 0)
    _ = fcntl(clientFD, F_SETFL, flags | O_NONBLOCK)
    var buf = [UInt8](repeating: 0, count: 4096)
    let n = read(clientFD, &buf, buf.count)
    if n > 0 {
        print("  Data WAS available (\(n) bytes) but kqueue didn't fire! BROKEN.")
    } else if n == 0 {
        print("  EOF — connection closed by host before sending data")
    } else {
        print("  EAGAIN — no data pending. Host may not have sent anything yet.")
    }
    print("  RESULT: kqueue does NOT work for AF_VSOCK connected sockets.")
} else {
    print("  FAIL: kevent wait error, errno=\(errno)")
}

// MARK: - Test 3: poll() on connected socket

print("\n=== Test 3: poll() on connected socket ===")

var pollFD = pollfd(fd: clientFD, events: Int16(POLLIN), revents: 0)
let pollResult = poll(&pollFD, 1, 5000) // 5s timeout

if pollResult > 0 {
    print("  poll() returned \(pollResult), revents=\(pollFD.revents)")
    print("  RESULT: poll() WORKS for AF_VSOCK!")
} else if pollResult == 0 {
    print("  poll() timed out")
    print("  RESULT: poll() does NOT work for AF_VSOCK.")
} else {
    print("  poll() error, errno=\(errno)")
}

// MARK: - Test 4: DispatchSource read source

print("\n=== Test 4: DispatchSource.makeReadSource on connected socket ===")

// Write some data back to the client so the host side gets a response,
// then the host might close — we just want to see if DispatchSource fires

let semaphore = DispatchSemaphore(value: 0)
var dispatchSourceFired = false

let readSource = DispatchSource.makeReadSource(fileDescriptor: clientFD, queue: .global())
readSource.setEventHandler {
    dispatchSourceFired = true
    print("  DispatchSource FIRED! estimatedBytes=\(readSource.data)")
    semaphore.signal()
}
readSource.setCancelHandler {
    if !dispatchSourceFired {
        print("  DispatchSource was cancelled without firing")
    }
}
readSource.resume()

let waitResult = semaphore.wait(timeout: .now() + 5)
readSource.cancel()

if waitResult == .timedOut && !dispatchSourceFired {
    print("  DispatchSource did NOT fire within 5s")
    print("  RESULT: DispatchSource does NOT work for AF_VSOCK.")
} else if dispatchSourceFired {
    print("  RESULT: DispatchSource WORKS for AF_VSOCK!")
}

// MARK: - Summary

print("\n=== Summary ===")
print("macOS version: \(ProcessInfo.processInfo.operatingSystemVersionString)")
print("Tests complete. See results above.")

close(kq2)
close(clientFD)
close(serverFD)
