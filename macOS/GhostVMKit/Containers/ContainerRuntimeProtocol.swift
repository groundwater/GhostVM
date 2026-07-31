import Foundation

/// Version of the backend-neutral container runtime API.
public struct ContainerRuntimeVersion: Codable, Equatable, Sendable {
    public static let current = ContainerRuntimeVersion(major: 1, minor: 0)

    public var major: Int
    public var minor: Int

    public init(major: Int, minor: Int) {
        self.major = major
        self.minor = minor
    }

    public func isCompatible(with other: ContainerRuntimeVersion) -> Bool {
        major == other.major
    }
}

/// Extensible method name used by frontends and runtime backends.
public struct ContainerRuntimeMethod: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.rawValue = try container.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static let systemCapabilities = Self(rawValue: "system.capabilities")

    public static let imagePull = Self(rawValue: "image.pull")
    public static let imageList = Self(rawValue: "image.list")
    public static let imageInspect = Self(rawValue: "image.inspect")
    public static let imageDelete = Self(rawValue: "image.delete")
    public static let imageUnpack = Self(rawValue: "image.unpack")

    public static let filesystemCreate = Self(rawValue: "filesystem.create")
    public static let filesystemDelete = Self(rawValue: "filesystem.delete")

    public static let containerCreate = Self(rawValue: "container.create")
    public static let containerStart = Self(rawValue: "container.start")
    public static let containerStop = Self(rawValue: "container.stop")
    public static let containerKill = Self(rawValue: "container.kill")
    public static let containerWait = Self(rawValue: "container.wait")
    public static let containerResize = Self(rawValue: "container.resize")
    public static let containerState = Self(rawValue: "container.state")
    public static let containerList = Self(rawValue: "container.list")
    public static let containerDelete = Self(rawValue: "container.delete")
    public static let containerCopyIn = Self(rawValue: "container.copyIn")
    public static let containerCopyOut = Self(rawValue: "container.copyOut")
    public static let containerDial = Self(rawValue: "container.dial")

    public static let processCreate = Self(rawValue: "process.create")
    public static let processStart = Self(rawValue: "process.start")
    public static let processKill = Self(rawValue: "process.kill")
    public static let processWait = Self(rawValue: "process.wait")
    public static let processResize = Self(rawValue: "process.resize")
    public static let processDelete = Self(rawValue: "process.delete")

    public static let networkCreateInterface = Self(rawValue: "network.createInterface")
    public static let networkReleaseInterface = Self(rawValue: "network.releaseInterface")

    public static let buildCreate = Self(rawValue: "build.create")
}

/// Metadata decoded before selecting a method-specific parameter type.
public struct ContainerRuntimeRequestEnvelope: Codable, Equatable, Sendable {
    public var version: ContainerRuntimeVersion
    public var id: String
    public var method: ContainerRuntimeMethod

    public init(
        version: ContainerRuntimeVersion = .current,
        id: String = UUID().uuidString.lowercased(),
        method: ContainerRuntimeMethod
    ) {
        self.version = version
        self.id = id
        self.method = method
    }
}

public struct ContainerRuntimeRequest<Parameters: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    public var version: ContainerRuntimeVersion
    public var id: String
    public var method: ContainerRuntimeMethod
    public var parameters: Parameters

    public init(
        version: ContainerRuntimeVersion = .current,
        id: String = UUID().uuidString.lowercased(),
        method: ContainerRuntimeMethod,
        parameters: Parameters
    ) {
        self.version = version
        self.id = id
        self.method = method
        self.parameters = parameters
    }
}

public struct ContainerRuntimeEmpty: Codable, Equatable, Sendable {
    public init() {}
}

/// A directory exported by GhostTools and materialized as a host filesystem.
public struct ContainerRuntimeFilesystemCreateParameters: Codable, Equatable, Sendable {
    public var guestPath: String
    public var readOnly: Bool

    public init(guestPath: String, readOnly: Bool = true) {
        self.guestPath = guestPath
        self.readOnly = readOnly
    }
}

public struct ContainerRuntimeFilesystem: Codable, Equatable, Sendable {
    public var id: String

    public init(id: String) {
        self.id = id
    }
}

public struct ContainerRuntimeFilesystemDeleteParameters: Codable, Equatable, Sendable {
    public var id: String

    public init(id: String) {
        self.id = id
    }
}

/// Framework-shaped mount metadata. `source` is a host-owned filesystem ID,
/// never an outer-host path supplied by the guest.
public struct ContainerRuntimeMount: Codable, Equatable, Sendable {
    public var type: String
    public var source: String
    public var destination: String
    public var options: [String]
    public var runtimeOptions: [String]

    public init(
        type: String,
        source: String,
        destination: String,
        options: [String] = [],
        runtimeOptions: [String] = []
    ) {
        self.type = type
        self.source = source
        self.destination = destination
        self.options = options
        self.runtimeOptions = runtimeOptions
    }
}

public struct ContainerRuntimeErrorCode: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.rawValue = try container.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static let invalidArgument = Self(rawValue: "invalid_argument")
    public static let notFound = Self(rawValue: "not_found")
    public static let alreadyExists = Self(rawValue: "already_exists")
    public static let failedPrecondition = Self(rawValue: "failed_precondition")
    public static let unavailable = Self(rawValue: "unavailable")
    public static let unsupported = Self(rawValue: "unsupported")
    public static let permissionDenied = Self(rawValue: "permission_denied")
    public static let timeout = Self(rawValue: "timeout")
    public static let cancelled = Self(rawValue: "cancelled")
    public static let internalError = Self(rawValue: "internal")
}

public struct ContainerRuntimeFailure: Codable, Equatable, Sendable {
    public var code: ContainerRuntimeErrorCode
    public var message: String

    public init(code: ContainerRuntimeErrorCode, message: String) {
        self.code = code
        self.message = message
    }
}

public struct ContainerRuntimeCapabilities: Codable, Equatable, Sendable {
    public var version: ContainerRuntimeVersion
    public var methods: [ContainerRuntimeMethod]
    public var features: [String]

    public init(
        version: ContainerRuntimeVersion = .current,
        methods: [ContainerRuntimeMethod],
        features: [String] = []
    ) {
        self.version = version
        self.methods = methods
        self.features = features
    }
}
