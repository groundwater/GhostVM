import Containerization
import ContainerizationOCI
import ContainerizationOS
import Foundation
import GhostVMKit
import SystemPackage

struct GhostboxHostsEntryCommands: GhostboxDomainHandler {
    let resource = "hostsEntry"

    func handle(
        method: GhostboxDirectMethod,
        parameters: [String: GhostboxJSONValue],
        session: GhostboxSession
    ) async throws -> GhostboxDirectValue {
        switch method.rawValue {
        case "hostsEntry.create":
            let decoded = try GhostboxParameters(parameters, allowed: ["hostsEntry", "ipAddress", "hostname", "comment"])
            return try register(
                Hosts.Entry(
                    ipAddress: decoded.requiredString("ipAddress"),
                    hostnames: decoded.requiredStringArray("hostname"),
                    comment: try decoded.optionalString("comment")
                ),
                name: decoded.requiredString("hostsEntry"),
                session: session
            )
        case "hostsEntry.localhostIpv4", "hostsEntry.localhostIpv6", "hostsEntry.ipv6Localnet",
             "hostsEntry.ipv6Mcastprefix", "hostsEntry.ipv6Allnodes", "hostsEntry.ipv6Allrouters":
            let decoded = try GhostboxParameters(parameters, allowed: ["hostsEntry", "comment"])
            let comment = try decoded.optionalString("comment")
            let entry: Hosts.Entry
            switch method.rawValue {
            case "hostsEntry.localhostIpv4": entry = .localHostIPV4(comment: comment)
            case "hostsEntry.localhostIpv6": entry = .localHostIPV6(comment: comment)
            case "hostsEntry.ipv6Localnet": entry = .ipv6LocalNet(comment: comment)
            case "hostsEntry.ipv6Mcastprefix": entry = .ipv6MulticastPrefix(comment: comment)
            case "hostsEntry.ipv6Allnodes": entry = .ipv6AllNodes(comment: comment)
            default: entry = .ipv6AllRouters(comment: comment)
            }
            return try register(entry, name: decoded.requiredString("hostsEntry"), session: session)
        case "hostsEntry.rendered", "hostsEntry.ipAddress", "hostsEntry.hostnames", "hostsEntry.comment":
            let decoded = try GhostboxParameters(parameters, allowed: ["hostsEntry"])
            let reference = try decoded.requiredReference("hostsEntry", expectedKind: "hosts-entry")
            let entry: Hosts.Entry = try session.value(for: reference, expectedKind: "hosts-entry")
            switch method.rawValue {
            case "hostsEntry.rendered": return .string(entry.rendered)
            case "hostsEntry.ipAddress": return .string(entry.ipAddress)
            case "hostsEntry.hostnames": return .strings(entry.hostnames)
            default: return entry.comment.map(GhostboxDirectValue.string) ?? .null
            }
        default:
            throw ghostboxUnsupported(method)
        }
    }

    private func register(_ entry: Hosts.Entry, name: String, session: GhostboxSession) throws -> GhostboxDirectValue {
        let reference = try session.register(kind: "hosts-entry", name: name, value: entry, equivalent: ghostboxHostsEntryEqual)
        return .reference(reference)
    }
}

struct GhostboxHostsCommands: GhostboxDomainHandler {
    let resource = "hosts"

