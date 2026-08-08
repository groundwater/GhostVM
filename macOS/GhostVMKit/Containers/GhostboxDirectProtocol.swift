import Foundation

public enum GhostboxDirectLimits {
    public static let bytePayloadBytes = 1024 * 1024
    public static let responseLineBytes = 2 * 1024 * 1024
    public static let ioFrameDataBytes = 64 * 1024
    public static let ioFrameLineBytes = 128 * 1024
}

public struct GhostboxDirectMethod: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let dnsCreate = Self(rawValue: "dns.create")
    public static let dnsDefaultNameservers = Self(rawValue: "dns.defaultNameservers")
    public static let dnsValidate = Self(rawValue: "dns.validate")
    public static let dnsResolvConf = Self(rawValue: "dns.resolvConf")
    public static let dnsNameservers = Self(rawValue: "dns.nameservers")
    public static let dnsDomain = Self(rawValue: "dns.domain")
    public static let dnsSearchDomains = Self(rawValue: "dns.searchDomains")
    public static let dnsOptions = Self(rawValue: "dns.options")
    public static let dnsDelete = Self(rawValue: "dns.delete")
    public static let processConfigDefaultPath = Self(rawValue: "processConfig.defaultPath")
    public static let processConfigDelete = Self(rawValue: "processConfig.delete")
    public static let networkDelete = Self(rawValue: "network.delete")
    public static let managerClose = Self(rawValue: "manager.close")
    public static let mountGuestShare = Self(rawValue: "mount.guestShare")
    public static let mountDelete = Self(rawValue: "mount.delete")
    public static let volumeCreate = Self(rawValue: "volume.create")
    public static let volumeList = Self(rawValue: "volume.list")
    public static let volumeInspect = Self(rawValue: "volume.inspect")
    public static let volumeMount = Self(rawValue: "volume.mount")
    public static let volumeDelete = Self(rawValue: "volume.delete")
    public static let containerDefaultMaskedPaths = Self(rawValue: "container.defaultMaskedPaths")
    public static let containerDefaultReadonlyPaths = Self(rawValue: "container.defaultReadonlyPaths")
    public static let containerDefaultCopyChunkSize = Self(rawValue: "container.defaultCopyChunkSize")
    public static let containerMaxIDLength = Self(rawValue: "container.maxIDLength")
    public static let kernelDefault = Self(rawValue: "kernel.default")
    public static let kernelInstallRecommended = Self(rawValue: "kernel.installRecommended")
    public static let readerStreamCreateProxy = Self(rawValue: "readerStream.createProxy")
    public static let readerStreamAttachProxy = Self(rawValue: "readerStream.attachProxy")
    public static let readerStreamCloseProxy = Self(rawValue: "readerStream.closeProxy")
    public static let writerCreateProxy = Self(rawValue: "writer.createProxy")
    public static let writerAttachProxy = Self(rawValue: "writer.attachProxy")
    public static let writerCloseProxy = Self(rawValue: "writer.closeProxy")
    public static let terminalCreateProxy = Self(rawValue: "terminal.createProxy")
    public static let terminalAttachProxy = Self(rawValue: "terminal.attachProxy")
    public static let terminalWaitAttachedProxy = Self(rawValue: "terminal.waitAttachedProxy")
    public static let terminalCloseProxy = Self(rawValue: "terminal.closeProxy")
}

public enum GhostboxIOStream: String, Codable, Equatable, Sendable {
    case input
    case output
    case terminal
}

public enum GhostboxIOFrameType: String, Codable, Equatable, Sendable {
    case data
    case eof
    case resize
    case error
}

public struct GhostboxIOFrame: Codable, Equatable, Sendable {
    public var version: Int
    public var type: GhostboxIOFrameType
    public var stream: GhostboxIOStream?
    public var data: Data?
    public var columns: UInt16?
    public var rows: UInt16?
    public var message: String?

