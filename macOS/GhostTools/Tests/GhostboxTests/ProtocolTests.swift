@testable import ghostbox
import XCTest

final class ProtocolTests: XCTestCase {
    func testIOFramesRoundTrip() throws {
        let frames: [GhostboxIOFrame] = [
            .data(Data([0x00, 0x0A, 0xFF]), stream: .input),
            .data(Data("output".utf8), stream: .output),
            .data(Data("tty".utf8), stream: .terminal),
            .eof(.input),
            .eof(.output),
            .eof(.terminal),
            .resize(columns: 132, rows: 43),
            .error("broken stream"),
        ]
        for frame in frames {
            var line = try frame.encodeLine()
            XCTAssertEqual(line.removeLast(), 0x0A)
            XCTAssertEqual(try GhostboxIOFrame.decode(line: line), frame)
        }
    }

    func testIOFramesRejectMalformedAndOversizedValues() {
        let invalid = [
            GhostboxIOFrame(type: .data, stream: .input, data: Data()),
            GhostboxIOFrame(type: .eof),
            GhostboxIOFrame(type: .resize, stream: .terminal, columns: 0, rows: 24),
            GhostboxIOFrame(type: .error, message: ""),
            GhostboxIOFrame(type: .data, stream: .input, data: Data(repeating: 0, count: kMaxIOFrameDataBytes + 1)),
        ]
        for frame in invalid {
            XCTAssertThrowsError(try frame.encodeLine())
        }
        XCTAssertThrowsError(try GhostboxIOFrame.decode(line: Data("not-json".utf8)))
    }
    func testDirectRequestUsesMethodParametersAndCurrentEnvelope() throws {
        let request = GhostboxDirectRequest(
            id: "request-1",
            invocation: .init(
                method: .dnsCreate,
                parameters: ["name": .string("dev"), "nameservers": .array([.string("1.1.1.1")])]
            )
        )
        let line = try encodeDirectRequestLine(request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.dropLast())) as? [String: Any])
        XCTAssertEqual(Set(object.keys), Set(["version", "operation", "id", "method", "parameters"]))
        XCTAssertEqual(object["version"] as? Int, kProtocolVersion)
        XCTAssertEqual(object["operation"] as? String, "direct")
        XCTAssertEqual(object["id"] as? String, "request-1")
        XCTAssertEqual(object["method"] as? String, "dns.create")
        XCTAssertEqual((object["parameters"] as? [String: Any])?["name"] as? String, "dev")
    }

    func testDirectMethodAllowsUnknownRawValues() throws {
        let method = GhostboxDirectMethod(rawValue: "snapshot.prepare")
        XCTAssertEqual(try JSONDecoder().decode(GhostboxDirectMethod.self, from: JSONEncoder().encode(method)), method)
    }

    func testJSONValueRoundTripsEverySupportedShape() throws {
        let value = GhostboxJSONValue.object([
            "null": .null,
            "bool": .boolean(true),
            "string": .string("value"),
            "integer": .integer(-42),
            "unsigned": .unsignedInteger(UInt64.max),
            "array": .array([.integer(1), .object(["nested": .string("yes")])]),
        ])
        let data = try JSONEncoder().encode(value)
        XCTAssertEqual(try JSONDecoder().decode(GhostboxJSONValue.self, from: data), value)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains(String(UInt64.max)))
    }

    func testJSONValueRejectsMalformedUnsignedIntegerTags() {
        let malformed = [
            #"{"$uint64":18446744073709551615}"#,
            #"{"$uint64":"18446744073709551616"}"#,
            #"{"$uint64":"01"}"#,
            #"{"$uint64":"1","extra":true}"#,
        ]
        for json in malformed {
            XCTAssertThrowsError(try JSONDecoder().decode(GhostboxJSONValue.self, from: Data(json.utf8)), json)
        }
    }

    func testDirectResultRoundTripsUInt64MaxWithoutPrecisionLoss() throws {
        let value = GhostboxDirectValue.unsignedInteger(UInt64.max)
        XCTAssertEqual(try JSONDecoder().decode(GhostboxDirectValue.self, from: JSONEncoder().encode(value)), value)
    }

    func testMaximumByteResponseFitsResponseLineLimit() throws {
        let value = GhostboxDirectValue.bytes(Data(repeating: 0xA5, count: kMaxDirectBytePayloadBytes))
        let response = GhostboxDirectResponse(
            version: kProtocolVersion,
            id: "request-1",
            result: value,
            error: nil
        )
        let encoded = try JSONEncoder().encode(response)
        XCTAssertLessThanOrEqual(encoded.count, kMaxDirectResponseLineBytes)
        XCTAssertEqual(try JSONDecoder().decode(GhostboxDirectResponse.self, from: encoded), response)

        XCTAssertThrowsError(try JSONEncoder().encode(
            GhostboxDirectValue.bytes(Data(repeating: 0, count: kMaxDirectBytePayloadBytes + 1))
        ))
    }

    func testMaximumIOFrameFitsFrameLineLimit() throws {
        let frame = GhostboxIOFrame.data(Data(repeating: 0x5A, count: kMaxIOFrameDataBytes), stream: .terminal)
        let line = try frame.encodeLine()
        XCTAssertLessThanOrEqual(line.count - 1, kMaxIOFrameLineBytes)
        XCTAssertEqual(try GhostboxIOFrame.decode(line: Data(line.dropLast())), frame)
    }

    func testDirectResultRejectsMalformedTaggedValues() {
        let malformed = [
            #"{"type":"void","value":null}"#,
            #"{"type":"string"}"#,
            #"{"type":"unsigned_integer","value":18446744073709551615}"#,
            #"{"type":"unsigned_integer","value":"01"}"#,
            #"{"type":"null","extra":true}"#,
        ]
        for json in malformed {
            XCTAssertThrowsError(try JSONDecoder().decode(GhostboxDirectValue.self, from: Data(json.utf8)), json)
        }
    }

    func testDirectResponseRequiresMatchingRequestID() throws {
        let response = GhostboxDirectResponse(
            version: kProtocolVersion,
            id: "other-request",
            result: .reference("@dns/dev"),
            error: nil
        )
        guard case .protocolError = decodeDirectResponse(try JSONEncoder().encode(response), requestID: "request-1") else {
            return XCTFail("Expected response ID mismatch to fail")
        }
    }

    func testDirectResponseDecodesStableError() throws {
        let response = GhostboxDirectResponse(
            version: kProtocolVersion,
            id: "request-1",
            result: nil,
            error: .init(code: "not_found", message: "DNS object missing")
        )
        XCTAssertEqual(
            decodeDirectResponse(try JSONEncoder().encode(response), requestID: "request-1"),
            .error(code: "not_found", message: "DNS object missing")
        )
    }

    func testDirectValueRenderingIsJSONCompatibleAndReferencesAreClear() throws {
        XCTAssertEqual(String(decoding: try renderDirectValue(.reference("@dns/dev")), as: UTF8.self), "@dns/dev\n")
        XCTAssertEqual(String(decoding: try renderDirectValue(.string("example.test")), as: UTF8.self), "\"example.test\"\n")
        XCTAssertEqual(String(decoding: try renderDirectValue(.strings(["a", "b"])), as: UTF8.self), "[\"a\",\"b\"]\n")
        XCTAssertEqual(String(decoding: try renderDirectValue(.object(["items": .array([.integer(1), .boolean(true)])])), as: UTF8.self), "{\"items\":[1,true]}\n")
        XCTAssertEqual(String(decoding: try renderDirectValue(.unsignedInteger(UInt64.max)), as: UTF8.self), "\(UInt64.max)\n")
        XCTAssertEqual(try renderDirectValue(.void), Data())
        XCTAssertEqual(String(decoding: try renderDirectValue(.null), as: UTF8.self), "null\n")
    }

    func testDirectRequestRejectsPayloadAboveBridgeLimit() {
        let request = GhostboxDirectRequest(
            id: "request-large",
            invocation: .init(
                method: .dnsCreate,
                parameters: ["name": .string("large"), "domain": .string(String(repeating: "x", count: 64 * 1024))]
            )
        )
        XCTAssertThrowsError(try encodeDirectRequestLine(request)) { error in
            XCTAssertEqual(error as? GhostboxDirectProtocolError, .requestTooLarge)
        }
    }
}
