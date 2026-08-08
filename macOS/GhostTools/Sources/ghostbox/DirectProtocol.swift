import Foundation

let kMaxDirectRequestLineBytes = 64 * 1024
let kMaxDirectArgumentCount = 256
let kMaxDirectArgumentBytes = 16 * 1024
let kMaxDirectArgumentsBytes = 60 * 1024
let kMaxDirectBytePayloadBytes = 1024 * 1024
let kMaxDirectResponseLineBytes = 2 * 1024 * 1024
let kMaxIOFrameDataBytes = 64 * 1024
let kMaxIOFrameLineBytes = 128 * 1024

enum GhostboxDirectProtocolError: LocalizedError, Equatable {
    case requestTooLarge

    var errorDescription: String? {
        "direct request exceeds the \(kMaxDirectRequestLineBytes)-byte limit"
    }
}

struct GhostboxDirectMethod: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    static let dnsCreate = Self(rawValue: "dns.create")
    static let dnsDefaultNameservers = Self(rawValue: "dns.defaultNameservers")
    static let dnsValidate = Self(rawValue: "dns.validate")
    static let dnsResolvConf = Self(rawValue: "dns.resolvConf")
    static let dnsNameservers = Self(rawValue: "dns.nameservers")
    static let dnsDomain = Self(rawValue: "dns.domain")
    static let dnsSearchDomains = Self(rawValue: "dns.searchDomains")
    static let dnsOptions = Self(rawValue: "dns.options")
    static let dnsDelete = Self(rawValue: "dns.delete")
    static let processConfigDefaultPath = Self(rawValue: "processConfig.defaultPath")
    static let processConfigDelete = Self(rawValue: "processConfig.delete")
    static let networkDelete = Self(rawValue: "network.delete")
    static let managerClose = Self(rawValue: "manager.close")
    static let mountGuestShare = Self(rawValue: "mount.guestShare")
    static let mountDelete = Self(rawValue: "mount.delete")
    static let volumeCreate = Self(rawValue: "volume.create")
    static let volumeList = Self(rawValue: "volume.list")
    static let volumeInspect = Self(rawValue: "volume.inspect")
    static let volumeMount = Self(rawValue: "volume.mount")
    static let volumeDelete = Self(rawValue: "volume.delete")
    static let containerDefaultMaskedPaths = Self(rawValue: "container.defaultMaskedPaths")
    static let containerDefaultReadonlyPaths = Self(rawValue: "container.defaultReadonlyPaths")
    static let containerDefaultCopyChunkSize = Self(rawValue: "container.defaultCopyChunkSize")
    static let containerMaxIDLength = Self(rawValue: "container.maxIDLength")
    static let kernelDefault = Self(rawValue: "kernel.default")
    static let kernelInstallRecommended = Self(rawValue: "kernel.installRecommended")
    static let readerStreamCreateProxy = Self(rawValue: "readerStream.createProxy")
    static let readerStreamAttachProxy = Self(rawValue: "readerStream.attachProxy")
    static let readerStreamCloseProxy = Self(rawValue: "readerStream.closeProxy")
    static let writerCreateProxy = Self(rawValue: "writer.createProxy")
    static let writerAttachProxy = Self(rawValue: "writer.attachProxy")
    static let writerCloseProxy = Self(rawValue: "writer.closeProxy")
    static let terminalCreateProxy = Self(rawValue: "terminal.createProxy")
    static let terminalAttachProxy = Self(rawValue: "terminal.attachProxy")
    static let terminalWaitAttachedProxy = Self(rawValue: "terminal.waitAttachedProxy")
    static let terminalCloseProxy = Self(rawValue: "terminal.closeProxy")
}

enum GhostboxIOStream: String, Codable, Equatable, Sendable {
    case input
    case output
    case terminal
}

enum GhostboxIOFrameType: String, Codable, Equatable, Sendable {
    case data
    case eof
    case resize
    case error
}

struct GhostboxIOFrame: Codable, Equatable, Sendable {
    var version = kProtocolVersion
    var type: GhostboxIOFrameType
    var stream: GhostboxIOStream?
    var data: Data?
    var columns: UInt16?
    var rows: UInt16?
    var message: String?

    static func data(_ data: Data, stream: GhostboxIOStream) -> Self {
        Self(type: .data, stream: stream, data: data)
    }

    static func eof(_ stream: GhostboxIOStream) -> Self {
        Self(type: .eof, stream: stream)
    }

    static func resize(columns: UInt16, rows: UInt16) -> Self {
        Self(type: .resize, stream: .terminal, columns: columns, rows: rows)
    }

