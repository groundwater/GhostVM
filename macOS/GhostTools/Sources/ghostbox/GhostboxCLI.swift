import Foundation

let ghostboxVersion = "0.1.0"

@main
struct GhostboxCLI {
    static func main() async {
        signal(SIGPIPE, SIG_IGN)

        let status: Int32
        switch parseArguments(Array(CommandLine.arguments.dropFirst())) {
        case .success(let options):
            status = await run(options)
        case .failure(let error):
            writeStderr((error.errorDescription ?? "error") + "\n")
            status = 125
        }
        exit(status)
    }

    static func run(_ options: CLIOptions) async -> Int32 {
        switch options.action {
        case .help(let topic):
            switch renderGhostboxHelp(topic) {
            case .success(let help):
                writeStdout(Data((help + "\n").utf8))
                return 0
            case .failure(let error):
                writeStderr((error.errorDescription ?? "invalid help topic") + "\n")
                return 125
            }
        case .version:
            writeStdout(Data("\(ghostboxVersion)\n".utf8))
            return 0
        case .direct(let invocation):
            return runDirect(invocation: invocation, port: kDefaultVsockPort)
        case .attach(let invocation, let stream):
            return runAttachment(invocation: invocation, expectedStream: stream, port: kDefaultVsockPort)
        case .forward(let container, let ports):
            return await runPortForwarding(container: container, ports: ports, port: kDefaultVsockPort)
        }
    }
}

func runDirect(invocation: GhostboxDirectInvocation, port: UInt32) -> Int32 {
    do {
        let value = try invokeDirect(invocation: invocation, port: port)
        guard writeStdout(try renderDirectValue(value)) else {
            writeStderr("ghostbox: failed to write direct result (errno \(errno))\n")
            return 125
        }
        return 0
    } catch let error as DirectInvocationError {
        writeStderr("ghostbox: \(error.errorDescription ?? "direct invocation failed")\n")
        return 125
    } catch {
        writeStderr("ghostbox: direct invocation failed: \(error)\n")
        return 125
    }
}

enum DirectInvocationError: Error, LocalizedError {
    case encode(Error)
    case connect(Error)
    case send(Int32)
    case response(String)
    case host(code: String, message: String)

    var errorDescription: String? {
        switch self {
        case .encode(let error): return "failed to encode direct request: \(error)"
        case .connect(let error): return "cannot connect to host: \(error)"
        case .send(let code): return "failed to send direct request (errno \(code))"
        case .response(let message): return "protocol error: \(message)"
        case .host(let code, let message): return "host error [\(code)]: \(message)"
        }
    }
}

func invokeDirect(invocation: GhostboxDirectInvocation, port: UInt32) throws -> GhostboxDirectValue {
    let request = GhostboxDirectRequest(invocation: invocation)
    let line: Data
    do {
        line = try encodeDirectRequestLine(request)
    } catch {
        throw DirectInvocationError.encode(error)
    }

    let fd: Int32
    do {
        fd = try vsockDialHost(port: port)
    } catch {
        throw DirectInvocationError.connect(error)
    }
    defer { Darwin.close(fd) }

    guard writeAll(fd: fd, line) else {
        throw DirectInvocationError.send(errno)
    }
    _ = Darwin.shutdown(fd, SHUT_WR)

    let responseData: Data
    do {
        let reader = LineReader(fd: fd, maxLineBytes: kMaxDirectResponseLineBytes)
        guard let response = try reader.readLine(), !response.isEmpty else {
            throw DirectInvocationError.response("connection closed before direct response")
        }
        responseData = response
    } catch {
        if let error = error as? DirectInvocationError { throw error }
        throw DirectInvocationError.response("failed to read direct response: \(error)")
    }

    switch decodeDirectResponse(responseData, requestID: request.id) {
    case .result(let value):
        return value
    case .error(let code, let message):
        throw DirectInvocationError.host(code: code, message: message)
    case .protocolError(let message):
        throw DirectInvocationError.response(message)
    }
}

