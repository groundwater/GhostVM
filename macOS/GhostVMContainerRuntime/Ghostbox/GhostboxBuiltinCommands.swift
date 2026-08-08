import Containerization
import ContainerizationOCI
import ContainerizationOS
import Foundation
import GhostVMKit

struct GhostboxDNSCommands: GhostboxDomainHandler {
    let resource = "dns"

    func handle(
        method: GhostboxDirectMethod,
        parameters: [String: GhostboxJSONValue],
        session: GhostboxSession
    ) async throws -> GhostboxDirectValue {
        switch method.rawValue {
        case GhostboxDirectMethod.dnsCreate.rawValue:
            let decoded = try GhostboxParameters(
                parameters,
                allowed: ["name", "nameservers", "domain", "searchDomains", "options"]
            )
            let dns = DNS(
                nameservers: try decoded.optionalStringArray("nameservers") ?? DNS.defaultNameservers,
                domain: try decoded.optionalString("domain"),
                searchDomains: try decoded.optionalStringArray("searchDomains") ?? [],
                options: try decoded.optionalStringArray("options") ?? []
            )
            let reference = try session.register(
                kind: "dns",
                name: decoded.requiredString("name"),
                value: dns,
                equivalent: ghostboxDNSEqual
            )
            return .reference(reference)

        case GhostboxDirectMethod.dnsDefaultNameservers.rawValue:
            _ = try GhostboxParameters(parameters, allowed: [])
            return .strings(DNS.defaultNameservers)

        case GhostboxDirectMethod.dnsDelete.rawValue:
            let decoded = try GhostboxParameters(parameters, allowed: ["dns"])
            let reference = try decoded.requiredReference("dns", expectedKind: "dns")
            let dns: DNS = try session.value(for: reference, expectedKind: "dns")
            try session.unregister(reference, expectedKind: "dns", matching: dns)
            return .void

        case GhostboxDirectMethod.dnsValidate.rawValue,
             GhostboxDirectMethod.dnsResolvConf.rawValue,
             GhostboxDirectMethod.dnsNameservers.rawValue,
             GhostboxDirectMethod.dnsDomain.rawValue,
             GhostboxDirectMethod.dnsSearchDomains.rawValue,
             GhostboxDirectMethod.dnsOptions.rawValue:
            let decoded = try GhostboxParameters(parameters, allowed: ["reference"])
            let reference = try decoded.requiredReference("reference", expectedKind: "dns")
            let dns: DNS = try session.value(for: reference, expectedKind: "dns")
            switch method.rawValue {
            case GhostboxDirectMethod.dnsValidate.rawValue:
                try dns.validate()
                return .void
            case GhostboxDirectMethod.dnsResolvConf.rawValue:
                return .string(dns.resolvConf)
            case GhostboxDirectMethod.dnsNameservers.rawValue:
                return .strings(dns.nameservers)
            case GhostboxDirectMethod.dnsDomain.rawValue:
                return dns.domain.map(GhostboxDirectValue.string) ?? .null
            case GhostboxDirectMethod.dnsSearchDomains.rawValue:
                return .strings(dns.searchDomains)
            default:
                return .strings(dns.options)
            }

        default:
            throw unsupported(method)
        }
    }

    private func unsupported(_ method: GhostboxDirectMethod) -> DirectDispatchError {
        DirectDispatchError(.unsupported, "unsupported direct method '\(method.rawValue)'")
    }
}

func ghostboxDNSEqual(_ lhs: DNS, _ rhs: DNS) -> Bool {
    guard lhs.nameservers == rhs.nameservers else { return false }
    guard lhs.domain == rhs.domain else { return false }
    guard lhs.searchDomains == rhs.searchDomains else { return false }
    return lhs.options == rhs.options
}

struct GhostboxProcessConfigCommands: GhostboxDomainHandler {
    let resource = "processConfig"

