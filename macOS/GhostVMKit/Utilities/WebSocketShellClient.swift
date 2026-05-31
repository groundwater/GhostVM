import Foundation
import Dispatch
#if canImport(Darwin)
import Darwin
#endif

public struct WebSocketClientFrame {
    public let opcode: UInt8
    public let payload: [UInt8]

    public init(opcode: UInt8, payload: [UInt8]) {
        self.opcode = opcode
        self.payload = payload
    }
}

public struct WebSocketClientFrameParser {
    private static let maxPayloadBytes = 16 * 1024 * 1024
    private var buffer = [UInt8]()

    public init() {}

    public mutating func feed(_ data: [UInt8]) {
        buffer.append(contentsOf: data)
    }

    public mutating func nextFrame() -> WebSocketClientFrame? {
        guard buffer.count >= 2 else { return nil }

        let fin = (buffer[0] & 0x80) != 0
        let opcode = buffer[0] & 0x0F
        guard opcode != 0x00 else {
            buffer.removeAll()
            return WebSocketClientFrame(opcode: 0x08, payload: [])
        }
        guard fin else {
            buffer.removeAll()
            return WebSocketClientFrame(opcode: 0x08, payload: [])
        }
        let masked = (buffer[1] & 0x80) != 0
        var payloadLen = Int(buffer[1] & 0x7F)
        var offset = 2

        if payloadLen == 126 {
            guard buffer.count >= offset + 2 else { return nil }
            payloadLen = Int(buffer[offset]) << 8 | Int(buffer[offset + 1])
            offset += 2
        } else if payloadLen == 127 {
            guard buffer.count >= offset + 8 else { return nil }
            payloadLen = 0
            for i in 0..<8 {
                payloadLen = (payloadLen << 8) | Int(buffer[offset + i])
            }
            offset += 8
        }

        guard payloadLen >= 0 && payloadLen <= Self.maxPayloadBytes else {
            buffer.removeAll()
            return WebSocketClientFrame(opcode: 0x08, payload: [])
        }

        var maskKey = [UInt8]()
        if masked {
            guard buffer.count >= offset + 4 else { return nil }
            maskKey = Array(buffer[offset..<offset + 4])
            offset += 4
        }

        guard buffer.count >= offset + payloadLen else { return nil }
        var payload = Array(buffer[offset..<offset + payloadLen])
        if masked {
            for i in 0..<payload.count {
                payload[i] ^= maskKey[i % 4]
            }
        }

        buffer.removeFirst(offset + payloadLen)
        return WebSocketClientFrame(opcode: opcode, payload: payload)
    }
}

public enum WebSocketClientFrames {
    public static func makeMaskedFrame(opcode: UInt8, payload: [UInt8]) -> [UInt8] {
        var frame = [UInt8]()
        frame.append(0x80 | opcode)

        let len = payload.count
        if len < 126 {
            frame.append(0x80 | UInt8(len))
        } else if len < 65536 {
            frame.append(0x80 | 126)
            frame.append(UInt8((len >> 8) & 0xFF))
            frame.append(UInt8(len & 0xFF))
        } else {
            frame.append(0x80 | 127)
            for i in (0..<8).reversed() {
                frame.append(UInt8((len >> (i * 8)) & 0xFF))
            }
        }

        var maskKey = [UInt8](repeating: 0, count: 4)
        arc4random_buf(&maskKey, 4)
        frame.append(contentsOf: maskKey)
        for (i, byte) in payload.enumerated() {
            frame.append(byte ^ maskKey[i % 4])
        }
        return frame
    }
}

public enum WebSocketShellClient {
    public struct Configuration {
        public let socketFD: Int32
        public let inputFD: Int32
        public let outputFD: Int32
        public let prelude: Data
        public let installWindowResizeHandler: Bool
        public let installInterruptHandler: Bool
        public let onControlMessage: @Sendable (String) -> Void

        public init(
            socketFD: Int32,
            inputFD: Int32,
            outputFD: Int32,
            prelude: Data = Data(),
            installWindowResizeHandler: Bool = false,
            installInterruptHandler: Bool = false,
            onControlMessage: @escaping @Sendable (String) -> Void = { _ in }
        ) {
            self.socketFD = socketFD
            self.inputFD = inputFD
            self.outputFD = outputFD
            self.prelude = prelude
            self.installWindowResizeHandler = installWindowResizeHandler
            self.installInterruptHandler = installInterruptHandler
            self.onControlMessage = onControlMessage
        }
    }

    public static func run(configuration: Configuration) {
        let socketFD = configuration.socketFD
        let inputFD = configuration.inputFD
        let outputFD = configuration.outputFD

        let ioQueue = DispatchQueue(label: "ghostvm.websocket-shell-client.io")
        var wsParser = WebSocketClientFrameParser()
        if !configuration.prelude.isEmpty {
            wsParser.feed(Array(configuration.prelude))
        }
        var socketWriteBuffer = [UInt8]()
        var writeSourceResumed = false
        var hasShutdown = false
        var shouldShutdownAfterWriteDrain = false
        let exitGroup = DispatchGroup()
        exitGroup.enter()
        let cancellationGroup = DispatchGroup()

        let socketWriteSource = DispatchSource.makeWriteSource(fileDescriptor: socketFD, queue: ioQueue)
        cancellationGroup.enter()
        socketWriteSource.setCancelHandler {
            cancellationGroup.leave()
        }
        let inputSource = DispatchSource.makeReadSource(fileDescriptor: inputFD, queue: ioQueue)
        cancellationGroup.enter()
        inputSource.setCancelHandler {
            cancellationGroup.leave()
        }
        let socketReadSource = DispatchSource.makeReadSource(fileDescriptor: socketFD, queue: ioQueue)
        cancellationGroup.enter()
        socketReadSource.setCancelHandler {
            cancellationGroup.leave()
        }

        let winchSource: DispatchSourceSignal?
        if configuration.installWindowResizeHandler {
            signal(SIGWINCH, SIG_IGN)
            winchSource = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: ioQueue)
            cancellationGroup.enter()
            winchSource?.setCancelHandler {
                cancellationGroup.leave()
            }
        } else {
            winchSource = nil
        }