    static func error(_ message: String) -> Self {
        Self(type: .error, message: message)
    }

    func validate() throws {
        guard version == kProtocolVersion else {
            throw ParseError.invalidDirect("unsupported I/O frame version")
        }
        switch type {
        case .data:
            guard stream != nil, let data, !data.isEmpty, data.count <= kMaxIOFrameDataBytes,
                  columns == nil, rows == nil, message == nil else {
                throw ParseError.invalidDirect("malformed I/O data frame")
            }
        case .eof:
            guard stream != nil, data == nil, columns == nil, rows == nil, message == nil else {
                throw ParseError.invalidDirect("malformed I/O EOF frame")
            }
        case .resize:
            guard stream == .terminal, data == nil, message == nil,
                  let columns, columns > 0, let rows, rows > 0 else {
                throw ParseError.invalidDirect("malformed I/O resize frame")
            }
        case .error:
            guard stream == nil, data == nil, columns == nil, rows == nil,
                  let message, !message.isEmpty, message.utf8.count <= 4096 else {
                throw ParseError.invalidDirect("malformed I/O error frame")
            }
        }
    }

    static func decode(line: Data) throws -> Self {
        guard !line.isEmpty, line.count <= kMaxIOFrameLineBytes else {
            throw ParseError.invalidDirect("invalid I/O frame length")
        }
        let frame = try JSONDecoder().decode(Self.self, from: line)
        try frame.validate()
        return frame
    }

    func encodeLine() throws -> Data {
        try validate()
        var encoded = try JSONEncoder().encode(self)
        guard encoded.count <= kMaxIOFrameLineBytes else {
            throw ParseError.invalidDirect("I/O frame exceeds the line limit")
        }
        encoded.append(0x0A)
        return encoded
    }
}