    func handle(
        method: GhostboxDirectMethod,
        parameters: [String: GhostboxJSONValue],
        session: GhostboxSession
    ) async throws -> GhostboxDirectValue {
        switch method.rawValue {
        case "hosts.create":
            let decoded = try GhostboxParameters(parameters, allowed: ["hosts", "entry", "comment"])
            let entryReferences = try decoded.optionalReferences("entry", expectedKind: "hosts-entry") ?? []
            let entries: [Hosts.Entry] = try entryReferences.map { try session.value(for: $0, expectedKind: "hosts-entry") }
            let record = GhostboxHostsRecord(
                value: Hosts(entries: entries, comment: try decoded.optionalString("comment")),
                entryReferences: entryReferences
            )
            return try register(record, name: decoded.requiredString("hosts"), session: session)
        case "hosts.default":
            _ = try GhostboxParameters(parameters, allowed: [])
            let entries = Hosts.default.entries
            let entryReferences = try entries.enumerated().map { index, entry in
                try session.register(
                    kind: "hosts-entry",
                    name: "default-\(index)",
                    value: entry,
                    equivalent: ghostboxHostsEntryEqual
                )
            }
            return try register(
                GhostboxHostsRecord(value: .default, entryReferences: entryReferences),
                name: "default",
                session: session
            )
        case "hosts.hostsFile", "hosts.entries", "hosts.comment":
            let decoded = try GhostboxParameters(parameters, allowed: ["hosts"])
            let reference = try decoded.requiredReference("hosts", expectedKind: "hosts")
            let record: GhostboxHostsRecord = try session.value(for: reference, expectedKind: "hosts")
            switch method.rawValue {
            case "hosts.hostsFile": return .string(record.value.hostsFile)
            case "hosts.entries": return .references(record.entryReferences)
            default: return record.value.comment.map(GhostboxDirectValue.string) ?? .null
            }
        default:
            throw ghostboxUnsupported(method)
        }
    }

    private func register(_ record: GhostboxHostsRecord, name: String, session: GhostboxSession) throws -> GhostboxDirectValue {
        let reference = try session.register(kind: "hosts", name: name, value: record, equivalent: ghostboxHostsRecordEqual)
        return .reference(reference)
    }
}

struct GhostboxSocketCommands: GhostboxDomainHandler {
    let resource = "socket"

    func handle(
        method: GhostboxDirectMethod,
        parameters: [String: GhostboxJSONValue],
        session: GhostboxSession
    ) async throws -> GhostboxDirectValue {
        switch method.rawValue {
        case "socket.create":
            let decoded = try GhostboxParameters(parameters, allowed: ["socket", "source", "destination", "permissions", "direction"])
            let direction: UnixSocketConfiguration.Direction
            switch try decoded.optionalString("direction") ?? "into" {
            case "into": direction = .into
            case "out-of": direction = .outOf
            case let value:
                throw DirectDispatchError(.invalidArgument, "invalid socket direction '\(value)'")
            }
            let socket = UnixSocketConfiguration(
                source: ghostboxFileURL(try decoded.requiredString("source")),
                destination: ghostboxFileURL(try decoded.requiredString("destination")),
                permissions: try ghostboxPermissions(parameters["permissions"]),
                direction: direction
            )
            let reference = try session.register(
                kind: "socket",
                name: decoded.requiredString("socket"),
                value: socket,
                equivalent: ghostboxSocketEqual
            )
            return .reference(reference)
        case "socket.id", "socket.source", "socket.destination", "socket.permissions", "socket.direction":
            let decoded = try GhostboxParameters(parameters, allowed: ["socket"])
            let reference = try decoded.requiredReference("socket", expectedKind: "socket")
            let socket: UnixSocketConfiguration = try session.value(for: reference, expectedKind: "socket")
            switch method.rawValue {
            case "socket.id": return .string(socket.id)
            case "socket.source": return .string(socket.source.path)
            case "socket.destination": return .string(socket.destination.path)
            case "socket.permissions":
                return socket.permissions.map { .unsignedInteger(UInt64($0.rawValue)) } ?? .null
            default: return .string(ghostboxDirectionString(socket.direction))
            }
        default:
            throw ghostboxUnsupported(method)
        }
    }
}

struct GhostboxRLimitKindCommands: GhostboxDomainHandler {
    let resource = "rlimitKind"

