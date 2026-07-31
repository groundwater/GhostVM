import Foundation

/// Constants for the guest-initiated container control channel.
///
/// The host (GhostVMHelper) listens on this vsock port via VZVirtioSocketListener.
/// A guest CLI connects to VMADDR_CID_HOST on this port, sends one NDJSON request,
/// and receives one NDJSON response object per line.
public enum ContainerBridgeConstants {
    /// Vsock port the host listens on for guest-initiated container requests.
    /// Ports 5000-5003 are used by guest-side GhostTools listeners.
    public static let port: UInt32 = 5004

    /// Wire protocol version. Version 2 adds framed stdin and TTY resize events.
    public static let protocolVersion = 2
    public static let minimumProtocolVersion = 1

    /// Maximum accepted size of a single request line in bytes (before the newline).
    public static let maxRequestLineBytes = 64 * 1024
}

/// A single guest request: run an image with a command.
///
/// Wire format (one JSON object on one line):
/// {"version":2,"operation":"run","image":"alpine","command":["sh"],"stdin":true,"tty":true,"columns":120,"rows":40}
/// Version 1 carries raw stdin after the request line. Version 2 carries NDJSON
/// input frames so terminal resize events can share the same connection safely.
public struct ContainerRunRequest: Codable, Equatable, Sendable {
    public var version: Int
    public var operation: String
    public var image: String
    public var command: [String]
    public var stdin: Bool?
    public var tty: Bool?
    public var columns: UInt16?
    public var rows: UInt16?
    public var volumes: [ContainerRunVolume]?

    public init(
        version: Int,
        operation: String,
        image: String,
        command: [String],
        stdin: Bool? = nil,
        tty: Bool? = nil,
        columns: UInt16? = nil,
        rows: UInt16? = nil,
        volumes: [ContainerRunVolume]? = nil
    ) {
        self.version = version
        self.operation = operation
        self.image = image
        self.command = command
        self.stdin = stdin
        self.tty = tty
        self.columns = columns
        self.rows = rows
        self.volumes = volumes
    }

    /// Decodes one request line (without the trailing newline).
    public static func decode(line: Data) throws -> ContainerRunRequest {
        guard !line.isEmpty else { throw ContainerProtocolError.emptyRequest }
        do {
            return try JSONDecoder().decode(ContainerRunRequest.self, from: line)
        } catch {
            throw ContainerProtocolError.malformedRequest(String(describing: error))
        }
    }

    /// Encodes as one NDJSON line (JSON object + '\n').
    public func encodeLine() throws -> Data {
        var data = try JSONEncoder().encode(self)
        data.append(0x0A)
        return data
    }
}

public enum ContainerInputType: String, Codable, Sendable {
    case stdin
    case stdinClose
    case resize
}

/// A version 2 guest-to-host input frame.
public struct ContainerInputFrame: Codable, Equatable, Sendable {
    public var version: Int
    public var type: ContainerInputType
    public var data: String?
    public var columns: UInt16?
    public var rows: UInt16?

    public init(type: ContainerInputType, data: String? = nil, columns: UInt16? = nil, rows: UInt16? = nil) {
        self.version = ContainerBridgeConstants.protocolVersion
        self.type = type
        self.data = data
        self.columns = columns
        self.rows = rows
    }

    public static func stdin(_ chunk: Data) -> ContainerInputFrame {
        ContainerInputFrame(type: .stdin, data: chunk.base64EncodedString())
    }

    public static func resize(columns: UInt16, rows: UInt16) -> ContainerInputFrame {
        ContainerInputFrame(type: .resize, columns: columns, rows: rows)
    }

    public func encodeLine() throws -> Data {
        var data = try JSONEncoder().encode(self)
        data.append(0x0A)
        return data
    }

    public static func decode(line: Data) throws -> ContainerInputFrame {
        do {
            return try JSONDecoder().decode(ContainerInputFrame.self, from: line)
        } catch {
            throw ContainerProtocolError.malformedInputFrame(String(describing: error))
        }
    }
}

public struct ContainerRunVolume: Codable, Equatable, Sendable {
    public var guestPath: String
    public var destination: String
    public var readOnly: Bool

    public init(guestPath: String, destination: String, readOnly: Bool) {
        self.guestPath = guestPath
        self.destination = destination
        self.readOnly = readOnly
    }
}

public enum ContainerResponseType: String, Codable, Sendable {
    case stdout
    case stderr
    case exit
    case error
}

/// A single host response frame (one JSON object per line).
///
/// - stdout/stderr: "data" holds base64-encoded output bytes.
/// - exit: "exitCode" holds the exit status (128+signal when killed by a signal).
/// - error: "message" describes what failed (protocol, validation, or launch).
public struct ContainerResponse: Codable, Equatable, Sendable {
    public var version: Int
    public var type: ContainerResponseType
    public var data: String?
    public var exitCode: Int32?
    public var message: String?

    public init(version: Int = ContainerBridgeConstants.protocolVersion, type: ContainerResponseType, data: String? = nil, exitCode: Int32? = nil, message: String? = nil) {
        self.version = version
        self.type = type
        self.data = data
        self.exitCode = exitCode
        self.message = message
    }

    public static func stdout(_ chunk: Data, version: Int = ContainerBridgeConstants.protocolVersion) -> ContainerResponse {
        ContainerResponse(version: version, type: .stdout, data: chunk.base64EncodedString())
    }

    public static func stderr(_ chunk: Data, version: Int = ContainerBridgeConstants.protocolVersion) -> ContainerResponse {
        ContainerResponse(version: version, type: .stderr, data: chunk.base64EncodedString())
    }

    public static func exit(_ code: Int32, version: Int = ContainerBridgeConstants.protocolVersion) -> ContainerResponse {
        ContainerResponse(version: version, type: .exit, exitCode: code)
    }

    public static func error(_ message: String, version: Int = ContainerBridgeConstants.protocolVersion) -> ContainerResponse {
        ContainerResponse(version: version, type: .error, message: message)
    }

    /// Encodes as one NDJSON line (JSON object + '\n').
    public func encodeLine() throws -> Data {
        var data = try JSONEncoder().encode(self)
        data.append(0x0A)
        return data
    }
}

public enum ContainerProtocolError: Error, LocalizedError, Equatable {
    case emptyRequest
    case requestTooLarge(limit: Int)
    case malformedRequest(String)
    case malformedInputFrame(String)
    case connectionClosed

    public var errorDescription: String? {
        switch self {
        case .emptyRequest:
            return "Empty request: send one JSON line such as {\"version\":1,\"operation\":\"run\",\"image\":\"alpine\",\"command\":[\"echo\",\"hello\"]}."
        case .requestTooLarge(let limit):
            return "Request line exceeds the \(limit)-byte limit."
        case .malformedRequest(let detail):
            return "Malformed request JSON: \(detail)"
        case .malformedInputFrame(let detail):
            return "Malformed input frame JSON: \(detail)"
        case .connectionClosed:
            return "Connection closed by peer."
        }
    }
}