    func handle(
        method: GhostboxDirectMethod,
        parameters: [String: GhostboxJSONValue],
        session: GhostboxSession
    ) async throws -> GhostboxDirectValue {
        switch method.rawValue {
        case "processConfig.defaultPath":
            _ = try GhostboxParameters(parameters, allowed: [])
            return .string(LinuxProcessConfiguration.defaultPath)
        case "processConfig.create":
            let decoded = try GhostboxParameters(
                parameters,
                allowed: [
                    "processConfig", "argument", "environment", "workingDirectory", "user", "rlimit",
                    "noNewPrivileges", "capabilities", "terminal", "stdin", "stdout", "stderr",
                ]
            )
            let rlimitReferences = try decoded.optionalReferences("rlimit", expectedKind: "rlimit") ?? []
            let rlimits: [LinuxRLimit] = try rlimitReferences.map {
                let record: GhostboxRLimitRecord = try session.value(for: $0, expectedKind: "rlimit")
                return record.value
            }
            let capabilitiesReference: String
            let capabilities: Containerization.LinuxCapabilities
            if let supplied = try decoded.optionalReference("capabilities", expectedKind: "capabilities") {
                capabilitiesReference = supplied
                capabilities = try session.value(for: supplied, expectedKind: "capabilities")
            } else {
                capabilitiesReference = try registerDefaultCapabilities(session: session)
                capabilities = .defaultOCICapabilities
            }
            let stdinReference = try decoded.optionalReference("stdin", expectedKind: "reader-stream")
            let stdin: (any ReaderStream)? = try stdinReference.map {
                try session.value(for: $0, expectedKind: "reader-stream", as: (any ReaderStream).self)
            }
            let stdoutReference = try decoded.optionalReference("stdout", expectedKind: "writer")
            let stdout: (any Writer)? = try stdoutReference.map {
                try session.value(for: $0, expectedKind: "writer", as: (any Writer).self)
            }
            let stderrReference = try decoded.optionalReference("stderr", expectedKind: "writer")
            let stderr: (any Writer)? = try stderrReference.map {
                try session.value(for: $0, expectedKind: "writer", as: (any Writer).self)
            }
            let user: ContainerizationOCI.User
            if let object = try decoded.optionalObject("user") {
                user = try ghostboxDecode(ContainerizationOCI.User.self, from: object, parameter: "user")
            } else {
                user = .init()
            }
            let configuration = LinuxProcessConfiguration(
                arguments: try decoded.requiredStringArray("argument"),
                environmentVariables: try decoded.optionalStringArray("environment")
                    ?? ["PATH=\(LinuxProcessConfiguration.defaultPath)"],
                workingDirectory: try decoded.optionalString("workingDirectory") ?? "/",
                user: user,
                rlimits: rlimits,
                noNewPrivileges: try decoded.optionalBool("noNewPrivileges") ?? false,
                capabilities: capabilities,
                terminal: try decoded.optionalBool("terminal") ?? false,
                stdin: stdin,
                stdout: stdout,
                stderr: stderr
            )
            return try register(
                configuration,
                references: GhostboxProcessReferences(
                    rlimits: rlimitReferences,
                    capabilities: capabilitiesReference,
                    stdin: stdinReference,
                    stdout: stdoutReference,
                    stderr: stderrReference
                ),
                name: decoded.requiredString("processConfig"),
                session: session
            )
        case "processConfig.fromImageConfig":
            let decoded = try GhostboxParameters(parameters, allowed: ["processConfig", "imageConfig"])
            let imageConfig = try ghostboxDecode(
                ImageConfig.self,
                from: decoded.requiredObject("imageConfig"),
                parameter: "imageConfig"
            )
            let capabilitiesReference = try registerDefaultCapabilities(session: session)
            return try register(
                LinuxProcessConfiguration(from: imageConfig),
                references: GhostboxProcessReferences(
                    rlimits: [],
                    capabilities: capabilitiesReference,
                    stdin: nil,
                    stdout: nil,
                    stderr: nil
                ),
                name: decoded.requiredString("processConfig"),
                session: session
            )
        case GhostboxDirectMethod.processConfigDelete.rawValue:
            let decoded = try GhostboxParameters(parameters, allowed: ["processConfig"])
            let reference = try decoded.requiredReference("processConfig", expectedKind: "process-config")
            let slot: GhostboxMutableSlot<GhostboxProcessConfigRecord> = try session.mutableValue(
                for: reference,
                expectedKind: "process-config"
            )
            try session.unregister(reference, expectedKind: "process-config", matching: slot)
            return .void
        case "processConfig.setTerminalIo":
            let decoded = try GhostboxParameters(parameters, allowed: ["processConfig", "terminal"])
            let reference = try decoded.requiredReference("processConfig", expectedKind: "process-config")
            let terminalReference = try decoded.requiredReference("terminal", expectedKind: "terminal")
            let endpoint: GhostboxProxyTerminal = try session.value(for: terminalReference, expectedKind: "terminal")
            let terminal = endpoint.child
            let name = ghostboxReferenceName(terminalReference)
            let aliases = try session.registerAliases(
                [(kind: "reader-stream", name: name), (kind: "writer", name: name)],
                value: terminal,
                equivalent: ghostboxTerminalEqual
            )
            let readerReference = aliases[0]
            let writerReference = aliases[1]
            try session.updateValue(for: reference, expectedKind: "process-config", as: GhostboxProcessConfigRecord.self) {
                $0.configuration.setTerminalIO(terminal: terminal)
                $0.references.stdin = readerReference
                $0.references.stdout = writerReference
            }
            return .void
        case "processConfig.arguments", "processConfig.environmentVariables", "processConfig.workingDirectory",
             "processConfig.user", "processConfig.rlimits", "processConfig.noNewPrivileges",
             "processConfig.capabilities", "processConfig.terminal", "processConfig.stdin",
             "processConfig.stdout", "processConfig.stderr":
            let decoded = try GhostboxParameters(parameters, allowed: ["processConfig"])
            let reference = try decoded.requiredReference("processConfig", expectedKind: "process-config")
            let record: GhostboxProcessConfigRecord = try session.valueSnapshot(
                for: reference,
                expectedKind: "process-config"
            )
            let configuration = record.configuration
            switch method.rawValue {
            case "processConfig.arguments": return .strings(configuration.arguments)
            case "processConfig.environmentVariables": return .strings(configuration.environmentVariables)
            case "processConfig.workingDirectory": return .string(configuration.workingDirectory)
            case "processConfig.user": return try ghostboxEncodedValue(configuration.user)
            case "processConfig.noNewPrivileges": return .boolean(configuration.noNewPrivileges)
            case "processConfig.terminal": return .boolean(configuration.terminal)
            default:
                let references = record.references
                switch method.rawValue {
                case "processConfig.rlimits": return .references(references.rlimits)
                case "processConfig.capabilities": return .reference(references.capabilities)
                case "processConfig.stdin": return references.stdin.map(GhostboxDirectValue.reference) ?? .null
                case "processConfig.stdout": return references.stdout.map(GhostboxDirectValue.reference) ?? .null
                default: return references.stderr.map(GhostboxDirectValue.reference) ?? .null
                }
            }
        default:
            throw ghostboxUnsupported(method)
        }
    }

