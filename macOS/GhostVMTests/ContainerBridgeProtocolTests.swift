import XCTest
@testable import GhostVMKit

final class ContainerBridgeProtocolTests: XCTestCase {

    // MARK: - Runtime API

    func testRuntimeVersionsUseMajorCompatibility() {
        XCTAssertTrue(ContainerRuntimeVersion.current.isCompatible(with: .init(major: 1, minor: 9)))
        XCTAssertFalse(ContainerRuntimeVersion.current.isCompatible(with: .init(major: 2, minor: 0)))
    }

    func testRuntimeRequestEnvelopeRoundTrip() throws {
        let request = ContainerRuntimeRequest(
            id: "request-1",
            method: .containerCreate,
            parameters: ContainerRuntimeEmpty()
        )
        let encoded = try JSONEncoder().encode(request)
        let envelope = try JSONDecoder().decode(ContainerRuntimeRequestEnvelope.self, from: encoded)
        let decoded = try JSONDecoder().decode(ContainerRuntimeRequest<ContainerRuntimeEmpty>.self, from: encoded)

        XCTAssertEqual(decoded, request)
        XCTAssertEqual(envelope.version, .current)
        XCTAssertEqual(envelope.id, "request-1")
        XCTAssertEqual(envelope.method.rawValue, "container.create")
    }

    func testRuntimeMethodsAllowForwardCompatibleValues() throws {
        let method = ContainerRuntimeMethod(rawValue: "snapshot.prepare")
        let encoded = try JSONEncoder().encode(method)
        let decoded = try JSONDecoder().decode(ContainerRuntimeMethod.self, from: encoded)

        XCTAssertEqual(decoded, method)
        XCTAssertEqual(String(data: encoded, encoding: .utf8), #""snapshot.prepare""#)
    }

    func testRuntimeCapabilitiesRoundTrip() throws {
        let capabilities = ContainerRuntimeCapabilities(
            methods: [.imagePull, .containerCreate, .containerStart],
            features: ["build.stream.v1"]
        )
        let encoded = try JSONEncoder().encode(capabilities)
        let decoded = try JSONDecoder().decode(ContainerRuntimeCapabilities.self, from: encoded)

        XCTAssertEqual(decoded, capabilities)
    }

    func testRuntimeFailureUsesStableCode() throws {
        let failure = ContainerRuntimeFailure(code: .notFound, message: "container missing")
        let encoded = try JSONEncoder().encode(failure)
        let decoded = try JSONDecoder().decode(ContainerRuntimeFailure.self, from: encoded)

        XCTAssertEqual(decoded, failure)
        XCTAssertEqual(decoded.code.rawValue, "not_found")
    }

    func testRuntimeFilesystemRequestAndMountRoundTrip() throws {
        let request = ContainerRuntimeRequest(
            id: "request-fs",
            method: .filesystemCreate,
            parameters: ContainerRuntimeFilesystemCreateParameters(
                guestPath: "/Users/guest/project",
                readOnly: true
            )
        )
        let mount = ContainerRuntimeMount(
            type: "virtiofs",
            source: "filesystem-1",
            destination: "/workspace",
            options: ["ro"]
        )

        let requestData = try JSONEncoder().encode(request)
        let mountData = try JSONEncoder().encode(mount)

        XCTAssertEqual(
            try JSONDecoder().decode(
                ContainerRuntimeRequest<ContainerRuntimeFilesystemCreateParameters>.self,
                from: requestData
            ),
            request
        )
        XCTAssertEqual(try JSONDecoder().decode(ContainerRuntimeMount.self, from: mountData), mount)
        XCTAssertEqual(request.method, .filesystemCreate)
        XCTAssertEqual(mount.source, "filesystem-1")
    }

    // MARK: - Request decoding

    func testDecodeValidRequest() throws {
        let line = Data(#"{"version":1,"operation":"run","image":"alpine","command":["echo","hello"]}"#.utf8)
        let request = try ContainerRunRequest.decode(line: line)
        XCTAssertEqual(request.version, 1)
        XCTAssertEqual(request.operation, "run")
        XCTAssertEqual(request.image, "alpine")
        XCTAssertEqual(request.command, ["echo", "hello"])
        XCTAssertNil(request.stdin)
    }

    func testDecodeAttachedStdinRequest() throws {
        let line = Data(#"{"version":1,"operation":"run","image":"alpine","command":["cat"],"stdin":true}"#.utf8)
        let request = try ContainerRunRequest.decode(line: line)
        XCTAssertEqual(request.stdin, true)
    }

    func testDecodeVolumeRequest() throws {
        let line = Data(#"{"version":1,"operation":"run","image":"alpine","command":[],"volumes":[{"guestPath":"/data","destination":"/mnt/data","readOnly":true}]}"#.utf8)
        let request = try ContainerRunRequest.decode(line: line)
        XCTAssertEqual(
            request.volumes,
            [ContainerRunVolume(guestPath: "/data", destination: "/mnt/data", readOnly: true)]
        )
    }

    func testDecodeTTYRequest() throws {
        let line = Data(#"{"version":2,"operation":"run","image":"alpine","command":["/bin/sh"],"stdin":true,"tty":true,"columns":120,"rows":40}"#.utf8)
        let request = try ContainerRunRequest.decode(line: line)
        XCTAssertEqual(request.tty, true)
        XCTAssertEqual(request.columns, 120)
        XCTAssertEqual(request.rows, 40)
    }

    func testInputFrameRoundTrip() throws {
        let frame = ContainerInputFrame.resize(columns: 132, rows: 43)
        let line = try frame.encodeLine()
        XCTAssertEqual(line.last, 0x0A)
        XCTAssertEqual(try ContainerInputFrame.decode(line: Data(line.dropLast())), frame)
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
        let request = ContainerRunRequest(version: 1, operation: "run", image: "alpine", command: ["echo", "hello"], stdin: true)
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
        XCTAssertEqual(json["version"] as? Int, 2)
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
        XCTAssertEqual(json["version"] as? Int, 2)
        XCTAssertEqual(json["type"] as? String, "exit")
        XCTAssertEqual(json["exitCode"] as? Int32, 137)
        XCTAssertNil(json["data"])
        XCTAssertNil(json["message"])
    }

    func testErrorResponseShape() throws {
        let json = try jsonObject(for: .error("something failed"))
        XCTAssertEqual(json["version"] as? Int, 2)
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
        XCTAssertEqual(ContainerBridgeConstants.protocolVersion, 2)
        XCTAssertEqual(ContainerBridgeConstants.minimumProtocolVersion, 1)
        XCTAssertEqual(ContainerBridgeConstants.maxRequestLineBytes, 64 * 1024)
    }
}