indirect enum GhostboxJSONValue: Codable, Equatable, Sendable {
    case null
    case boolean(Bool)
    case string(String)
    case integer(Int64)
    case unsignedInteger(UInt64)
    case array([GhostboxJSONValue])
    case object([String: GhostboxJSONValue])

    private static let unsignedIntegerTag = "$uint64"

    init(from decoder: Decoder) throws {
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

        let container = try decoder.container(keyedBy: JSONCodingKey.self)
        if container.contains(JSONCodingKey(Self.unsignedIntegerTag)) {
            guard container.allKeys.count == 1 else {
                throw DecodingError.dataCorruptedError(
                    forKey: JSONCodingKey(Self.unsignedIntegerTag),
                    in: container,
                    debugDescription: "\(Self.unsignedIntegerTag) must be the only key in a tagged unsigned integer"
                )
            }
            let encoded = try container.decode(String.self, forKey: JSONCodingKey(Self.unsignedIntegerTag))
            guard isCanonicalUnsignedInteger(encoded), let value = UInt64(encoded) else {
                throw DecodingError.dataCorruptedError(
                    forKey: JSONCodingKey(Self.unsignedIntegerTag),
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

    func encode(to encoder: Encoder) throws {
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
            var container = encoder.container(keyedBy: JSONCodingKey.self)
            try container.encode(String(value), forKey: JSONCodingKey(Self.unsignedIntegerTag))
        case .array(let values):
            var container = encoder.unkeyedContainer()
            for value in values {
                try container.encode(value)
            }
        case .object(let values):
            var container = encoder.container(keyedBy: JSONCodingKey.self)
            for (key, value) in values {
                try container.encode(value, forKey: JSONCodingKey(key))
            }
        }
    }
}

private struct JSONCodingKey: CodingKey, Hashable {
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

private func isCanonicalUnsignedInteger(_ value: String) -> Bool {
    guard !value.isEmpty else { return false }
    if value == "0" { return true }
    guard value.first != "0" else { return false }
    return value.utf8.allSatisfy { (0x30...0x39).contains($0) }
}

struct GhostboxDirectInvocation: Equatable, Sendable {
    let method: GhostboxDirectMethod
    let parameters: [String: GhostboxJSONValue]
}

struct GhostboxDirectRequest: Codable, Equatable, Sendable {
    let version: Int
    let operation: String
    let id: String
    let method: GhostboxDirectMethod
    let parameters: [String: GhostboxJSONValue]

    init(id: String = UUID().uuidString.lowercased(), invocation: GhostboxDirectInvocation) {
        version = kProtocolVersion
        operation = "direct"
        self.id = id
        method = invocation.method
        parameters = invocation.parameters
    }
}

struct GhostboxDirectValue: Codable, Equatable, Sendable {
    enum Storage: Equatable, Sendable {
        case json(GhostboxJSONValue)
        case reference(String)
        case references([String])
        case bytes(Data)
        case void
    }

    let storage: Storage

    private init(storage: Storage) {
        self.storage = storage
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
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

    static var null: Self { Self(storage: .json(.null)) }
    static func boolean(_ value: Bool) -> Self { Self(storage: .json(.boolean(value))) }
    static func string(_ value: String) -> Self { Self(storage: .json(.string(value))) }
    static func integer(_ value: Int64) -> Self { Self(storage: .json(.integer(value))) }
    static func unsignedInteger(_ value: UInt64) -> Self { Self(storage: .json(.unsignedInteger(value))) }
    static func array(_ value: [GhostboxDirectValue]) -> Self {
        Self(storage: .json(.array(value.map(\.jsonRepresentation))))
    }
    static func object(_ value: [String: GhostboxDirectValue]) -> Self {
        Self(storage: .json(.object(value.mapValues(\.jsonRepresentation))))
    }
    static func strings(_ value: [String]) -> Self {
        Self(storage: .json(.array(value.map(GhostboxJSONValue.string))))
    }
    static func reference(_ value: String) -> Self { Self(storage: .reference(value)) }
    static func references(_ value: [String]) -> Self { Self(storage: .references(value)) }
    static func bytes(_ value: Data) -> Self { Self(storage: .bytes(value)) }
    static var void: Self { Self(storage: .void) }

    var jsonRepresentation: GhostboxJSONValue {
        switch storage {
        case .json(let value): return value
        case .reference(let value): return .string(value)
        case .references(let values): return .array(values.map(GhostboxJSONValue.string))
        case .bytes(let value): return .object(["$bytes": .string(value.base64EncodedString())])
        case .void: return .null
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .type)
        let requiresValue = kind != .null && kind != .void
        let rawContainer = try decoder.container(keyedBy: JSONCodingKey.self)
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
            guard isCanonicalUnsignedInteger(encoded), let value = UInt64(encoded) else {
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
            guard value.count <= kMaxDirectBytePayloadBytes else {
                throw DecodingError.dataCorruptedError(
                    forKey: .value,
                    in: container,
                    debugDescription: "byte payload exceeds the \(kMaxDirectBytePayloadBytes)-byte limit"
                )
            }
            storage = .bytes(value)
        case .void: storage = .void
        }
    }

    func encode(to encoder: Encoder) throws {
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
            guard value.count <= kMaxDirectBytePayloadBytes else {
                throw EncodingError.invalidValue(
                    value,
                    EncodingError.Context(codingPath: encoder.codingPath, debugDescription: "byte payload exceeds the \(kMaxDirectBytePayloadBytes)-byte limit")
                )
            }
            try container.encode(Kind.bytes, forKey: .type)
            try container.encode(value, forKey: .value)
        case .void:
            try container.encode(Kind.void, forKey: .type)
        }
    }
}

struct GhostboxDirectFailure: Codable, Equatable {
    let code: String
    let message: String
}

struct GhostboxDirectResponse: Codable, Equatable {
    let version: Int
    let id: String
    let result: GhostboxDirectValue?
    let error: GhostboxDirectFailure?
}

enum DecodedDirectResponse: Equatable {
    case result(GhostboxDirectValue)
    case error(code: String, message: String)
    case protocolError(String)
}

func encodeDirectRequestLine(_ request: GhostboxDirectRequest) throws -> Data {
    var data = try JSONEncoder().encode(request)
    guard data.count <= kMaxDirectRequestLineBytes else {
        throw GhostboxDirectProtocolError.requestTooLarge
    }
    data.append(0x0A)
    return data
}

func decodeDirectResponse(_ data: Data, requestID: String) -> DecodedDirectResponse {
    guard let response = try? JSONDecoder().decode(GhostboxDirectResponse.self, from: data) else {
        return .protocolError("malformed direct response")
    }
    guard response.version == kProtocolVersion else {
        return .protocolError("unsupported direct response version")
    }
    guard response.id == requestID else {
        return .protocolError("direct response ID does not match request")
    }
    switch (response.result, response.error) {
    case (.some(let result), .none):
        return .result(result)
    case (.none, .some(let error)) where !error.code.isEmpty && !error.message.isEmpty:
        return .error(code: error.code, message: error.message)
    default:
        return .protocolError("direct response must contain exactly one result or error")
    }
}