    func handle(
        method: GhostboxDirectMethod,
        parameters: [String: GhostboxJSONValue],
        session: GhostboxSession
    ) async throws -> GhostboxDirectValue {
        guard method.rawValue == "rlimitKind.create" else { throw ghostboxUnsupported(method) }
        let decoded = try GhostboxParameters(parameters, allowed: ["rlimitKind", "ociName"])
        let kind = try LinuxRLimit.Kind(decoded.requiredString("ociName"))
        let reference = try session.register(
            kind: "rlimit-kind",
            name: decoded.requiredString("rlimitKind"),
            value: kind,
            equivalent: ==
        )
        return .reference(reference)
    }
}

struct GhostboxRLimitCommands: GhostboxDomainHandler {
    let resource = "rlimit"

    func handle(
        method: GhostboxDirectMethod,
        parameters: [String: GhostboxJSONValue],
        session: GhostboxSession
    ) async throws -> GhostboxDirectValue {
        switch method.rawValue {
        case "rlimit.create", "rlimit.createEqual":
            let allowed: Set<String> = method.rawValue == "rlimit.create"
                ? ["rlimit", "kind", "hard", "soft"]
                : ["rlimit", "kind", "limit"]
            let decoded = try GhostboxParameters(parameters, allowed: allowed)
            let kindReference = try decoded.requiredReference("kind", expectedKind: "rlimit-kind")
            let kind: LinuxRLimit.Kind = try session.value(for: kindReference, expectedKind: "rlimit-kind")
            let value: LinuxRLimit
            if method.rawValue == "rlimit.create" {
                value = LinuxRLimit(
                    kind: kind,
                    hard: try decoded.requiredUInt64("hard"),
                    soft: try decoded.requiredUInt64("soft")
                )
            } else {
                value = LinuxRLimit(kind: kind, limit: try decoded.requiredUInt64("limit"))
            }
            let reference = try session.register(
                kind: "rlimit",
                name: decoded.requiredString("rlimit"),
                value: GhostboxRLimitRecord(value: value, kindReference: kindReference),
                equivalent: ==
            )
            return .reference(reference)
        case "rlimit.kind", "rlimit.hard", "rlimit.soft", "rlimit.toOCI":
            let decoded = try GhostboxParameters(parameters, allowed: ["rlimit"])
            let reference = try decoded.requiredReference("rlimit", expectedKind: "rlimit")
            let record: GhostboxRLimitRecord = try session.value(for: reference, expectedKind: "rlimit")
            switch method.rawValue {
            case "rlimit.kind": return .reference(record.kindReference)
            case "rlimit.hard": return .unsignedInteger(record.value.hard)
            case "rlimit.soft": return .unsignedInteger(record.value.soft)
            default: return try ghostboxEncodedValue(record.value.toOCI())
            }
        default:
            throw ghostboxUnsupported(method)
        }
    }
}

struct GhostboxCapabilitiesCommands: GhostboxDomainHandler {
    let resource = "capabilities"

