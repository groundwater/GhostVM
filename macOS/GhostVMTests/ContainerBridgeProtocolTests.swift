import XCTest
@testable import GhostVMKit

final class ContainerBridgeProtocolTests: XCTestCase {
    func testGhostboxIOFramesRoundTrip() throws {
        let frames: [GhostboxIOFrame] = [
            .data(Data([0x00, 0x0A, 0xFF]), stream: .input),
            .data(Data("output".utf8), stream: .output),
            .eof(.terminal),
            .resize(columns: 120, rows: 40),
            .error("closed"),
        ]
        for frame in frames {
            var line = try frame.encodeLine()
            XCTAssertEqual(line.removeLast(), 0x0A)
            XCTAssertEqual(try GhostboxIOFrame.decode(line: line), frame)
        }
    }

    func testGhostboxIOFramesEnforceBounds() {
        XCTAssertThrowsError(try GhostboxIOFrame.data(
            Data(repeating: 0, count: GhostboxDirectLimits.ioFrameDataBytes + 1),
            stream: .input
        ).encodeLine())
        XCTAssertThrowsError(try GhostboxIOFrame.resize(columns: 0, rows: 24).encodeLine())
        XCTAssertThrowsError(try GhostboxIOFrame.decode(line: Data()))
    }
    func testMaximumGhostboxIOFrameFitsFrameLineLimit() throws {
        let frame = GhostboxIOFrame.data(
            Data(repeating: 0x5A, count: GhostboxDirectLimits.ioFrameDataBytes),
            stream: .terminal
        )
        let line = try frame.encodeLine()
        XCTAssertLessThanOrEqual(line.count - 1, GhostboxDirectLimits.ioFrameLineBytes)
        XCTAssertEqual(try GhostboxIOFrame.decode(line: Data(line.dropLast())), frame)
    }
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
        XCTAssertEqual(try JSONDecoder().decode(ContainerRuntimeMethod.self, from: JSONEncoder().encode(method)), method)
    }

    func testRuntimeCapabilitiesRoundTrip() throws {
        let capabilities = ContainerRuntimeCapabilities(
            methods: [.imagePull, .containerCreate, .containerStart],
            features: ["build.stream.v1"]
        )
        XCTAssertEqual(
            try JSONDecoder().decode(ContainerRuntimeCapabilities.self, from: JSONEncoder().encode(capabilities)),
            capabilities
        )
    }

    func testRuntimeFailureUsesStableCode() throws {
        let failure = ContainerRuntimeFailure(code: .notFound, message: "container missing")
        XCTAssertEqual(
            try JSONDecoder().decode(ContainerRuntimeFailure.self, from: JSONEncoder().encode(failure)),
            failure
        )
    }

    func testRuntimeFilesystemRequestAndMountRoundTrip() throws {
        let request = ContainerRuntimeRequest(
            id: "request-fs",
            method: .filesystemCreate,
            parameters: ContainerRuntimeFilesystemCreateParameters(guestPath: "/Users/guest/project", readOnly: true)
        )
        let mount = ContainerRuntimeMount(
            type: "virtiofs",
            source: "filesystem-1",
            destination: "/workspace",
            options: ["ro"]
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                ContainerRuntimeRequest<ContainerRuntimeFilesystemCreateParameters>.self,
                from: JSONEncoder().encode(request)
            ),
            request
        )
        XCTAssertEqual(try JSONDecoder().decode(ContainerRuntimeMount.self, from: JSONEncoder().encode(mount)), mount)
    }

    func testRuntimeBuildRequestCarriesMetadataNotContext() throws {
        let parameters = ContainerRuntimeBuildCreateParameters(
            tags: ["web:latest"],
            dockerfile: Data("FROM scratch\n".utf8),
            buildArguments: ["MODE=release"],
            target: "server"
        )
        let request = ContainerRuntimeRequest(method: .buildCreate, parameters: parameters)
        XCTAssertEqual(
            try JSONDecoder().decode(
                ContainerRuntimeRequest<ContainerRuntimeBuildCreateParameters>.self,
                from: JSONEncoder().encode(request)
            ),
            request
        )
    }

    func testGhostboxDirectRequestRoundTrip() throws {
        let request = GhostboxDirectRequest(
            id: "direct-1",
            method: .dnsCreate,
            parameters: [
                "name": .string("dev"),
                "nameservers": .array([.string("1.1.1.1")]),
            ]
        )
        let data = try JSONEncoder().encode(request)
        XCTAssertEqual(try GhostboxDirectRequest.decode(line: data), request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["operation"] as? String, "direct")
        XCTAssertEqual(object["method"] as? String, "dns.create")
    }

    func testGhostboxDirectResponseHasTypedResult() throws {
        let response = GhostboxDirectResponse.success(id: "direct-1", value: .strings(["1.1.1.1"]))
        XCTAssertEqual(
            try JSONDecoder().decode(GhostboxDirectResponse.self, from: JSONEncoder().encode(response)),
            response
        )
    }

    func testGhostboxDirectValueAccessors() {
        XCTAssertEqual(GhostboxDirectValue.reference("@container/web").referenceValue, "@container/web")
        XCTAssertEqual(GhostboxDirectValue.references(["@volume/data"]).referencesValue, ["@volume/data"])
        XCTAssertEqual(GhostboxDirectValue.string("running").jsonValue, .string("running"))
        XCTAssertNil(GhostboxDirectValue.void.jsonValue)
    }

    func testMaximumGhostboxByteResponseFitsResponseLineLimit() throws {
        let response = GhostboxDirectResponse.success(
            id: "direct-1",
            value: .bytes(Data(repeating: 0xA5, count: GhostboxDirectLimits.bytePayloadBytes))
        )
        let line = try response.encodeLine()
        XCTAssertLessThanOrEqual(line.count - 1, GhostboxDirectLimits.responseLineBytes)
        XCTAssertEqual(
            try JSONDecoder().decode(GhostboxDirectResponse.self, from: Data(line.dropLast())),
            response
        )
    }

    func testGhostboxDirectFailureUsesStableRuntimeError() throws {
        let response = GhostboxDirectResponse.failure(id: "direct-1", code: .notFound, message: "DNS object missing")
        let decoded = try JSONDecoder().decode(GhostboxDirectResponse.self, from: JSONEncoder().encode(response))
        XCTAssertEqual(decoded.error?.code, .notFound)
        XCTAssertNil(decoded.result)
    }

    func testDirectDecodeRejectsEmptyAndMalformedRequests() {
        XCTAssertThrowsError(try GhostboxDirectRequest.decode(line: Data())) { error in
            XCTAssertEqual(error as? ContainerProtocolError, .emptyRequest)
        }
        XCTAssertThrowsError(try GhostboxDirectRequest.decode(line: Data("not json".utf8))) { error in
            guard case .malformedRequest = error as? ContainerProtocolError else {
                return XCTFail("Expected malformed request")
            }
        }
    }

    func testBridgeConstantsDescribeDirectChannel() {
        XCTAssertEqual(ContainerBridgeConstants.port, 5004)
        XCTAssertEqual(ContainerBridgeConstants.protocolVersion, 5)
        XCTAssertEqual(ContainerBridgeConstants.maxRequestLineBytes, 64 * 1024)
        XCTAssertEqual(ContainerRuntimeXPCProtocol.version, 5)
        XCTAssertEqual(ContainerRuntimeXPCProtocol.Key.ipv4Subnet, "ipv4Subnet")
        XCTAssertEqual(ContainerRuntimeXPCProtocol.Key.volumeRoot, "volumeRoot")
        XCTAssertEqual(ContainerRuntimeXPCProtocol.Key.imageRoot, "imageRoot")
    }
}
