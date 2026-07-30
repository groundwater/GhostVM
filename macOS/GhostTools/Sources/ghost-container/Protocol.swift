import Foundation

/// Wire-protocol version supported by this client.
let kProtocolVersion: Int = 1

/// Default vsock port for the host container bridge.
let kDefaultVsockPort: UInt32 = 5004

/// VMADDR_CID_HOST — well-known constant for dialing the host from a guest VM.
let VMADDR_CID_HOST: UInt32 = 2

/// AF_VSOCK socket family constant (40 on macOS).
let AF_VSOCK: Int32 = 40

// MARK: - Request

/// A single NDJSON request line sent to the host.
struct HostContainerRequest: Codable {
    let version: Int
    let operation: String
    let image: String
    let command: [String]
}

/// Build a request dictionary matching the exact wire format:
/// `{"version":1,"operation":"run","image":"alpine","command":["echo","hello"]}`
func makeRunRequest(image: String, command: [String]) -> HostContainerRequest {
    return HostContainerRequest(
        version: kProtocolVersion,
        operation: "run",
        image: image,
        command: command
    )
}

// MARK: - Response

/// A single NDJSON response line from the host.
struct HostContainerResponse: Codable {
    let version: Int?
    let type: String
    let data: String?
    let exitCode: Int32?
    let message: String?
}

/// Discrete decoded response for internal handling.
/// - `.protocolError`: distinct from `.error` (host-reported runtime error) — a
///   protocol error means the wire response was malformed, had an unknown type,
///   a wrong/missing version, or was missing a required field. It is never
///   decoded as success or silent empty output.
enum DecodedResponse {
    case stdout(Data)
    case stderr(Data)
    case exit(Int32)
    case error(String)
    case protocolError(String)
}

/// Decode a raw JSON line into a `DecodedResponse`.
///
/// Strict rules:
/// - `version` is **required** and must equal `kProtocolVersion`, otherwise `.protocolError`.
/// - `type` must be one of `stdout`, `stderr`, `exit`, `error`.
/// - `stdout`/`stderr` require `data` encoded as base64. An empty base64 string is
///   valid empty output. Missing or invalid data produces `.protocolError`.
/// - `exit` **requires** `exitCode`; missing/out-of-range → `.protocolError`.
/// - `error` **requires** a nonempty `message`; missing/empty → `.protocolError`.
/// - Malformed JSON, unknown type, or any other malformed field → `.protocolError`.
/// - `.protocolError` is never decoded as success or silent empty output.
func decodeResponse(_ json: Data) -> DecodedResponse {
    guard let resp = try? JSONDecoder().decode(HostContainerResponse.self, from: json) else {
        return .protocolError("malformed JSON response")
    }

    guard let v = resp.version, v == kProtocolVersion else {
        return .protocolError("unsupported or missing response version")
    }

    switch resp.type {
    case "stdout":
        return decodeOutputStream(resp.data, kind: "stdout")
    case "stderr":
        return decodeOutputStream(resp.data, kind: "stderr")
    case "exit":
        guard let code = resp.exitCode else {
            return .protocolError("exit response missing exitCode")
        }
        guard (0...255).contains(code) else {
            return .protocolError("exit response has out-of-range exitCode")
        }
        return .exit(code)
    case "error":
        guard let msg = resp.message, !msg.isEmpty else {
            return .protocolError("error response missing or empty message")
        }
        return .error(msg)
    default:
        return .protocolError("unknown response type '\(resp.type)'")
    }
}

/// Decode base64 stream data for `stdout`/`stderr`.
/// - Empty string → empty output (valid).
/// - Invalid base64 → `.protocolError` (never silent empty output).
private func decodeOutputStream(_ data: String?, kind: String) -> DecodedResponse {
    guard let s = data else {
        return .protocolError("\(kind) response missing data")
    }
    if s.isEmpty {
        return kind == "stdout" ? .stdout(Data()) : .stderr(Data())
    }
    guard let decoded = Data(base64Encoded: s) else {
        return .protocolError("\(kind) response has invalid base64 data")
    }
    return kind == "stdout" ? .stdout(decoded) : .stderr(decoded)
}