    func handle(
        method: GhostboxDirectMethod,
        parameters: [String: GhostboxJSONValue],
        session: GhostboxSession
    ) async throws -> GhostboxDirectValue {
        switch method.rawValue {
        case "capabilities.create":
            let decoded = try GhostboxParameters(
                parameters,
                allowed: ["capabilities", "bounding", "effective", "inheritable", "permitted", "ambient"]
            )
            let capabilities = Containerization.LinuxCapabilities(
                bounding: try ghostboxCapabilities(decoded.optionalStringArray("bounding") ?? []),
                effective: try ghostboxCapabilities(decoded.optionalStringArray("effective") ?? []),
                inheritable: try ghostboxCapabilities(decoded.optionalStringArray("inheritable") ?? []),
                permitted: try ghostboxCapabilities(decoded.optionalStringArray("permitted") ?? []),
                ambient: try ghostboxCapabilities(decoded.optionalStringArray("ambient") ?? [])
            )
            return try register(capabilities, name: decoded.requiredString("capabilities"), session: session)
        case "capabilities.createUniform":
            let decoded = try GhostboxParameters(parameters, allowed: ["capabilities", "capability"])
            return try register(
                Containerization.LinuxCapabilities(
                    capabilities: try ghostboxCapabilities(decoded.requiredStringArray("capability"))
                ),
                name: decoded.requiredString("capabilities"),
                session: session
            )
        case "capabilities.all", "capabilities.defaultOCI":
            _ = try GhostboxParameters(parameters, allowed: [])
            let isAll = method.rawValue == "capabilities.all"
            return try register(
                isAll ? .allCapabilities : .defaultOCICapabilities,
                name: isAll ? "all" : "default-oci",
                session: session
            )
        case "capabilities.bounding", "capabilities.effective", "capabilities.inheritable",
             "capabilities.permitted", "capabilities.ambient", "capabilities.toOCI":
            let decoded = try GhostboxParameters(parameters, allowed: ["capabilities"])
            let reference = try decoded.requiredReference("capabilities", expectedKind: "capabilities")
            let capabilities: Containerization.LinuxCapabilities = try session.value(
                for: reference,
                expectedKind: "capabilities"
            )
            switch method.rawValue {
            case "capabilities.bounding": return .strings(capabilities.bounding.map(\.description))
            case "capabilities.effective": return .strings(capabilities.effective.map(\.description))
            case "capabilities.inheritable": return .strings(capabilities.inheritable.map(\.description))
            case "capabilities.permitted": return .strings(capabilities.permitted.map(\.description))
            case "capabilities.ambient": return .strings(capabilities.ambient.map(\.description))
            default: return try ghostboxEncodedValue(capabilities.toOCI())
            }
        default:
            throw ghostboxUnsupported(method)
        }
    }

    private func register(
        _ capabilities: Containerization.LinuxCapabilities,
        name: String,
        session: GhostboxSession
    ) throws -> GhostboxDirectValue {
        let reference = try session.register(
            kind: "capabilities",
            name: name,
            value: capabilities,
            equivalent: ghostboxCapabilitiesEqual
        )
        return .reference(reference)
    }
}

struct GhostboxContainerConfigCommands: GhostboxDomainHandler {
    let resource = "containerConfig"