func runPortForwarding(container: String, ports: [PublishedPort], port: UInt32) async -> Int32 {
    #if DEBUG
    let signalTestControl = ProcessInfo.processInfo.environment["GHOSTBOX_FORWARD_SIGNAL_TEST_CONTROL"] == "1"
    #endif

    let addressResult: Result<String, Error>
    #if DEBUG
    if signalTestControl {
        addressResult = .success("127.0.0.1")
    } else {
        addressResult = Result { try resolveContainerIPv4Address(container: container, port: port) }
    }
    #else
    addressResult = Result { try resolveContainerIPv4Address(container: container, port: port) }
    #endif

    let address: String
    switch addressResult {
    case .success(let resolvedAddress):
        address = resolvedAddress
    case .failure(let error as DirectInvocationError):
        writeStderr("ghostbox: cannot resolve container address: \(error.errorDescription ?? "unknown error")\n")
        return 125
    case .failure(let error):
        writeStderr("ghostbox: cannot resolve container address: \(error.localizedDescription)\n")
        return 125
    }

    var forwarders: [PublishedPortForwarder] = []
    do {
        for publication in ports {
            forwarders.append(try await PublishedPortForwarder(publication))
        }
    } catch {
        for forwarder in forwarders { await forwarder.stop() }
        writeStderr("ghostbox: cannot publish port: \(error.localizedDescription)\n")
        return 125
    }

    let runState = ForwardingRunState()
    let signalQueue = DispatchQueue(label: "org.ghostvm.ghostbox.forward-signals")
    let handledSignals = [SIGINT, SIGTERM, SIGHUP]
    let signals = handledSignals.map { signalNumber in
        let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: signalQueue)
        source.setEventHandler { runState.finish(status: 128 + signalNumber) }
        return source
    }
    for (signalNumber, source) in zip(handledSignals, signals) {
        signal(signalNumber, SIG_IGN)
        source.resume()
    }
    forwarders.forEach { forwarder in
        forwarder.start(targetAddress: address) { error in
            runState.finish(status: 125) {
                writeStderr("ghostbox: port forwarding stopped: \(error.localizedDescription)\n")
            }
        }
    }
    #if DEBUG
    if signalTestControl { writeStdout(Data("READY\n".utf8)) }
    #endif
    let status = await runState.wait()
    #if DEBUG
    if signalTestControl {
        writeStdout(Data("CLEANUP\n".utf8))
        _ = FileHandle.standardInput.readData(ofLength: 1)
    }
    #endif
    for forwarder in forwarders { await forwarder.stop() }
    #if DEBUG
    if signalTestControl {
        writeStdout(Data("STOPPED\n".utf8))
        _ = FileHandle.standardInput.readData(ofLength: 1)
    }
    #endif
    signals.forEach { $0.cancel() }
    // Keep these signals ignored until main exits; restoring SIG_DFL here would
    // let a repeated signal replace the selected exit status after cleanup.
    return status
}

private func resolveContainerIPv4Address(container: String, port: UInt32) throws -> String {
    let interfaces = try invokeDirect(
        invocation: .init(
            method: .init(rawValue: "container.interfaces"),
            parameters: ["container": .string(container)]
        ),
        port: port
    )
    guard case .references(let references) = interfaces.storage, !references.isEmpty else {
        throw DirectInvocationError.response("container has no network interface")
    }
    for interface in references {
        let addressValue = try invokeDirect(
            invocation: .init(
                method: .init(rawValue: "interface.ipv4Address"),
                parameters: ["interface": .string(interface)]
            ),
            port: port
        )
        if case .json(.string(let cidr)) = addressValue.storage, !cidr.isEmpty {
            return cidr.split(separator: "/", maxSplits: 1).first.map(String.init) ?? cidr
        }
    }
    throw DirectInvocationError.response("container interfaces have no IPv4 address")
}

private final class ForwardingRunState: @unchecked Sendable {
    private let lock = NSLock()
    private var status: Int32?
    private var continuation: CheckedContinuation<Int32, Never>?

    @discardableResult
    func finish(status: Int32, onFinish: () -> Void = {}) -> Bool {
        let (finished, continuation): (Bool, CheckedContinuation<Int32, Never>?) = lock.withLock {
            guard self.status == nil else { return (false, nil) }
            self.status = status
            defer { self.continuation = nil }
            return (true, self.continuation)
        }
        guard finished else { return false }
        continuation?.resume(returning: status)
        onFinish()
        return true
    }

    func wait() async -> Int32 {
        await withCheckedContinuation { continuation in
            let status = lock.withLock { () -> Int32? in
                if let status = self.status { return status }
                self.continuation = continuation
                return nil
            }
            if let status { continuation.resume(returning: status) }
        }
    }
}

func renderDirectValue(_ value: GhostboxDirectValue) throws -> Data {
    switch value.storage {
    case .json(let json):
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(RenderedJSON(json))
        data.append(0x0A)
        return data
    case .references(let values):
        guard !values.isEmpty else { return Data() }
        return Data((values.joined(separator: "\n") + "\n").utf8)
    case .bytes(let value):
        return value
    case .void:
        return Data()
    case .reference(let value):
        return Data((value + "\n").utf8)
    }
}

private struct RenderedJSON: Encodable {
    let value: GhostboxJSONValue

    init(_ value: GhostboxJSONValue) {
        self.value = value
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case .null:
            try container.encodeNil()
        case .boolean(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .integer(let value):
            try container.encode(value)
        case .unsignedInteger(let value):
            try container.encode(value)
        case .array(let values):
            try container.encode(values.map(RenderedJSON.init))
        case .object(let values):
            try container.encode(values.mapValues(RenderedJSON.init))
        }
    }
}

@discardableResult
func writeStdout(_ data: Data) -> Bool {
    writeAll(fd: STDOUT_FILENO, data)
}

@discardableResult
func writeStderr(_ data: Data) -> Bool {
    writeAll(fd: STDERR_FILENO, data)
}

@discardableResult
func writeStderr(_ string: String) -> Bool {
    writeStderr(Data(string.utf8))
}