    private func register(
        _ configuration: LinuxProcessConfiguration,
        references: GhostboxProcessReferences,
        name: String,
        session: GhostboxSession
    ) throws -> GhostboxDirectValue {
        let reference = try session.registerMutable(
            kind: "process-config",
            name: name,
            value: GhostboxProcessConfigRecord(configuration: configuration, references: references),
            equivalent: {
                ghostboxProcessConfigurationEqual($0.configuration, $1.configuration)
                    && $0.references == $1.references
            }
        )
        return .reference(reference)
    }

    private func registerDefaultCapabilities(session: GhostboxSession) throws -> String {
        try session.register(
            kind: "capabilities",
            name: "default-oci",
            value: Containerization.LinuxCapabilities.defaultOCICapabilities,
            equivalent: ghostboxCapabilitiesEqual
        )
    }
}

struct GhostboxContainerCommands: GhostboxDomainHandler {
    let resource = "container"

    func handle(
        method: GhostboxDirectMethod,
        parameters: [String: GhostboxJSONValue],
        session: GhostboxSession
    ) async throws -> GhostboxDirectValue {
        _ = try GhostboxParameters(parameters, allowed: [])
        switch method.rawValue {
        case "container.defaultMounts":
            let references = try LinuxContainer.defaultMounts().enumerated().map { index, mount in
                try session.register(
                    kind: "mount",
                    name: "container-default-\(index)",
                    value: mount,
                    equivalent: ghostboxMountEqual
                )
            }
            return .references(references)
        case "container.defaultOCIMounts":
            return .array(LinuxContainer.defaultOCIMounts().map(ghostboxMountValue))
        case GhostboxDirectMethod.containerDefaultMaskedPaths.rawValue:
            return .strings(LinuxContainer.defaultMaskedPaths())
        case GhostboxDirectMethod.containerDefaultReadonlyPaths.rawValue:
            return .strings(LinuxContainer.defaultReadonlyPaths())
        case GhostboxDirectMethod.containerDefaultCopyChunkSize.rawValue:
            return .integer(Int64(LinuxContainer.defaultCopyChunkSize))
        case GhostboxDirectMethod.containerMaxIDLength.rawValue:
            return .integer(Int64(LinuxContainer.maxIDLength))
        default:
            throw ghostboxUnsupported(method)
        }
    }
}