    func handle(
        method: GhostboxDirectMethod,
        parameters: [String: GhostboxJSONValue],
        session: GhostboxSession
    ) async throws -> GhostboxDirectValue {
        switch method.rawValue {
        case "containerConfig.createDefault":
            let decoded = try GhostboxParameters(parameters, allowed: ["containerConfig"])
            return try register(.init(), name: decoded.requiredString("containerConfig"), session: session)
        case "containerConfig.create":
            let decoded = try GhostboxParameters(
                parameters,
                allowed: [
                    "containerConfig", "process", "cpus", "memory", "hostname", "sysctl", "interface", "socket", "mount",
                    "maskedPath", "readonlyPath", "dns", "hosts", "virtualization", "bootLog", "ociRuntimePath",
                    "useInit", "cpuOverhead", "memoryOverhead",
                ]
            )
            let processReference = try decoded.requiredReference("process", expectedKind: "process-config")
            let process = try ghostboxProcessConfiguration(processReference, session: session)
            let interfaceReferences = try decoded.optionalReferences("interface", expectedKind: "interface") ?? []
            let interfaces: [any Interface] = try interfaceReferences.map {
                try session.value(for: $0, expectedKind: "interface", as: (any Interface).self)
            }
            let socketReferences = try decoded.optionalReferences("socket", expectedKind: "socket") ?? []
            let sockets: [UnixSocketConfiguration] = try socketReferences.map {
                try session.value(for: $0, expectedKind: "socket")
            }
            let mountReferences = try decoded.optionalReferences("mount", expectedKind: "mount") ?? []
            let mounts: [Containerization.Mount] = try mountReferences.map {
                try session.value(for: $0, expectedKind: "mount")
            }
            let dns: DNS? = try decoded.optionalReference("dns", expectedKind: "dns").map {
                try session.value(for: $0, expectedKind: "dns")
            }
            let hosts: Hosts? = try decoded.optionalReference("hosts", expectedKind: "hosts").map {
                let record: GhostboxHostsRecord = try session.value(for: $0, expectedKind: "hosts")
                return record.value
            }
            let bootLog: BootLog? = try decoded.optionalReference("bootLog", expectedKind: "boot-log").map {
                try session.value(for: $0, expectedKind: "boot-log")
            }
            let config = LinuxContainer.Configuration(
                process: process,
                cpus: try decoded.optionalInt("cpus") ?? 4,
                memoryInBytes: try decoded.optionalUInt64("memory") ?? 1_073_741_824,
                hostname: try decoded.optionalString("hostname"),
                sysctl: try ghostboxSysctls(decoded.optionalStringArray("sysctl") ?? []),
                interfaces: interfaces,
                sockets: sockets,
                mounts: parameters["mount"] == nil ? LinuxContainer.defaultMounts() : mounts,
                maskedPaths: try decoded.optionalStringArray("maskedPath") ?? LinuxContainer.defaultMaskedPaths(),
                readonlyPaths: try decoded.optionalStringArray("readonlyPath") ?? LinuxContainer.defaultReadonlyPaths(),
                dns: dns,
                hosts: hosts,
                virtualization: try decoded.optionalBool("virtualization") ?? false,
                bootLog: bootLog,
                ociRuntimePath: try decoded.optionalString("ociRuntimePath"),
                useInit: try decoded.optionalBool("useInit") ?? false,
                cpuOverhead: try decoded.optionalInt("cpuOverhead") ?? 1,
                memoryOverhead: try decoded.optionalUInt64("memoryOverhead") ?? 134_217_728
            )
            return try register(config, name: decoded.requiredString("containerConfig"), session: session)
        default:
            throw ghostboxUnsupported(method)
        }
    }

    private func register(
        _ config: LinuxContainer.Configuration,
        name: String,
        session: GhostboxSession
    ) throws -> GhostboxDirectValue {
        let reference = try session.register(
            kind: "container-config",
            name: name,
            value: config,
            equivalent: ghostboxContainerConfigurationEqual
        )
        return .reference(reference)
    }
}

enum GhostboxConfigurationCommandHandlers {
    static let all: [any GhostboxDomainHandler] = [
        GhostboxHostsEntryCommands(),
        GhostboxHostsCommands(),
        GhostboxSocketCommands(),
        GhostboxRLimitKindCommands(),
        GhostboxRLimitCommands(),
        GhostboxCapabilitiesCommands(),
        GhostboxContainerConfigCommands(),
    ]
}

struct GhostboxHostsRecord: Sendable {
    let value: Hosts
    let entryReferences: [String]
}

struct GhostboxRLimitRecord: Sendable, Equatable {
    let value: LinuxRLimit
    let kindReference: String
}

struct GhostboxProcessReferences: Sendable, Equatable {
    var rlimits: [String]
    var capabilities: String
    var stdin: String?
    var stdout: String?
    var stderr: String?
}

struct GhostboxProcessConfigRecord: Sendable {
    var configuration: LinuxProcessConfiguration
    var references: GhostboxProcessReferences
}

func ghostboxProcessConfiguration(
    _ reference: String,
    session: GhostboxSession
) throws -> LinuxProcessConfiguration {
    let record: GhostboxProcessConfigRecord = try session.valueSnapshot(
        for: reference,
        expectedKind: "process-config"
    )
    return record.configuration
}

func ghostboxReferenceName(_ reference: String) -> String {
    String(reference.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).last ?? "")
}

func ghostboxDecode<Value: Decodable>(
    _ type: Value.Type,
    from object: [String: GhostboxJSONValue],
    parameter: String
) throws -> Value {
    do {
        return try JSONDecoder().decode(type, from: JSONEncoder().encode(GhostboxJSONValue.object(object)))
    } catch {
        throw DirectDispatchError(.invalidArgument, "parameter '\(parameter)' is not valid \(type): \(error.localizedDescription)")
    }
}