    public init(
        version: Int = ContainerBridgeConstants.protocolVersion,
        type: GhostboxIOFrameType,
        stream: GhostboxIOStream? = nil,
        data: Data? = nil,
        columns: UInt16? = nil,
        rows: UInt16? = nil,
        message: String? = nil
    ) {
        self.version = version
        self.type = type
        self.stream = stream
        self.data = data
        self.columns = columns
        self.rows = rows
        self.message = message
    }

    public static func data(_ data: Data, stream: GhostboxIOStream) -> Self {
        Self(type: .data, stream: stream, data: data)
    }

    public static func eof(_ stream: GhostboxIOStream) -> Self {
        Self(type: .eof, stream: stream)
    }

    public static func resize(columns: UInt16, rows: UInt16) -> Self {
        Self(type: .resize, stream: .terminal, columns: columns, rows: rows)
    }

    public static func error(_ message: String) -> Self {
        Self(type: .error, message: message)
    }

    public func validate() throws {
        guard version == ContainerBridgeConstants.protocolVersion else {
            throw ContainerProtocolError.malformedRequest("unsupported I/O frame version")
        }
        switch type {
        case .data:
            guard let stream, let data, !data.isEmpty,
                  data.count <= GhostboxDirectLimits.ioFrameDataBytes,
                  columns == nil, rows == nil, message == nil else {
                throw ContainerProtocolError.malformedRequest("malformed I/O data frame")
            }
            _ = stream
        case .eof:
            guard stream != nil, data == nil, columns == nil, rows == nil, message == nil else {
                throw ContainerProtocolError.malformedRequest("malformed I/O EOF frame")
            }
        case .resize:
            guard stream == .terminal, data == nil, message == nil,
                  let columns, columns > 0, let rows, rows > 0 else {
                throw ContainerProtocolError.malformedRequest("malformed I/O resize frame")
            }
        case .error:
            guard stream == nil, data == nil, columns == nil, rows == nil,
                  let message, !message.isEmpty, message.utf8.count <= 4096 else {
                throw ContainerProtocolError.malformedRequest("malformed I/O error frame")
            }
        }
    }

    public static func decode(line: Data) throws -> Self {
        guard !line.isEmpty, line.count <= GhostboxDirectLimits.ioFrameLineBytes else {
            throw ContainerProtocolError.malformedRequest("invalid I/O frame length")
        }
        do {
            let frame = try JSONDecoder().decode(Self.self, from: line)
            try frame.validate()
            return frame
        } catch let error as ContainerProtocolError {
            throw error
        } catch {
            throw ContainerProtocolError.malformedRequest("invalid I/O frame: \(error)")
        }
    }

    public func encodeLine() throws -> Data {
        try validate()
        var encoded = try JSONEncoder().encode(self)
        guard encoded.count <= GhostboxDirectLimits.ioFrameLineBytes else {
            throw ContainerProtocolError.requestTooLarge(limit: GhostboxDirectLimits.ioFrameLineBytes)
        }
        encoded.append(0x0A)
        return encoded
    }
}

