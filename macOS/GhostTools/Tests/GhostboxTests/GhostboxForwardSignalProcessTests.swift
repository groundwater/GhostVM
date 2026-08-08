@testable import ghostbox
import Darwin
import Foundation
import XCTest

final class GhostboxForwardSignalProcessTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        signal(SIGPIPE, SIG_IGN)
    }

    func testRepeatedSIGTERMCleansUpBeforeNormalExit() async throws {
        #if !DEBUG
        throw XCTSkip("process signal control is available only in debug builds")
        #else
        let executable = try ghostboxExecutableURL()
        let publishedPort = try reserveEphemeralPort()
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = executable
        process.arguments = [
            "cn:container:forward",
            "@container/signal-test",
            "-p",
            "127.0.0.1:\(publishedPort):1",
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["GHOSTBOX_FORWARD_SIGNAL_TEST_CONTROL"] = "1"
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        addTeardownBlock {
            try? input.fileHandleForWriting.write(contentsOf: Data([0, 0]))
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            await Self.waitForExit(process)
        }

        XCTAssertEqual(try readLine(from: output.fileHandleForReading.fileDescriptor), "READY")
        XCTAssertEqual(Darwin.kill(process.processIdentifier, SIGTERM), 0)
        XCTAssertEqual(try readLine(from: output.fileHandleForReading.fileDescriptor), "CLEANUP")

        XCTAssertEqual(Darwin.kill(process.processIdentifier, SIGTERM), 0)
        try input.fileHandleForWriting.write(contentsOf: Data([0]))
        XCTAssertEqual(try readLine(from: output.fileHandleForReading.fileDescriptor), "STOPPED")

        let replacement = try makeListener(port: publishedPort)
        Darwin.close(replacement)
        try input.fileHandleForWriting.write(contentsOf: Data([0]))
        await Self.waitForExit(process)

        guard !process.isRunning else {
            return XCTFail("ghostbox did not exit after forwarding cleanup")
        }
        XCTAssertEqual(process.terminationReason, .exit)
        XCTAssertEqual(process.terminationStatus, 128 + SIGTERM)
        XCTAssertEqual(errors.fileHandleForReading.readDataToEndOfFile(), Data())
        #endif
    }

    private func ghostboxExecutableURL() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["GHOSTBOX_TEST_EXECUTABLE"] {
            let url = URL(fileURLWithPath: override)
            guard FileManager.default.isExecutableFile(atPath: url.path) else {
                throw POSIXError(.ENOENT)
            }
            return url
        }

        let url = Bundle(for: Self.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("ghostbox")
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw POSIXError(.ENOENT)
        }
        return url
    }

    private func readLine(from fd: Int32) throws -> String {
        var data = Data()
        while data.count < 64 {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN | POLLHUP), revents: 0)
            guard Darwin.poll(&descriptor, 1, 3_000) > 0 else {
                throw POSIXError(.ETIMEDOUT)
            }
            var byte = UInt8(0)
            let count = Darwin.read(fd, &byte, 1)
            if count == 1 {
                if byte == UInt8(ascii: "\n") { return String(decoding: data, as: UTF8.self) }
                data.append(byte)
            } else if count == 0 {
                throw POSIXError(.ECONNRESET)
            } else if errno != EINTR {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        throw POSIXError(.EMSGSIZE)
    }

    private func reserveEphemeralPort() throws -> UInt16 {
        let fd = try makeListener(port: 0)
        defer { Darwin.close(fd) }
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(fd, $0, &length)
            }
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return UInt16(bigEndian: address.sin_port)
    }

    private func makeListener(port: UInt16) throws -> Int32 {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, Darwin.listen(fd, 16) == 0 else {
            let code = errno
            Darwin.close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        return fd
    }

    private static func waitForExit(_ process: Process) async {
        for _ in 0..<300 where process.isRunning {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}