        let intSource: DispatchSourceSignal?
        if configuration.installInterruptHandler {
            signal(SIGINT, SIG_IGN)
            intSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: ioQueue)
            cancellationGroup.enter()
            intSource?.setCancelHandler {
                cancellationGroup.leave()
            }
        } else {
            intSource = nil
        }

        func enqueueWrite(_ bytes: [UInt8]) {
            socketWriteBuffer.append(contentsOf: bytes)
            if !writeSourceResumed {
                writeSourceResumed = true
                socketWriteSource.resume()
            }
        }

        func shutdown() {
            guard !hasShutdown else { return }
            hasShutdown = true
            if !inputSource.isCancelled {
                inputSource.cancel()
            }
            socketReadSource.cancel()
            if !writeSourceResumed {
                socketWriteSource.resume()
            }
            socketWriteSource.cancel()
            winchSource?.cancel()
            intSource?.cancel()
            exitGroup.leave()
        }

        func processBufferedFrames() {
            while let frame = wsParser.nextFrame() {
                switch frame.opcode {
                case 0x02:
                    frame.payload.withUnsafeBufferPointer { ptr in
                        guard let base = ptr.baseAddress, ptr.count > 0 else { return }
                        var off = 0
                        while off < ptr.count {
                            let n = Darwin.write(outputFD, base + off, ptr.count - off)
                            if n > 0 {
                                off += n
                            } else if n < 0 && errno == EINTR {
                                continue
                            } else {
                                shutdown()
                                return
                            }
                        }
                    }
                case 0x01:
                    if let text = String(bytes: frame.payload, encoding: .utf8) {
                        configuration.onControlMessage(text)
                    }
                case 0x08:
                    shutdown()
                case 0x09:
                    enqueueWrite(WebSocketClientFrames.makeMaskedFrame(opcode: 0x0A, payload: frame.payload))
                default:
                    break
                }
                if hasShutdown {
                    return
                }
            }
        }

        socketWriteSource.setEventHandler {
            guard !socketWriteBuffer.isEmpty else {
                writeSourceResumed = false
                socketWriteSource.suspend()
                return
            }
            let n = socketWriteBuffer.withUnsafeBufferPointer { ptr -> Int in
                guard let base = ptr.baseAddress else { return 0 }
                return Darwin.write(socketFD, base, ptr.count)
            }
            if n > 0 {
                socketWriteBuffer.removeFirst(n)
                if socketWriteBuffer.isEmpty {
                    if shouldShutdownAfterWriteDrain {
                        shutdown()
                        return
                    }
                    writeSourceResumed = false
                    socketWriteSource.suspend()
                }
            } else if n < 0 && errno != EAGAIN && errno != EINTR {
                shutdown()
            }
        }

        inputSource.setEventHandler {
            var buf = [UInt8](repeating: 0, count: 4096)
            let n = Darwin.read(inputFD, &buf, buf.count)
            if n > 0 {
                enqueueWrite(WebSocketClientFrames.makeMaskedFrame(opcode: 0x02, payload: Array(buf[0..<n])))
            } else if n == 0 {
                shouldShutdownAfterWriteDrain = true
                inputSource.cancel()
                if socketWriteBuffer.isEmpty {
                    shutdown()
                }
            } else if errno != EAGAIN && errno != EINTR {
                shutdown()
            }
        }

        socketReadSource.setEventHandler {
            var buf = [UInt8](repeating: 0, count: 16384)
            let n = Darwin.read(socketFD, &buf, buf.count)
            if n > 0 {
                wsParser.feed(Array(buf[0..<n]))
                processBufferedFrames()
            } else if n == 0 {
                shutdown()
            } else if errno != EAGAIN && errno != EINTR {
                shutdown()
            }
        }

        winchSource?.setEventHandler {
            var ws = winsize()
            _ = ioctl(outputFD, TIOCGWINSZ, &ws)
            if ws.ws_col > 0 && ws.ws_row > 0 {
                let json = "{\"type\":\"resize\",\"cols\":\(ws.ws_col),\"rows\":\(ws.ws_row)}"
                enqueueWrite(WebSocketClientFrames.makeMaskedFrame(opcode: 0x01, payload: Array(json.utf8)))
            }
        }

        intSource?.setEventHandler {
            enqueueWrite(WebSocketClientFrames.makeMaskedFrame(opcode: 0x02, payload: [3]))
        }

        inputSource.resume()
        socketReadSource.resume()
        winchSource?.resume()
        intSource?.resume()
        processBufferedFrames()

        exitGroup.wait()
        cancellationGroup.wait()
        ioQueue.sync {}
        Darwin.close(socketFD)
    }
}