public indirect enum GhostboxJSONValue: Codable, Equatable, Sendable {
    case null
    case boolean(Bool)
    case string(String)
    case integer(Int64)
    case unsignedInteger(UInt64)
    case array([GhostboxJSONValue])
    case object([String: GhostboxJSONValue])

    private static let unsignedIntegerTag = "$uint64"

    public init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if single.decodeNil() {
            self = .null
            return
        }
        if let value = try? single.decode(Bool.self) {
            self = .boolean(value)
            return
        }
        if let value = try? single.decode(String.self) {
            self = .string(value)
            return
        }
        if let value = try? single.decode(Int64.self) {
            self = .integer(value)
            return
        }
        if let value = try? single.decode(UInt64.self) {
            self = .unsignedInteger(value)
            return
        }
        if var container = try? decoder.unkeyedContainer() {
            var values: [GhostboxJSONValue] = []
            while !container.isAtEnd {
                try values.append(container.decode(GhostboxJSONValue.self))
            }
            self = .array(values)
            return
        }

        let container = try decoder.container(keyedBy: GhostboxJSONCodingKey.self)
        if container.contains(GhostboxJSONCodingKey(Self.unsignedIntegerTag)) {
            guard container.allKeys.count == 1 else {
                throw DecodingError.dataCorruptedError(
                    forKey: GhostboxJSONCodingKey(Self.unsignedIntegerTag),
                    in: container,
                    debugDescription: "\(Self.unsignedIntegerTag) must be the only key in a tagged unsigned integer"
                )
            }
            let encoded = try container.decode(String.self, forKey: GhostboxJSONCodingKey(Self.unsignedIntegerTag))
            guard ghostboxIsCanonicalUnsignedInteger(encoded), let value = UInt64(encoded) else {
                throw DecodingError.dataCorruptedError(
                    forKey: GhostboxJSONCodingKey(Self.unsignedIntegerTag),
                    in: container,
                    debugDescription: "\(Self.unsignedIntegerTag) must contain a canonical UInt64 decimal string"
                )
            }
            self = .unsignedInteger(value)
            return
        }

        self = .object(try Dictionary(uniqueKeysWithValues: container.allKeys.map { key in
            (key.stringValue, try container.decode(GhostboxJSONValue.self, forKey: key))
        }))
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .null:
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        case .boolean(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .string(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .integer(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .unsignedInteger(let value):
            var container = encoder.container(keyedBy: GhostboxJSONCodingKey.self)
            try container.encode(String(value), forKey: GhostboxJSONCodingKey(Self.unsignedIntegerTag))
        case .array(let values):
            var container = encoder.unkeyedContainer()
            for value in values {
                try container.encode(value)
            }
        case .object(let values):
            var container = encoder.container(keyedBy: GhostboxJSONCodingKey.self)
            for (key, value) in values {
                try container.encode(value, forKey: GhostboxJSONCodingKey(key))
            }
        }
    }
}

private struct GhostboxJSONCodingKey: CodingKey, Hashable {
    let stringValue: String
    let intValue: Int? = nil

    init(_ stringValue: String) {
        self.stringValue = stringValue
    }

    init?(stringValue: String) {
        self.init(stringValue)
    }

    init?(intValue: Int) {
        return nil
    }
}

private func ghostboxIsCanonicalUnsignedInteger(_ value: String) -> Bool {
    guard !value.isEmpty else { return false }
    if value == "0" { return true }
    guard value.first != "0" else { return false }
    return value.utf8.allSatisfy { (0x30...0x39).contains($0) }
}

public struct GhostboxDirectRequest: Codable, Equatable, Sendable {
    public var version: Int
    public var operation: String
    public var id: String
    public var method: GhostboxDirectMethod
    public var parameters: [String: GhostboxJSONValue]

    public init(
        version: Int = ContainerBridgeConstants.protocolVersion,
        id: String = UUID().uuidString.lowercased(),
        method: GhostboxDirectMethod,
        parameters: [String: GhostboxJSONValue] = [:]
    ) {
        self.version = version
        self.operation = "direct"
        self.id = id
        self.method = method
        self.parameters = parameters
    }

    public static func decode(line: Data) throws -> GhostboxDirectRequest {
        guard !line.isEmpty else { throw ContainerProtocolError.emptyRequest }
        guard line.count <= ContainerBridgeConstants.maxRequestLineBytes else {
            throw ContainerProtocolError.requestTooLarge(limit: ContainerBridgeConstants.maxRequestLineBytes)
        }
        do {
            let request = try JSONDecoder().decode(GhostboxDirectRequest.self, from: line)
            try request.validate()
            return request
        } catch let error as ContainerProtocolError {
            throw error
        } catch {
            throw ContainerProtocolError.malformedRequest(String(describing: error))
        }
    }

    public func validate() throws {
        guard version == ContainerBridgeConstants.protocolVersion,
              operation == "direct",
              !id.isEmpty,
              !method.rawValue.isEmpty else {
            throw ContainerProtocolError.malformedRequest("invalid direct request envelope")
        }
    }
}

public struct GhostboxDirectRequestEnvelope: Codable, Equatable, Sendable {
    public var version: Int
    public var operation: String
    public var id: String
    public var method: GhostboxDirectMethod

    public init(version: Int, operation: String, id: String, method: GhostboxDirectMethod) {
        self.version = version
        self.operation = operation
        self.id = id
        self.method = method
    }
}

public struct GhostboxDirectValue: Codable, Equatable, Sendable {
    private enum Storage: Equatable, Sendable {
        case json(GhostboxJSONValue)
        case reference(String)
        case references([String])
        case bytes(Data)
        case void
    }

    private let storage: Storage

    private init(storage: Storage) {
        self.storage = storage
    }

    public var jsonValue: GhostboxJSONValue? {
        guard case .json(let value) = storage else { return nil }
        return value
    }

    public var referenceValue: String? {
        guard case .reference(let value) = storage else { return nil }
        return value
    }

    public var referencesValue: [String]? {
        guard case .references(let value) = storage else { return nil }
        return value
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case value
    }

    private enum Kind: String, Codable {
        case null
        case boolean
        case string
        case integer
        case unsignedInteger = "unsigned_integer"
        case array
        case object
        case reference
        case references
        case bytes
        case void
    }

    public static var null: Self { Self(storage: .json(.null)) }
    public static func boolean(_ value: Bool) -> Self { Self(storage: .json(.boolean(value))) }
    public static func string(_ value: String) -> Self { Self(storage: .json(.string(value))) }
    public static func integer(_ value: Int64) -> Self { Self(storage: .json(.integer(value))) }
    public static func unsignedInteger(_ value: UInt64) -> Self { Self(storage: .json(.unsignedInteger(value))) }
    public static func array(_ value: [GhostboxDirectValue]) -> Self {
        Self(storage: .json(.array(value.map(\.jsonRepresentation))))
    }
    public static func object(_ value: [String: GhostboxDirectValue]) -> Self {
        Self(storage: .json(.object(value.mapValues(\.jsonRepresentation))))
    }
    public static func strings(_ value: [String]) -> Self {
        Self(storage: .json(.array(value.map(GhostboxJSONValue.string))))
    }
    public static func reference(_ value: String) -> Self { Self(storage: .reference(value)) }
    public static func references(_ value: [String]) -> Self { Self(storage: .references(value)) }
    public static func bytes(_ value: Data) -> Self { Self(storage: .bytes(value)) }
    public static var void: Self { Self(storage: .void) }

    private var jsonRepresentation: GhostboxJSONValue {
        switch storage {
        case .json(let value): return value
        case .reference(let value): return .string(value)
        case .references(let values): return .array(values.map(GhostboxJSONValue.string))
        case .bytes(let value): return .object(["$bytes": .string(value.base64EncodedString())])
        case .void: return .null
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .type)
        let requiresValue = kind != .null && kind != .void
        let rawContainer = try decoder.container(keyedBy: GhostboxJSONCodingKey.self)
        let expectedKeys: Set<String> = requiresValue ? ["type", "value"] : ["type"]
        guard Set(rawContainer.allKeys.map(\.stringValue)) == expectedKeys else {
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "malformed tagged direct value"
            )
        }

        switch kind {
        case .null: storage = .json(.null)
        case .boolean: storage = .json(.boolean(try container.decode(Bool.self, forKey: .value)))
        case .string: storage = .json(.string(try container.decode(String.self, forKey: .value)))
        case .integer: storage = .json(.integer(try container.decode(Int64.self, forKey: .value)))
        case .unsignedInteger:
            let encoded = try container.decode(String.self, forKey: .value)
            guard ghostboxIsCanonicalUnsignedInteger(encoded), let value = UInt64(encoded) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .value,
                    in: container,
                    debugDescription: "unsigned_integer must contain a canonical UInt64 decimal string"
                )
            }
            storage = .json(.unsignedInteger(value))
        case .array: storage = .json(.array(try container.decode([GhostboxJSONValue].self, forKey: .value)))
        case .object: storage = .json(.object(try container.decode([String: GhostboxJSONValue].self, forKey: .value)))
        case .reference: storage = .reference(try container.decode(String.self, forKey: .value))
        case .references: storage = .references(try container.decode([String].self, forKey: .value))
        case .bytes:
            let value = try container.decode(Data.self, forKey: .value)
            guard value.count <= GhostboxDirectLimits.bytePayloadBytes else {
                throw DecodingError.dataCorruptedError(
                    forKey: .value,
                    in: container,
                    debugDescription: "byte payload exceeds the \(GhostboxDirectLimits.bytePayloadBytes)-byte limit"
                )
            }
            storage = .bytes(value)
        case .void: storage = .void
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch storage {
        case .json(.null):
            try container.encode(Kind.null, forKey: .type)
        case .json(.boolean(let value)):
            try container.encode(Kind.boolean, forKey: .type)
            try container.encode(value, forKey: .value)
        case .json(.string(let value)):
            try container.encode(Kind.string, forKey: .type)
            try container.encode(value, forKey: .value)
        case .json(.integer(let value)):
            try container.encode(Kind.integer, forKey: .type)
            try container.encode(value, forKey: .value)
        case .json(.unsignedInteger(let value)):
            try container.encode(Kind.unsignedInteger, forKey: .type)
            try container.encode(String(value), forKey: .value)
        case .json(.array(let value)):
            try container.encode(Kind.array, forKey: .type)
            try container.encode(value, forKey: .value)
        case .json(.object(let value)):
            try container.encode(Kind.object, forKey: .type)
            try container.encode(value, forKey: .value)
        case .reference(let value):
            try container.encode(Kind.reference, forKey: .type)
            try container.encode(value, forKey: .value)
        case .references(let value):
            try container.encode(Kind.references, forKey: .type)
            try container.encode(value, forKey: .value)
        case .bytes(let value):
            guard value.count <= GhostboxDirectLimits.bytePayloadBytes else {
                throw EncodingError.invalidValue(
                    value,
                    EncodingError.Context(codingPath: encoder.codingPath, debugDescription: "byte payload exceeds the \(GhostboxDirectLimits.bytePayloadBytes)-byte limit")
                )
            }
            try container.encode(Kind.bytes, forKey: .type)
            try container.encode(value, forKey: .value)
        case .void:
            try container.encode(Kind.void, forKey: .type)
        }
    }
}

public struct GhostboxDirectResponse: Codable, Equatable, Sendable {
    public var version: Int
    public var id: String
    public var result: GhostboxDirectValue?
    public var error: ContainerRuntimeFailure?

    public init(
        version: Int = ContainerBridgeConstants.protocolVersion,
        id: String,
        result: GhostboxDirectValue? = nil,
        error: ContainerRuntimeFailure? = nil
    ) {
        self.version = version
        self.id = id
        self.result = result
        self.error = error
    }

    public static func success(id: String, value: GhostboxDirectValue) -> GhostboxDirectResponse {
        GhostboxDirectResponse(id: id, result: value)
    }

    public static func failure(
        id: String,
        code: ContainerRuntimeErrorCode,
        message: String
    ) -> GhostboxDirectResponse {
        GhostboxDirectResponse(id: id, error: ContainerRuntimeFailure(code: code, message: message))
    }

    public func encodeLine() throws -> Data {
        var data = try JSONEncoder().encode(self)
        guard data.count <= GhostboxDirectLimits.responseLineBytes else {
            throw ContainerProtocolError.requestTooLarge(limit: GhostboxDirectLimits.responseLineBytes)
        }
        data.append(0x0A)
        return data
    }
}