private func ghostboxTerminalEqual(_ lhs: Terminal, _ rhs: Terminal) -> Bool {
    lhs.handle === rhs.handle
}

private func ghostboxMountValue(_ mount: Containerization.Mount) -> GhostboxDirectValue {
    .object([
        "type": .string(mount.type),
        "source": .string(mount.source),
        "destination": .string(mount.destination),
        "options": .strings(mount.options),
    ])
}

protocol GhostboxIOAttachable: Sendable {
    var attachmentStream: GhostboxIOStream { get }
    func attach(fd: Int32) throws
    func closeProxy()
}

struct GhostboxIOCommands: GhostboxDomainHandler {
    let resource: String

    func handle(
        method: GhostboxDirectMethod,
        parameters: [String: GhostboxJSONValue],
        session: GhostboxSession
    ) async throws -> GhostboxDirectValue {
        switch method.rawValue {
        case GhostboxDirectMethod.readerStreamCreateProxy.rawValue:
            let decoded = try GhostboxParameters(parameters, allowed: ["readerStream"])
            let name = try decoded.requiredString("readerStream")
            let endpoint = try GhostboxProxyReaderStream()
            return .reference(try session.register(
                kind: "reader-stream", name: name, value: endpoint,
                equivalent: { $0 === $1 }, cleanupPriority: 100,
                cancel: { $0.closeProxy() },
                cleanup: { $0.closeProxy() }
            ))
        case GhostboxDirectMethod.writerCreateProxy.rawValue:
            let decoded = try GhostboxParameters(parameters, allowed: ["writer"])
            let name = try decoded.requiredString("writer")
            let endpoint = try GhostboxProxyWriter()
            return .reference(try session.register(
                kind: "writer", name: name, value: endpoint,
                equivalent: { $0 === $1 }, cleanupPriority: 100,
                cancel: { $0.closeProxy() },
                cleanup: { $0.closeProxy() }
            ))
        case GhostboxDirectMethod.terminalCreateProxy.rawValue:
            let decoded = try GhostboxParameters(parameters, allowed: ["terminal", "width", "height"])
            let name = try decoded.requiredString("terminal")
            let endpoint = try GhostboxProxyTerminal(
                width: decoded.requiredInteger("width", as: UInt16.self),
                height: decoded.requiredInteger("height", as: UInt16.self)
            )
            return .reference(try session.register(
                kind: "terminal", name: name, value: endpoint,
                equivalent: { $0 === $1 }, cleanupPriority: 100,
                cancel: { $0.closeProxy() },
                cleanup: { $0.closeProxy() }
            ))
        case GhostboxDirectMethod.readerStreamCloseProxy.rawValue:
            let decoded = try GhostboxParameters(parameters, allowed: ["readerStream"])
            let reference = try decoded.requiredReference("readerStream", expectedKind: "reader-stream")
            let endpoint: GhostboxProxyReaderStream = try session.value(
                for: reference,
                expectedKind: "reader-stream"
            )
            endpoint.closeProxy()
            try session.unregister(reference, expectedKind: "reader-stream", matching: endpoint)
            return .void
        case GhostboxDirectMethod.writerCloseProxy.rawValue:
            let decoded = try GhostboxParameters(parameters, allowed: ["writer"])
            let reference = try decoded.requiredReference("writer", expectedKind: "writer")
            let endpoint: GhostboxProxyWriter = try session.value(
                for: reference, expectedKind: "writer"
            )
            endpoint.closeProxy()
            try session.unregister(reference, expectedKind: "writer", matching: endpoint)
            return .void
        case GhostboxDirectMethod.terminalCloseProxy.rawValue:
            let decoded = try GhostboxParameters(parameters, allowed: ["terminal"])
            let reference = try decoded.requiredReference("terminal", expectedKind: "terminal")
            let endpoint: GhostboxProxyTerminal = try session.value(
                for: reference, expectedKind: "terminal"
            )
            endpoint.closeProxy()
            let name = ghostboxReferenceName(reference)
            try session.unregister(reference, expectedKind: "terminal", matching: endpoint)
            try session.unregister(
                GhostboxReference.canonical(kind: "reader-stream", name: name),
                expectedKind: "reader-stream",
                matching: endpoint.child
            )
            try session.unregister(
                GhostboxReference.canonical(kind: "writer", name: name),
                expectedKind: "writer",
                matching: endpoint.child
            )
            return .void
        case GhostboxDirectMethod.terminalWaitAttachedProxy.rawValue:
            let decoded = try GhostboxParameters(parameters, allowed: ["terminal"])
            let endpoint: GhostboxProxyTerminal = try session.value(
                for: decoded.requiredReference("terminal", expectedKind: "terminal"), expectedKind: "terminal"
            )
            try await endpoint.waitAttached()
            return .void
        default:
            throw ghostboxUnsupported(method)
        }
    }
}

