import XCTest
@testable import GhostVMKit
#if canImport(Darwin)
import Darwin
#endif

final class WebSocketShellClientTests: XCTestCase {

    func testClientConsumesServerOutputExactlyUnderBurst() throws {
        let output = makeScreenLikePayload(lineCount: 1500)
        let harness = try ClientHarness()
        let reader = OutputReader(masterFD: harness.outputMasterFD)
        reader.start()

        let serverDone = DispatchGroup()
        serverDone.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer {
                Darwin.close(harness.serverFD)
                serverDone.leave()
            }
            for chunk in Self.chunk(data: output, sizes: [1, 2, 7, 31, 127, 509, 2048]) {
                let frame = self.makeServerFrame(opcode: 0x02, payload: Array(chunk))
                _ = Self.writeAll(fd: harness.serverFD, data: Data(frame))
            }
            let closeFrame = self.makeServerFrame(opcode: 0x08, payload: [])
            _ = Self.writeAll(fd: harness.serverFD, data: Data(closeFrame))
        }

        harness.runClientOrFail()
        Darwin.close(harness.outputSlaveFD)
        Darwin.close(harness.inputWriteFD)
        Darwin.close(harness.inputReadFD)

        XCTAssertEqual(serverDone.wait(timeout: .now() + 5), .success)
        let captured = reader.finish()
        XCTAssertEqual(captured, output)
    }

    func testClientProducesExactBinaryPayloadUnderBurst() throws {
        let inputPayload = makeInputPayload(byteCount: 2 * 1024 * 1024 + 173)
        let harness = try ClientHarness()
        let reader = OutputReader(masterFD: harness.outputMasterFD)
        reader.start()

        let receivedBox = LockedDataBox()
        let serverDone = DispatchGroup()
        serverDone.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer {
                Darwin.close(harness.serverFD)
                serverDone.leave()
            }
            var parser = WebSocketClientFrameParser()
            var buffer = [UInt8](repeating: 0, count: 8192)
            var received = Data()
            while true {
                let n = Darwin.read(harness.serverFD, &buffer, buffer.count)
                if n > 0 {
                    parser.feed(Array(buffer[0..<n]))
                    while let frame = parser.nextFrame() {
                        switch frame.opcode {
                        case 0x02:
                            received.append(contentsOf: frame.payload)
                        case 0x09:
                            let pong = self.makeServerFrame(opcode: 0x0A, payload: frame.payload)
                            _ = Self.writeAll(fd: harness.serverFD, data: Data(pong))
                        case 0x08:
                            receivedBox.set(received)
                            return
                        default:
                            break
                        }
                    }
                } else if n == 0 {
                    receivedBox.set(received)
                    return
                } else if errno == EINTR {
                    continue
                } else {
                    receivedBox.set(received)
                    return
                }
            }
        }

        let inputWriter = DispatchGroup()
        inputWriter.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer {
                Darwin.close(harness.inputWriteFD)
                inputWriter.leave()
            }
            for chunk in Self.chunk(data: inputPayload, sizes: [3, 17, 257, 4093, 6553]) {
                _ = Self.writeAll(fd: harness.inputWriteFD, data: chunk)
            }
        }

        harness.runClientOrFail()
        Darwin.close(harness.outputSlaveFD)
        Darwin.close(harness.inputReadFD)

        XCTAssertEqual(inputWriter.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(serverDone.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(receivedBox.get(), inputPayload)
        _ = reader.finish()
    }

    func testClientFlushesPendingInputBeforeEOFShutdown() throws {
        let inputPayload = makeInputPayload(byteCount: 512 * 1024 + 37)
        let harness = try ClientHarness()
        let reader = OutputReader(masterFD: harness.outputMasterFD)
        reader.start()
        harness.setClientSendBuffer(bytes: 4096)

        let receivedBox = LockedDataBox()
        let serverDone = DispatchGroup()
        serverDone.enter()
        DispatchQueue.global(qos: .utility).async {
            defer {
                Darwin.close(harness.serverFD)
                serverDone.leave()
            }
            usleep(150_000)
            var parser = WebSocketClientFrameParser()
            var buffer = [UInt8](repeating: 0, count: 4096)
            var received = Data()
            while true {
                let n = Darwin.read(harness.serverFD, &buffer, buffer.count)
                if n > 0 {
                    parser.feed(Array(buffer[0..<n]))
                    while let frame = parser.nextFrame() {
                        if frame.opcode == 0x02 {
                            received.append(contentsOf: frame.payload)
                        }
                    }
                } else if n == 0 {
                    receivedBox.set(received)
                    return
                } else if errno == EINTR {
                    continue
                } else {
                    receivedBox.set(received)
                    return
                }
            }
        }

        let inputWriter = DispatchGroup()
        inputWriter.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer {
                Darwin.close(harness.inputWriteFD)
                inputWriter.leave()
            }
            _ = Self.writeAll(fd: harness.inputWriteFD, data: inputPayload)
        }

        harness.runClientOrFail()
        Darwin.close(harness.outputSlaveFD)
        Darwin.close(harness.inputReadFD)

        XCTAssertEqual(inputWriter.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(serverDone.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(receivedBox.get(), inputPayload)
        _ = reader.finish()
    }

    func testClientProcessesPreludeBeforeAdditionalSocketReads() throws {
        let preludePayload = Data("prelude-first-frame\r\n".utf8)
        let harness = try ClientHarness()
        let reader = OutputReader(masterFD: harness.outputMasterFD)
        reader.start()

        let serverDone = DispatchGroup()
        serverDone.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer {
                Darwin.close(harness.serverFD)
                serverDone.leave()
            }
            usleep(100_000)
            let closeFrame = self.makeServerFrame(opcode: 0x08, payload: [])
            _ = Self.writeAll(fd: harness.serverFD, data: Data(closeFrame))
        }

        harness.runClientOrFail(prelude: Data(makeServerFrame(opcode: 0x02, payload: Array(preludePayload))))
        Darwin.close(harness.outputSlaveFD)
        Darwin.close(harness.inputWriteFD)
        Darwin.close(harness.inputReadFD)

        XCTAssertEqual(serverDone.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(reader.finish(), preludePayload)
    }

    func testClientHandlesControlAndPingWhileStreamingOutput() throws {
        let harness = try ClientHarness()
        let reader = OutputReader(masterFD: harness.outputMasterFD)
        reader.start()
        let controlBox = LockedStringBox()

        let serverDone = DispatchGroup()
        serverDone.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer {
                Darwin.close(harness.serverFD)
                serverDone.leave()
            }
            let textFrame = self.makeServerFrame(opcode: 0x01, payload: Array(#"{"type":"exit","code":7}"#.utf8))
            _ = Self.writeAll(fd: harness.serverFD, data: Data(textFrame))
            let pingPayload = Array("ping".utf8)
            let pingFrame = self.makeServerFrame(opcode: 0x09, payload: pingPayload)
            _ = Self.writeAll(fd: harness.serverFD, data: Data(pingFrame))
            let outputFrame = self.makeServerFrame(opcode: 0x02, payload: Array("status line\r\n".utf8))
            _ = Self.writeAll(fd: harness.serverFD, data: Data(outputFrame))

            var parser = WebSocketClientFrameParser()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while true {
                let n = Darwin.read(harness.serverFD, &buffer, buffer.count)
                if n > 0 {
                    parser.feed(Array(buffer[0..<n]))
                    while let frame = parser.nextFrame() {
                        if frame.opcode == 0x0A {
                            let closeFrame = self.makeServerFrame(opcode: 0x08, payload: [])
                            _ = Self.writeAll(fd: harness.serverFD, data: Data(closeFrame))
                            return
                        }
                    }
                } else if n == 0 || (n < 0 && errno != EINTR) {
                    return
                }
            }
        }

        harness.runClientOrFail { controlBox.set($0) }
        Darwin.close(harness.outputSlaveFD)
        Darwin.close(harness.inputWriteFD)
        Darwin.close(harness.inputReadFD)

        XCTAssertEqual(serverDone.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(controlBox.get(), #"{"type":"exit","code":7}"#)
        XCTAssertEqual(reader.finish(), Data("status line\r\n".utf8))
    }

    private func makeServerFrame(opcode: UInt8, payload: [UInt8]) -> [UInt8] {
        var frame = [UInt8]()
        frame.append(0x80 | opcode)
        if payload.count <= 125 {
            frame.append(UInt8(payload.count))
        } else if payload.count <= 0xFFFF {
            frame.append(126)
            frame.append(UInt8((payload.count >> 8) & 0xFF))
            frame.append(UInt8(payload.count & 0xFF))
        } else {
            frame.append(127)
            let len64 = UInt64(payload.count)
            for i in (0..<8).reversed() {
                frame.append(UInt8((len64 >> (i * 8)) & 0xFF))
            }
        }
        frame.append(contentsOf: payload)
        return frame
    }

    private func makeScreenLikePayload(lineCount: Int) -> Data {
        var data = Data()
        for index in 0..<lineCount {
            let leading = String(repeating: " ", count: (index % 11) * 3)
            let marker = index % 17 == 0 ? "\(index % 10)" : " "
            let line = "\(leading)\(marker)│ row \(index)  files \(index % 7) active  W:\(1000 + index)\r\n"
            data.append(contentsOf: line.utf8)
        }
        return data
    }

    private func makeInputPayload(byteCount: Int) -> Data {
        var data = Data(count: byteCount)
        data.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for index in 0..<byteCount {
                base[index] = UInt8((index * 31) & 0xFF)
            }
        }
        return data
    }

    private static func chunk(data: Data, sizes: [Int]) -> [Data] {
        var chunks: [Data] = []
        var offset = 0
        var index = 0
        while offset < data.count {
            let size = sizes[index % sizes.count]
            let end = min(offset + size, data.count)
            chunks.append(data.subdata(in: offset..<end))
            offset = end
            index += 1
        }
        return chunks
    }

    @discardableResult
    private static func writeAll(fd: Int32, data: Data) -> Bool {
        data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return true }
            var offset = 0
            while offset < bytes.count {
                let n = Darwin.write(fd, base + offset, bytes.count - offset)
                if n > 0 {
                    offset += n
                } else if n < 0 && errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
    }
}

private final class ClientHarness {
    let serverFD: Int32
    let clientFD: Int32
    let inputReadFD: Int32
    let inputWriteFD: Int32
    let outputMasterFD: Int32
    let outputSlaveFD: Int32

    init() throws {
        var socketFDs = [Int32](repeating: -1, count: 2)
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &socketFDs) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        serverFD = socketFDs[0]
        clientFD = socketFDs[1]

        var pipeFDs = [Int32](repeating: -1, count: 2)
        guard pipe(&pipeFDs) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        inputReadFD = pipeFDs[0]
        inputWriteFD = pipeFDs[1]

        let master = posix_openpt(O_RDWR | O_NOCTTY)
        guard master >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard grantpt(master) == 0, unlockpt(master) == 0, let slaveName = ptsname(master) else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let slave = Darwin.open(slaveName, O_RDWR | O_NOCTTY)
        guard slave >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var raw = termios()
        guard tcgetattr(slave, &raw) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        cfmakeraw(&raw)
        guard tcsetattr(slave, TCSAFLUSH, &raw) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        outputMasterFD = master
        outputSlaveFD = slave

        let flags = fcntl(clientFD, F_GETFL, 0)
        _ = fcntl(clientFD, F_SETFL, flags | O_NONBLOCK)
    }

    func runClientOrFail(
        prelude: Data = Data(),
        onControlMessage: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            WebSocketShellClient.run(
                configuration: .init(
                    socketFD: self.clientFD,
                    inputFD: self.inputReadFD,
                    outputFD: self.outputSlaveFD,
                    prelude: prelude,
                    installWindowResizeHandler: false,
                    installInterruptHandler: false,
                    onControlMessage: onControlMessage
                )
            )
            group.leave()
        }
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success, "client session timed out")
    }

    func setClientSendBuffer(bytes: Int32) {
        var value = bytes
        _ = withUnsafePointer(to: &value) {
            setsockopt(clientFD, SOL_SOCKET, SO_SNDBUF, $0, socklen_t(MemoryLayout<Int32>.size))
        }
    }
}

private final class OutputReader: @unchecked Sendable {
    private let masterFD: Int32
    private let box = LockedDataBox()
    private let group = DispatchGroup()

    init(masterFD: Int32) {
        self.masterFD = masterFD
    }

    func start() {
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            defer {
                Darwin.close(self.masterFD)
                self.group.leave()
            }
            var captured = Data()
            var buffer = [UInt8](repeating: 0, count: 8192)
            while true {
                let n = Darwin.read(self.masterFD, &buffer, buffer.count)
                if n > 0 {
                    captured.append(contentsOf: buffer[0..<n])
                } else if n == 0 {
                    self.box.set(captured)
                    return
                } else if errno == EINTR {
                    continue
                } else {
                    self.box.set(captured)
                    return
                }
            }
        }
    }

    func finish() -> Data {
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        return box.get()
    }
}

private final class LockedDataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func set(_ data: Data) {
        lock.lock()
        self.data = data
        lock.unlock()
    }

    func get() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

private final class LockedStringBox: @unchecked Sendable {
    private let lock = NSLock()
    private var string = ""

    func set(_ string: String) {
        lock.lock()
        self.string = string
        lock.unlock()
    }

    func get() -> String {
        lock.lock()
        defer { lock.unlock() }
        return string
    }
}
