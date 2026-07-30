import XCTest
@testable import GhostVMKit

final class ContainerBridgeProtocolTests: XCTestCase {

    // MARK: - Request decoding

    func testDecodeValidRequest() throws {
        let line = Data(#"{"version":1,"operation":"run","image":"alpine","command":["echo","hello"]}"#.utf8)
        let request = try ContainerRunRequest.decode(line: line)
        XCTAssertEqual(request.version, 1)
        XCTAssertEqual(request.operation, "run")
        XCTAssertEqual(request.image, "alpine")
        XCTAssertEqual(request.command, ["echo", "hello"])
    }

    func testDecodeToleratesUnknownKeys() throws {
        let line = Data(#"{"version":1,"operation":"run","image":"alpine","command":[],"future":"field"}"#.utf8)
        let request = try ContainerRunRequest.decode(line: line)
        XCTAssertEqual(request.image, "alpine")
        XCTAssertEqual(request.command, [])
    }

    func testDecodeEmptyLineThrowsEmptyRequest() {
        XCTAssertThrowsError(try ContainerRunRequest.decode(line: Data())) { error in
            XCTAssertEqual(error as? ContainerProtocolError, .emptyRequest)
        }
    }

    func testDecodeInvalidJSONThrows() {
        let line = Data("not json".utf8)
        XCTAssertThrowsError(try ContainerRunRequest.decode(line: line)) { error in
            guard case .malformedRequest = (error as? ContainerProtocolError) else {
                return XCTFail("Expected malformedRequest, got \(error)")
            }
        }
    }

    func testDecodeMissingCommandThrows() {
        let line = Data(#"{"version":1,"operation":"run","image":"alpine"}"#.utf8)
        XCTAssertThrowsError(try ContainerRunRequest.decode(line: line)) { error in
            guard case .malformedRequest = (error as? ContainerProtocolError) else {
                return XCTFail("Expected malformedRequest, got \(error)")
            }
        }
    }

    func testDecodeWrongCommandTypeThrows() {
        let line = Data(#"{"version":1,"operation":"run","image":"alpine","command":"echo hi"}"#.utf8)
        XCTAssertThrowsError(try ContainerRunRequest.decode(line: line))
    }

    func testRequestEncodeRoundTrip() throws {
        let request = ContainerRunRequest(version: 1, operation: "run", image: "alpine", command: ["echo", "hello"])
        let line = try request.encodeLine()
        XCTAssertEqual(line.last, 0x0A)
        let decoded = try ContainerRunRequest.decode(line: Data(line.dropLast()))
        XCTAssertEqual(decoded, request)
    }

    // MARK: - Response encoding

    private func jsonObject(for response: ContainerResponse) throws -> [String: Any] {
        let line = try response.encodeLine()
        XCTAssertEqual(line.last, 0x0A, "Response line must end with a newline")
        let object = try JSONSerialization.jsonObject(with: Data(line.dropLast()))
        return try XCTUnwrap(object as? [String: Any])
    }

    func testStdoutResponseShape() throws {
        let payload = Data([0x00, 0xFF, 0x61]) // binary-safe via base64
        let json = try jsonObject(for: .stdout(payload))
        XCTAssertEqual(json["version"] as? Int, 1)
        XCTAssertEqual(json["type"] as? String, "stdout")
        XCTAssertEqual(json["data"] as? String, payload.base64EncodedString())
        XCTAssertNil(json["exitCode"])
        XCTAssertNil(json["message"])
    }

    func testStderrResponseShape() throws {
        let payload = Data("boom".utf8)
        let json = try jsonObject(for: .stderr(payload))
        XCTAssertEqual(json["type"] as? String, "stderr")
        XCTAssertEqual(json["data"] as? String, payload.base64EncodedString())
    }

    func testExitResponseShape() throws {
        let json = try jsonObject(for: .exit(137))
        XCTAssertEqual(json["version"] as? Int, 1)
        XCTAssertEqual(json["type"] as? String, "exit")
        XCTAssertEqual(json["exitCode"] as? Int32, 137)
        XCTAssertNil(json["data"])
        XCTAssertNil(json["message"])
    }

    func testErrorResponseShape() throws {
        let json = try jsonObject(for: .error("something failed"))
        XCTAssertEqual(json["version"] as? Int, 1)
        XCTAssertEqual(json["type"] as? String, "error")
        XCTAssertEqual(json["message"] as? String, "something failed")
        XCTAssertNil(json["data"])
        XCTAssertNil(json["exitCode"])
    }

    func testResponseRoundTrip() throws {
        let response = ContainerResponse.exit(0)
        let line = try response.encodeLine()
        let decoded = try JSONDecoder().decode(ContainerResponse.self, from: Data(line.dropLast()))
        XCTAssertEqual(decoded, response)
    }

    // MARK: - Constants

    func testConstants() {
        XCTAssertEqual(ContainerBridgeConstants.port, 5004)
        XCTAssertEqual(ContainerBridgeConstants.protocolVersion, 1)
        XCTAssertEqual(ContainerBridgeConstants.maxRequestLineBytes, 64 * 1024)
    }
}