func ghostboxIOAttachment(
    method: GhostboxDirectMethod,
    parameters: [String: GhostboxJSONValue],
    session: GhostboxSession
) throws -> any GhostboxIOAttachable {
    switch method.rawValue {
    case GhostboxDirectMethod.readerStreamAttachProxy.rawValue:
        let decoded = try GhostboxParameters(parameters, allowed: ["readerStream"])
        return try session.value(
            for: decoded.requiredReference("readerStream", expectedKind: "reader-stream"),
            expectedKind: "reader-stream",
            as: GhostboxProxyReaderStream.self
        )
    case GhostboxDirectMethod.writerAttachProxy.rawValue:
        let decoded = try GhostboxParameters(parameters, allowed: ["writer"])
        return try session.value(
            for: decoded.requiredReference("writer", expectedKind: "writer"),
            expectedKind: "writer",
            as: GhostboxProxyWriter.self
        )
    case GhostboxDirectMethod.terminalAttachProxy.rawValue:
        let decoded = try GhostboxParameters(parameters, allowed: ["terminal", "resizeTarget"])
        let endpoint: GhostboxProxyTerminal = try session.value(
            for: decoded.requiredReference("terminal", expectedKind: "terminal"),
            expectedKind: "terminal",
            as: GhostboxProxyTerminal.self
        )
        if let target = try decoded.optionalString("resizeTarget") {
            let relay: GhostboxTerminalResizeRelay
            if target.hasPrefix("@container/") {
                let record: GhostboxContainerRecord = try session.value(for: target, expectedKind: "container")
                relay = GhostboxTerminalResizeRelay(container: record.value)
            } else if target.hasPrefix("@process/") {
                let process: LinuxProcess = try session.value(for: target, expectedKind: "process")
                relay = GhostboxTerminalResizeRelay(process: process)
            } else {
                throw DirectDispatchError(.invalidArgument, "resizeTarget must be an @container/NAME or @process/NAME reference")
            }
            try endpoint.setResizeHandler { width, height in
                Task { await relay.resize(width: width, height: height) }
            }
            try endpoint.setExitWatcher {
                await relay.waitUntilExited()
            }
        }
        return endpoint
    default:
        throw ghostboxUnsupported(method)
    }
}

final class GhostboxProxyReaderStream: ReaderStream, GhostboxIOAttachable, @unchecked Sendable {
    let attachmentStream = GhostboxIOStream.input

    private let lock = NSLock()
    private let sourceHandle: FileHandle
    private var sourceFD: Int32
    private var producerFD: Int32
    private var attachedFD: Int32 = -1
    private var attachmentUsed = false
    private var producerFinished = false
    private var cancelled = false
    private var streamUsed = false

    init() throws {
        let pair = try ghostboxSocketPair()
        sourceFD = pair.0
        producerFD = pair.1
        sourceHandle = FileHandle(fileDescriptor: pair.0, closeOnDealloc: false)
    }

