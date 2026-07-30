@testable import ghost_container
import XCTest

final class ProtocolTests: XCTestCase {

    // MARK: - Request encoding

    func testRequestWireFormatMatchesExactly() throws {
        let req = makeRunRequest(image: "alpine", command: ["echo", "hello"])
        let line = try encodeRequestLine(req)
        let s = String(data: line, encoding: .utf8)!

        XCTAssertEqual(s, #"{"version":1,"operation":"run","image":"alpine","command":["echo","hello"]}"# + "\n")
    }

    func testRequestWithEmptyCommand() throws {
        let req = makeRunRequest(image: "ubuntu:24.04", command: [])
        let line = try encodeRequestLine(req)
        let s = String(data: line, encoding: .utf8)!

        XCTAssertEqual(s, #"{"version":1,"operation":"run","image":"ubuntu:24.04","command":[]}"# + "\n")
    }

    // MARK: - Response decoding: success cases

    func testDecodeStdout() throws {
        let payload = "hello world".data(using: .utf8)!
        let b64 = payload.base64EncodedString()
        let json = #"{"version":1,"type":"stdout","data":"\#(b64)"}"#.data(using: .utf8)!

        switch decodeResponse(json) {
        case .stdout(let data):
            XCTAssertEqual(data, payload)
        default:
            XCTFail("Expected .stdout")
        }
    }

    func testDecodeStderr() throws {
        let payload = "error line".data(using: .utf8)!
        let b64 = payload.base64EncodedString()
        let json = #"{"version":1,"type":"stderr","data":"\#(b64)"}"#.data(using: .utf8)!

        switch decodeResponse(json) {
        case .stderr(let data):
            XCTAssertEqual(data, payload)
        default:
            XCTFail("Expected .stderr")
        }
    }

    func testDecodeExit() throws {
        let json = #"{"version":1,"type":"exit","exitCode":42}"#.data(using: .utf8)!

        switch decodeResponse(json) {
        case .exit(let code):
            XCTAssertEqual(code, 42)
        default:
            XCTFail("Expected .exit")
        }
    }

    func testDecodeExitZero() throws {
        let json = #"{"version":1,"type":"exit","exitCode":0}"#.data(using: .utf8)!

        switch decodeResponse(json) {
        case .exit(let code):
            XCTAssertEqual(code, 0)
        default:
            XCTFail("Expected .exit")
        }
    }

    func testDecodeExit255() throws {
        let json = #"{"version":1,"type":"exit","exitCode":255}"#.data(using: .utf8)!

        switch decodeResponse(json) {
        case .exit(let code):
            XCTAssertEqual(code, 255)
        default:
            XCTFail("Expected .exit")
        }
    }

    func testDecodeError() throws {
        let json = #"{"version":1,"type":"error","message":"image not found"}"#.data(using: .utf8)!

        switch decodeResponse(json) {
        case .error(let message):
            XCTAssertEqual(message, "image not found")
        default:
            XCTFail("Expected .error")
        }
    }

    // MARK: - Response decoding: empty base64 is valid empty output

    func testDecodeStdoutEmptyBase64StringYieldsEmpty() throws {
        let json = #"{"version":1,"type":"stdout","data":""}"#.data(using: .utf8)!

        switch decodeResponse(json) {
        case .stdout(let data):
            XCTAssertTrue(data.isEmpty)
        default:
            XCTFail("Expected .stdout with empty data")
        }
    }

    func testDecodeStderrEmptyBase64StringYieldsEmpty() throws {
        let json = #"{"version":1,"type":"stderr","data":""}"#.data(using: .utf8)!

        switch decodeResponse(json) {
        case .stderr(let data):
            XCTAssertTrue(data.isEmpty)
        default:
            XCTFail("Expected .stderr with empty data")
        }
    }

    func testDecodeStdoutMissingDataIsProtocolError() throws {
        let json = #"{"version":1,"type":"stdout"}"#.data(using: .utf8)!

        switch decodeResponse(json) {
        case .protocolError:
            break
        default:
            XCTFail("Expected .protocolError for missing data")
        }
    }

    // MARK: - Response decoding: strict protocol errors (never success)

    func testDecodeStdoutInvalidBase64IsProtocolError() throws {
        let json = #"{"version":1,"type":"stdout","data":"!!! not base64"}"#.data(using: .utf8)!

        switch decodeResponse(json) {
        case .protocolError:
            break
        default:
            XCTFail("Expected .protocolError for invalid base64, not silent empty output")
        }
    }

    func testDecodeExitMissingCodeIsProtocolError() throws {
        let json = #"{"version":1,"type":"exit"}"#.data(using: .utf8)!

        switch decodeResponse(json) {
        case .protocolError:
            break
        default:
            XCTFail("Expected .protocolError for missing exitCode")
        }
    }

    func testDecodeExitOutOfRangeHighIsProtocolError() throws {
        let json = #"{"version":1,"type":"exit","exitCode":256}"#.data(using: .utf8)!

        switch decodeResponse(json) {
        case .protocolError:
            break
        default:
            XCTFail("Expected .protocolError for out-of-range exitCode")
        }
    }

    func testDecodeExitNegativeIsProtocolError() throws {
        let json = #"{"version":1,"type":"exit","exitCode":-1}"#.data(using: .utf8)!

        switch decodeResponse(json) {
        case .protocolError:
            break
        default:
            XCTFail("Expected .protocolError for negative exitCode")
        }
    }

    func testDecodeErrorMissingMessageIsProtocolError() throws {
        let json = #"{"version":1,"type":"error"}"#.data(using: .utf8)!

        switch decodeResponse(json) {
        case .protocolError:
            break
        default:
            XCTFail("Expected .protocolError for missing error message")
        }
    }

    func testDecodeErrorEmptyMessageIsProtocolError() throws {
        let json = #"{"version":1,"type":"error","message":""}"#.data(using: .utf8)!

        switch decodeResponse(json) {
        case .protocolError:
            break
        default:
            XCTFail("Expected .protocolError for empty error message")
        }
    }

    func testDecodeUnsupportedVersionIsProtocolError() throws {
        let json = #"{"version":99,"type":"exit","exitCode":0}"#.data(using: .utf8)!

        switch decodeResponse(json) {
        case .protocolError:
            break
        default:
            XCTFail("Expected .protocolError for wrong version")
        }
    }

    func testDecodeMissingVersionIsProtocolError() throws {
        // version is now required.
        let json = #"{"type":"exit","exitCode":7}"#.data(using: .utf8)!

        switch decodeResponse(json) {
        case .protocolError:
            break
        default:
            XCTFail("Expected .protocolError for missing version")
        }
    }

    func testDecodeUnknownTypeIsProtocolError() throws {
        let json = #"{"version":1,"type":"bogus"}"#.data(using: .utf8)!

        switch decodeResponse(json) {
        case .protocolError:
            break
        default:
            XCTFail("Expected .protocolError for unknown type")
        }
    }

    func testDecodeMalformedJSONIsProtocolError() throws {
        let json = "not json".data(using: .utf8)!

        switch decodeResponse(json) {
        case .protocolError:
            break
        default:
            XCTFail("Expected .protocolError for malformed JSON")
        }
    }

    // MARK: - Exit code clamping (predictable, no bit masking)

    func testClampExitCodeZero() {
        XCTAssertEqual(clampExitCode(0), 0)
    }

    func testClampExitCodeNormal() {
        XCTAssertEqual(clampExitCode(42), 42)
    }

    func testClampExitCodeNormalUnchangedInRange() {
        for c in Int32(0)...Int32(255) {
            XCTAssertEqual(clampExitCode(c), c, "exit \(c) should map to itself")
        }
    }

    func testClampExitCode256MapsTo125() {
        // Out-of-range host status maps to 125, not bit masking.
        XCTAssertEqual(clampExitCode(256), 125)
    }

    func testClampExitCodeNegativeMapsTo125() {
        XCTAssertEqual(clampExitCode(-1), 125)
        XCTAssertEqual(clampExitCode(-2), 125)
    }

    func testClampExitCode255() {
        XCTAssertEqual(clampExitCode(255), 255)
    }

    func testClampExitCodeLargeMapsTo125() {
        XCTAssertEqual(clampExitCode(1000), 125)
    }
}