func ghostboxHostsEntryEqual(_ lhs: Hosts.Entry, _ rhs: Hosts.Entry) -> Bool {
    lhs.ipAddress == rhs.ipAddress && lhs.hostnames == rhs.hostnames && lhs.comment == rhs.comment
}

private func ghostboxHostsRecordEqual(_ lhs: GhostboxHostsRecord, _ rhs: GhostboxHostsRecord) -> Bool {
    lhs.entryReferences == rhs.entryReferences
        && lhs.value.comment == rhs.value.comment
        && lhs.value.entries.count == rhs.value.entries.count
        && zip(lhs.value.entries, rhs.value.entries).allSatisfy(ghostboxHostsEntryEqual)
}

private func ghostboxFileURL(_ value: String) -> URL {
    if let url = URL(string: value), url.isFileURL { return url }
    return URL(filePath: value)
}

private func ghostboxPermissions(_ value: GhostboxJSONValue?) throws -> FilePermissions? {
    guard let value else { return nil }
    let raw: UInt64?
    switch value {
    case .unsignedInteger(let value): raw = value
    case .integer(let value): raw = value >= 0 ? UInt64(value) : nil
    case .string(let value):
        let digits = value.hasPrefix("0o") ? String(value.dropFirst(2)) : value
        raw = UInt64(digits, radix: 8)
    default: raw = nil
    }
    guard let raw, raw <= 0o7777 else {
        throw DirectDispatchError(.invalidArgument, "parameter 'permissions' must be an octal file mode")
    }
    return FilePermissions(rawValue: numericCast(raw))
}

private func ghostboxDirectionString(_ direction: UnixSocketConfiguration.Direction) -> String {
    switch direction {
    case .into: return "into"
    case .outOf: return "out-of"
    }
}

private func ghostboxSocketEqual(_ lhs: UnixSocketConfiguration, _ rhs: UnixSocketConfiguration) -> Bool {
    lhs.source == rhs.source
        && lhs.destination == rhs.destination
        && lhs.permissions == rhs.permissions
        && ghostboxDirectionString(lhs.direction) == ghostboxDirectionString(rhs.direction)
}

private func ghostboxCapabilities(_ values: [String]) throws -> [CapabilityName] {
    try values.map(CapabilityName.init(rawValue:))
}

func ghostboxCapabilitiesEqual(
    _ lhs: Containerization.LinuxCapabilities,
    _ rhs: Containerization.LinuxCapabilities
) -> Bool {
    lhs.bounding == rhs.bounding
        && lhs.effective == rhs.effective
        && lhs.inheritable == rhs.inheritable
        && lhs.permitted == rhs.permitted
        && lhs.ambient == rhs.ambient
}

private func ghostboxSysctls(_ values: [String]) throws -> [String: String] {
    var result: [String: String] = [:]
    for value in values {
        guard let separator = value.firstIndex(of: "="), separator != value.startIndex else {
            throw DirectDispatchError(.invalidArgument, "sysctl '\(value)' must use KEY=VALUE syntax")
        }
        let key = String(value[..<separator])
        guard result[key] == nil else {
            throw DirectDispatchError(.invalidArgument, "duplicate sysctl '\(key)'")
        }
        result[key] = String(value[value.index(after: separator)...])
    }
    return result
}

func ghostboxMountEqual(_ lhs: Containerization.Mount, _ rhs: Containerization.Mount) -> Bool {
    lhs.type == rhs.type
        && lhs.source == rhs.source
        && lhs.destination == rhs.destination
        && lhs.options == rhs.options
        && ghostboxRuntimeOptionsEqual(lhs.runtimeOptions, rhs.runtimeOptions)
}