    func stream() -> AsyncStream<Data> {
        AsyncStream { continuation in
            let mayStart = lock.withLock {
                guard !streamUsed, !cancelled else { return false }
                streamUsed = true
                return true
            }
            guard mayStart else {
                continuation.finish()
                return
            }
            sourceHandle.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    continuation.finish()
                } else {
                    continuation.yield(data)
                }
            }
            continuation.onTermination = { [weak self] _ in
                self?.sourceHandle.readabilityHandler = nil
                self?.closeProxy()
            }
        }
    }

    func attach(fd: Int32) throws {
        try beginAttachment(fd: fd)
        defer { lock.withLock { attachedFD = -1 } }
        let reader = GhostboxRuntimeLineReader(fd: fd)
        while let line = try reader.readLine() {
            let frame = try GhostboxIOFrame.decode(line: line)
            switch frame.type {
            case .data where frame.stream == .input:
                guard let data = frame.data, ghostboxWriteAll(fd: producerDescriptor(), data) else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EPIPE)
                }
            case .eof where frame.stream == .input:
                finishInput()
                _ = ghostboxWriteAll(fd: fd, try GhostboxIOFrame.eof(.input).encodeLine())
                return
            default:
                throw DirectDispatchError(.invalidArgument, "unexpected frame for reader-stream attachment")
            }
        }
        finishInput()
    }

    func closeProxy() {
        let descriptor = lock.withLock { () -> Int32 in
            guard !cancelled else { return -1 }
            cancelled = true
            let attached = attachedFD
            _ = Darwin.shutdown(producerFD, SHUT_WR)
            return attached
        }
        if descriptor >= 0 { _ = Darwin.shutdown(descriptor, SHUT_RD) }
    }

    deinit {
        sourceHandle.readabilityHandler = nil
        Darwin.close(sourceFD)
        Darwin.close(producerFD)
    }

    private func beginAttachment(fd: Int32) throws {
        try lock.withLock {
            guard !attachmentUsed, !producerFinished, !cancelled else {
                throw DirectDispatchError(.failedPrecondition, "reader-stream proxy is already attached or closed")
            }
            attachmentUsed = true
            attachedFD = fd
        }
    }

    private func producerDescriptor() -> Int32 {
        lock.withLock { producerFinished || cancelled ? -1 : producerFD }
    }

    private func finishInput() {
        lock.withLock {
            guard !producerFinished, !cancelled else { return }
            producerFinished = true
            _ = Darwin.shutdown(producerFD, SHUT_WR)
        }
    }
}

final class GhostboxProxyWriter: Writer, GhostboxIOAttachable, @unchecked Sendable {
    let attachmentStream = GhostboxIOStream.output

    private let lock = NSLock()
    private let writeLock = NSLock()
    private var writerFD: Int32
    private var consumerFD: Int32
    private var attachmentUsed = false
    private var closed = false

    init() throws {
        let pair = try ghostboxSocketPair()
        writerFD = pair.0
        consumerFD = pair.1
    }

    func write(_ data: Data) throws {
        guard !data.isEmpty else { return }
        let descriptor = lock.withLock { closed ? -1 : writerFD }
        guard descriptor >= 0 else { throw POSIXError(.EPIPE) }
        try writeLock.withLock {
            guard ghostboxWriteAll(fd: descriptor, data) else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EPIPE)
            }
        }
    }

    func close() throws {
        closeProxy()
    }

    func attach(fd: Int32) throws {
        try lock.withLock {
            guard !attachmentUsed else {
                throw DirectDispatchError(.failedPrecondition, "writer proxy is already attached")
            }
            attachmentUsed = true
        }
        var buffer = [UInt8](repeating: 0, count: GhostboxDirectLimits.ioFrameDataBytes)
        while true {
            let count = Darwin.read(consumerFD, &buffer, buffer.count)
            if count > 0 {
                let frame = GhostboxIOFrame.data(Data(buffer[0..<count]), stream: .output)
                guard ghostboxWriteAll(fd: fd, try frame.encodeLine()) else {
                    _ = Darwin.shutdown(consumerFD, SHUT_RD)
                    return
                }
                continue
            }
            if count < 0, errno == EINTR { continue }
            if count < 0, errno != EBADF {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            _ = ghostboxWriteAll(fd: fd, try GhostboxIOFrame.eof(.output).encodeLine())
            return
        }
    }

    func closeProxy() {
        lock.withLock {
            guard !closed else { return }
            closed = true
            _ = Darwin.shutdown(writerFD, SHUT_WR)
        }
    }

    deinit {
        Darwin.close(writerFD)
        Darwin.close(consumerFD)
    }
}

final class GhostboxProxyTerminal: GhostboxIOAttachable, @unchecked Sendable {
    let attachmentStream = GhostboxIOStream.terminal
    let child: Terminal

    private let parent: Terminal
    private let cancellationReadFD: Int32
    private let cancellationWriteFD: Int32
    private let lock = NSLock()
    private let readiness = GhostboxAttachmentReadiness()
    private var attachmentUsed = false
    private var closed = false
    private var terminalsClosed = false
    private var resizeHandler: (@Sendable (UInt16, UInt16) -> Void)?
    private var exitWatcher: Task<Void, Never>?

