import XCTest
import Foundation
import GhostHTTP
@testable import GhostTools

final class WebSocketShellIntegrationTests: XCTestCase {

    private final class LockedErrorBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storedError: Error?

        func set(_ error: Error) {
            lock.lock()
            storedError = error
            lock.unlock()
        }

        func get() -> Error? {
            lock.lock()
            defer { lock.unlock() }
            return storedError
        }
    }

    func testShellRoundTripPlainText() throws {
        let session = try runShellSession(command: "printf 'alpha\\nbeta\\n'")
        XCTAssertEqual(session.output, "alpha\r\nbeta\r\n")
    }

    func testShellNoDoubleCarriageReturnOnLF() throws {
        let session = try runShellSession(command: "printf 'left\\nright\\n'")
        XCTAssertFalse(session.output.contains("\r\r\n"))
    }

    func testShellResizeControlMessage() throws {
        let resizeMessage = #"{"type":"resize","cols":132,"rows":43}"#
        let session = try runShellSession(
            command: "while [ \"$(stty size)\" != \"43 132\" ]; do sleep 0.05; done; stty size",
            clientFrames: [
                WSFrameEncoder.encode(opcode: .text, payload: Array(resizeMessage.utf8), mask: true)
            ]
        )
        XCTAssertEqual(session.output, "43 132\r\n", "expected resized PTY dimensions in output, got: \(session.output)")
    }

    private func runShellSession(
        command: String,
        clientFrames: [[UInt8]] = [],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> ShellSessionResult {
        var fds = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0, file: file, line: line)
        let serverFD = fds[0]
        let clientFD = fds[1]

        configureTimeouts(fd: serverFD)
        configureTimeouts(fd: clientFD)

        let serverDone = DispatchGroup()
        let serverError = LockedErrorBox()
        serverDone.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer {
                Darwin.close(serverFD)
                serverDone.leave()
            }
            do {
                let (request, prelude) = try HTTPCodec.readRequest(fd: serverFD)
                try WebSocketShell.handleUpgradeAndRun(
                    fd: serverFD,
                    request: request,
                    cols: 80,
                    rows: 24,
                    term: "xterm-256color",
                    prelude: prelude,
                    launchConfiguration: .init(
                        executablePath: "/bin/sh",
                        arguments: ["sh", "-c", command],
                        environment: ["TERM": "xterm-256color"]
                    )
                )
            } catch {
                serverError.set(error)
            }
        }

        defer {
            Darwin.close(clientFD)
        }

        var wsKeyBytes = [UInt8](repeating: 0, count: 16)
        arc4random_buf(&wsKeyBytes, wsKeyBytes.count)
        let upgraded = try HTTPClient.performUpgradeRequest(
            fd: clientFD,
            path: "/api/v1/shell?cols=80&rows=24&term=xterm-256color",
            headers: HTTPHeaders([
                "Host": "localhost",
                "Upgrade": "websocket",
                "Connection": "Upgrade",
                "Sec-WebSocket-Key": Data(wsKeyBytes).base64EncodedString(),
                "Sec-WebSocket-Version": "13",
            ])
        )
        XCTAssertEqual(upgraded.responseHead.status, .switchingProtocols)

        for frame in clientFrames {
            try writeAll(fd: clientFD, data: Data(frame))
        }

        var parser = WSFrameParser()
        if !upgraded.prelude.isEmpty {
            parser.feed(Array(upgraded.prelude))
        }

        var output = Data()
        readLoop: while true {
            while let frame = parser.nextFrame() {
                switch frame.opcode {
                case .binary:
                    output.append(contentsOf: frame.payload)
                case .close:
                    break readLoop
                case .ping:
                    let pong = WSFrameEncoder.encode(opcode: .pong, payload: frame.payload, mask: true)
                    try writeAll(fd: clientFD, data: Data(pong))
                default:
                    break
                }
            }

            var buffer = [UInt8](repeating: 0, count: 4096)
            let n = Darwin.read(clientFD, &buffer, buffer.count)
            if n > 0 {
                parser.feed(Array(buffer[0..<n]))
                continue
            }
            if n == 0 {
                break
            }
            if errno == EINTR {
                continue
            }
            XCTFail("client read failed with errno \(errno)", file: file, line: line)
            break
        }

        let closeFrame = WSFrameEncoder.encode(opcode: .close, payload: [], mask: true)
        try? writeAll(fd: clientFD, data: Data(closeFrame))

        if serverDone.wait(timeout: .now() + 5) == .timedOut {
            XCTFail("server shell did not exit", file: file, line: line)
        }
        if let serverError = serverError.get() {
            throw serverError
        }

        return ShellSessionResult(output: String(decoding: output, as: UTF8.self))
    }

    private func configureTimeouts(fd: Int32) {
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        XCTAssertEqual(
            withUnsafePointer(to: &timeout) {
                setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
            },
            0
        )
        XCTAssertEqual(
            withUnsafePointer(to: &timeout) {
                setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
            },
            0
        )
    }

    private func writeAll(fd: Int32, data: Data) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let n = Darwin.write(fd, base + offset, bytes.count - offset)
                if n > 0 {
                    offset += n
                } else if n < 0 && errno == EINTR {
                    continue
                } else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
        }
    }
}

private struct ShellSessionResult {
    let output: String
}