private func ghostboxRuntimeOptionsEqual(
    _ lhs: Containerization.Mount.RuntimeOptions,
    _ rhs: Containerization.Mount.RuntimeOptions
) -> Bool {
    switch (lhs, rhs) {
    case (.virtioblk(let lhs), .virtioblk(let rhs)),
         (.virtiofs(let lhs), .virtiofs(let rhs)),
         (.any(let lhs), .any(let rhs)):
        return lhs == rhs
    case (.shared, .shared):
        return true
    default:
        return false
    }
}

func ghostboxProcessConfigurationEqual(_ lhs: LinuxProcessConfiguration, _ rhs: LinuxProcessConfiguration) -> Bool {
    lhs.arguments == rhs.arguments
        && lhs.environmentVariables == rhs.environmentVariables
        && lhs.workingDirectory == rhs.workingDirectory
        && ghostboxUserEqual(lhs.user, rhs.user)
        && lhs.rlimits == rhs.rlimits
        && lhs.noNewPrivileges == rhs.noNewPrivileges
        && ghostboxCapabilitiesEqual(lhs.capabilities, rhs.capabilities)
        && lhs.terminal == rhs.terminal
        && (lhs.stdin == nil) == (rhs.stdin == nil)
        && (lhs.stdout == nil) == (rhs.stdout == nil)
        && (lhs.stderr == nil) == (rhs.stderr == nil)
}

private func ghostboxUserEqual(_ lhs: ContainerizationOCI.User, _ rhs: ContainerizationOCI.User) -> Bool {
    lhs.uid == rhs.uid
        && lhs.gid == rhs.gid
        && lhs.umask == rhs.umask
        && lhs.additionalGids == rhs.additionalGids
        && lhs.username == rhs.username
}

func ghostboxContainerConfigurationEqual(
    _ lhs: LinuxContainer.Configuration,
    _ rhs: LinuxContainer.Configuration
) -> Bool {
    ghostboxProcessConfigurationEqual(lhs.process, rhs.process)
        && lhs.cpus == rhs.cpus
        && lhs.memoryInBytes == rhs.memoryInBytes
        && lhs.hostname == rhs.hostname
        && lhs.sysctl == rhs.sysctl
        && lhs.interfaces.count == rhs.interfaces.count
        && lhs.sockets.count == rhs.sockets.count
        && zip(lhs.sockets, rhs.sockets).allSatisfy(ghostboxSocketEqual)
        && lhs.mounts.count == rhs.mounts.count
        && zip(lhs.mounts, rhs.mounts).allSatisfy(ghostboxMountEqual)
        && lhs.maskedPaths == rhs.maskedPaths
        && lhs.readonlyPaths == rhs.readonlyPaths
        && ghostboxOptionalDNSEqual(lhs.dns, rhs.dns)
        && ghostboxOptionalHostsEqual(lhs.hosts, rhs.hosts)
        && lhs.virtualization == rhs.virtualization
        && (lhs.bootLog == nil) == (rhs.bootLog == nil)
        && lhs.ociRuntimePath == rhs.ociRuntimePath
        && lhs.useInit == rhs.useInit
        && lhs.cpuOverhead == rhs.cpuOverhead
        && lhs.memoryOverhead == rhs.memoryOverhead
}

private func ghostboxOptionalDNSEqual(_ lhs: DNS?, _ rhs: DNS?) -> Bool {
    switch (lhs, rhs) {
    case (.some(let lhs), .some(let rhs)): return ghostboxDNSEqual(lhs, rhs)
    case (.none, .none): return true
    default: return false
    }
}

private func ghostboxOptionalHostsEqual(_ lhs: Hosts?, _ rhs: Hosts?) -> Bool {
    switch (lhs, rhs) {
    case (.some(let lhs), .some(let rhs)):
        return lhs.comment == rhs.comment
            && lhs.entries.count == rhs.entries.count
            && zip(lhs.entries, rhs.entries).allSatisfy(ghostboxHostsEntryEqual)
    case (.none, .none): return true
    default: return false
    }
}