    init(width: UInt16, height: UInt16) throws {
        guard width > 0, height > 0 else {
            throw DirectDispatchError(.invalidArgument, "terminal dimensions must be greater than zero")
        }
        let pair = try Terminal.create(initialSize: .init(width: width, height: height))
        let cancellation = try ghostboxSocketPair()
        parent = pair.parent
        child = pair.child
        cancellationReadFD = cancellation.0
        cancellationWriteFD = cancellation.1
        var attributes = termios()
        guard tcgetattr(child.handle.fileDescriptor, &attributes) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        cfmakeraw(&attributes)
        attributes.c_oflag |= tcflag_t(OPOST)
        guard tcsetattr(child.handle.fileDescriptor, TCSANOW, &attributes) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    func attach(fd: Int32) throws {
        try lock.withLock {
            guard !attachmentUsed, !closed else {
                throw DirectDispatchError(.failedPrecondition, "terminal proxy is already attached or closed")
            }
            attachmentUsed = true
        }

        let inputDone = DispatchGroup()
        let inputError = GhostboxAttachmentErrorBox()
        inputDone.enter()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            defer { inputDone.leave() }
            do {
                let reader = GhostboxRuntimeLineReader(fd: fd)
                var receivedEOF = false
                while let line = try reader.readLine() {
                    let frame = try GhostboxIOFrame.decode(line: line)
                    switch frame.type {
                    case .data where frame.stream == .terminal:
                        guard let data = frame.data,
                              ghostboxWriteAll(fd: parent.handle.fileDescriptor, data) else {
                            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EPIPE)
                        }
                    case .resize where frame.stream == .terminal:
                        try child.resize(width: frame.columns!, height: frame.rows!)
                        readiness.markReady()
                        lock.withLock { resizeHandler }?(frame.columns!, frame.rows!)
                    case .eof where frame.stream == .terminal:
                        receivedEOF = true
                        return
                    default:
                        throw DirectDispatchError(.invalidArgument, "unexpected frame for terminal attachment")
                    }
                }
                if !receivedEOF { closeProxy() }
            } catch {
                inputError.set(error)
                closeProxy()
            }
        }

        var buffer = [UInt8](repeating: 0, count: GhostboxDirectLimits.ioFrameDataBytes)
        outputLoop: while true {
            var descriptors = [
                pollfd(fd: parent.handle.fileDescriptor, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0),
                pollfd(fd: cancellationReadFD, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0),
            ]
            let status = Darwin.poll(&descriptors, nfds_t(descriptors.count), -1)
            if status < 0, errno == EINTR { continue }
            if status < 0 || descriptors[1].revents != 0 { break }
            if descriptors[0].revents == 0 { continue }
            while true {
                let count = Darwin.read(parent.handle.fileDescriptor, &buffer, buffer.count)
                if count > 0 {
                    let frame = GhostboxIOFrame.data(Data(buffer[0..<count]), stream: .terminal)
                    guard ghostboxWriteAll(fd: fd, try frame.encodeLine()) else { break outputLoop }
                }
                if count < 0, errno == EINTR { continue }
                if count <= 0 { break outputLoop }
                break
            }
        }

        if let error = inputError.value {
            _ = ghostboxWriteAll(fd: fd, try GhostboxIOFrame.error(error.localizedDescription).encodeLine())
        } else {
            _ = ghostboxWriteAll(fd: fd, try GhostboxIOFrame.eof(.terminal).encodeLine())
        }
        _ = Darwin.shutdown(fd, SHUT_RDWR)
        inputDone.wait()
        closeTerminalDescriptors()
    }

    func closeProxy() {
        let result = lock.withLock { () -> (closeImmediately: Bool, watcher: Task<Void, Never>?) in
            guard !closed else { return (false, nil) }
            closed = true
            let watcher = exitWatcher
            exitWatcher = nil
            return (!attachmentUsed, watcher)
        }
        result.watcher?.cancel()
        readiness.close()
        if result.closeImmediately {
            closeTerminalDescriptors()
        } else {
            _ = ghostboxWriteAll(fd: cancellationWriteFD, Data([1]))
        }
    }

    func waitAttached() async throws {
        try await readiness.wait()
    }

    func setResizeHandler(_ handler: @escaping @Sendable (UInt16, UInt16) -> Void) throws {
        try lock.withLock {
            guard !attachmentUsed, !closed else {
                throw DirectDispatchError(.failedPrecondition, "terminal proxy is already attached or closed")
            }
            resizeHandler = handler
        }
    }

    func setExitWatcher(_ waitUntilExited: @escaping @Sendable () async -> Void) throws {
        try lock.withLock {
            guard !attachmentUsed, !closed, exitWatcher == nil else {
                throw DirectDispatchError(.failedPrecondition, "terminal proxy lifecycle is already attached or closed")
            }
            exitWatcher = Task { [weak self] in
                await waitUntilExited()
                guard !Task.isCancelled else { return }
                self?.closeProxy()
            }
        }
    }

    deinit {
        closeProxy()
        closeTerminalDescriptors()
        Darwin.close(cancellationReadFD)
        Darwin.close(cancellationWriteFD)
    }

    private func closeTerminalDescriptors() {
        let shouldClose = lock.withLock {
            guard !terminalsClosed else { return false }
            terminalsClosed = true
            return true
        }
        if shouldClose {
            try? parent.close()
            try? child.close()
        }
    }
}

private actor GhostboxTerminalResizeRelay {
    private enum Target: Sendable {
        case container(LinuxContainer)
        case process(LinuxProcess)
    }

    private let target: Target

    init(container: LinuxContainer) {
        target = .container(container)
    }

    init(process: LinuxProcess) {
        target = .process(process)
    }

    func resize(width: UInt16, height: UInt16) async {
        let size = Terminal.Size(width: width, height: height)
        switch target {
        case .container(let container): try? await container.resize(to: size)
        case .process(let process): try? await process.resize(to: size)
        }
    }

    func waitUntilExited() async {
        switch target {
        case .container(let container):
            while !Task.isCancelled {
                do {
                    let statistics = try await container.statistics(categories: .process)
                    if statistics.process?.current == 0 { return }
                } catch {
                    // The attachment may be established before the container starts.
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        case .process(let process):
            while process.pid < 0, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard !Task.isCancelled else { return }
            _ = try? await process.wait()
        }
    }
}

private final class GhostboxAttachmentErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Error?

    var value: Error? { lock.withLock { stored } }
    func set(_ error: Error) { lock.withLock { stored = error } }
}

private final class GhostboxRuntimeLineReader {
    private let fd: Int32
    private var buffer = [UInt8]()

    init(fd: Int32) {
        self.fd = fd
        buffer.reserveCapacity(4096)
    }

    func readLine() throws -> Data? {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                guard newline <= GhostboxDirectLimits.ioFrameLineBytes else {
                    throw ContainerProtocolError.requestTooLarge(limit: GhostboxDirectLimits.ioFrameLineBytes)
                }
                let line = Data(buffer[..<newline])
                buffer.removeFirst(newline + 1)
                return line
            }
            guard buffer.count <= GhostboxDirectLimits.ioFrameLineBytes else {
                throw ContainerProtocolError.requestTooLarge(limit: GhostboxDirectLimits.ioFrameLineBytes)
            }
            let readSize = min(4096, GhostboxDirectLimits.ioFrameLineBytes - buffer.count + 1)
            var chunk = [UInt8](repeating: 0, count: readSize)
            let count = Darwin.read(fd, &chunk, chunk.count)
            if count > 0 {
                buffer.append(contentsOf: chunk[0..<count])
                continue
            }
            if count < 0, errno == EINTR { continue }
            if count < 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            guard !buffer.isEmpty else { return nil }
            defer { buffer.removeAll(keepingCapacity: true) }
            return Data(buffer)
        }
    }
}

private func ghostboxSocketPair() throws -> (Int32, Int32) {
    var descriptors = [Int32](repeating: -1, count: 2)
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    return (descriptors[0], descriptors[1])
}

@discardableResult
func ghostboxWriteAll(fd: Int32, _ data: Data) -> Bool {
    guard fd >= 0 else { return false }
    var offset = 0
    return data.withUnsafeBytes { bytes in
        while offset < bytes.count {
            let count = Darwin.write(fd, bytes.baseAddress! + offset, bytes.count - offset)
            if count > 0 {
                offset += count
            } else if count < 0, errno == EINTR {
                continue
            } else {
                return false
            }
        }
        return true
    }
}
