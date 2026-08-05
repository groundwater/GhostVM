@testable import ghostbox
import XCTest

final class ProtocolTests: XCTestCase {

    // MARK: - Request encoding

    func testRequestWireFormatMatchesExactly() throws {
        let req = makeRunRequest(image: "alpine", command: ["echo", "hello"])
        let line = try encodeRequestLine(req)
        let s = String(data: line, encoding: .utf8)!

        XCTAssertEqual(s, #"{"version":4,"operation":"run","image":"alpine","command":["echo","hello"],"stdin":false,"tty":false}"# + "\n")
    }

    func testRequestWithEmptyCommand() throws {
        let req = makeRunRequest(image: "ubuntu:24.04", command: [])
        let line = try encodeRequestLine(req)
        let s = String(data: line, encoding: .utf8)!

        XCTAssertEqual(s, #"{"version":4,"operation":"run","image":"ubuntu:24.04","command":[],"stdin":false,"tty":false}"# + "\n")
    }

    func testRequestWithVolume() throws {
        let volume = HostContainerVolume(guestPath: "/home/user/src", destination: "/src", readOnly: true)
        let request = makeRunRequest(image: "alpine", command: [], volumes: [volume])
        let line = try encodeRequestLine(request)
        XCTAssertEqual(
            String(data: line, encoding: .utf8),
            #"{"version":4,"operation":"run","image":"alpine","command":[],"stdin":false,"tty":false,"volumes":[{"guestPath":"/home/user/src","destination":"/src","readOnly":true}]}"# + "\n"
        )
    }

    func testInteractiveTTYRequestIncludesTerminalSize() throws {
        let request = makeRunRequest(
            image: "alpine",
            command: ["/bin/sh"],
            interactive: true,
            tty: true,
            columns: 120,
            rows: 40
        )
        XCTAssertEqual(
            String(data: try encodeRequestLine(request), encoding: .utf8),
            #"{"version":4,"operation":"run","image":"alpine","command":["/bin/sh"],"stdin":true,"tty":true,"columns":120,"rows":40}"# + "\n"
        )
    }

    func testConfiguredRunRequestIncludesVersion4Fields() throws {
        let request = makeRunRequest(
            image: "alpine",
            command: [],
            environment: ["MODE=production"],
            workingDirectory: "/app",
            user: "1000:1000",
            cpus: 4,
            memoryBytes: 2_147_483_648
        )
        XCTAssertEqual(
            String(data: try encodeRequestLine(request), encoding: .utf8),
            #"{"version":4,"operation":"run","image":"alpine","command":[],"stdin":false,"tty":false,"environment":["MODE=production"],"workingDirectory":"/app","user":"1000:1000","cpus":4,"memoryBytes":2147483648}"# + "\n"
        )
    }

    func testInputFramesAreNDJSON() throws {
        let input = try encodeInputFrame(.stdin(Data([0x00, 0xFF])))
        let resize = try encodeInputFrame(.resize(columns: 132, rows: 43))
        XCTAssertEqual(input.last, 0x0A)
        XCTAssertEqual(resize.last, 0x0A)
        let inputObject = try JSONSerialization.jsonObject(with: Data(input.dropLast())) as? [String: Any]
        let resizeObject = try JSONSerialization.jsonObject(with: Data(resize.dropLast())) as? [String: Any]
        XCTAssertEqual(inputObject?["type"] as? String, "stdin")
        XCTAssertEqual(inputObject?["data"] as? String, Data([0x00, 0xFF]).base64EncodedString())
        XCTAssertEqual(resizeObject?["columns"] as? Int, 132)
        XCTAssertEqual(resizeObject?["rows"] as? Int, 43)
    }

    // MARK: - Response decoding: success cases

    func testDecodeReadyAddress() throws {
        let json = #"{"version":4,"type":"ready","ipv4Address":"192.168.64.3"}"#.data(using: .utf8)!
        guard case .ready(let address) = decodeResponse(json) else {
            return XCTFail("Expected ready response")
        }
        XCTAssertEqual(address, "192.168.64.3")
    }

    func testDecodeStdout() throws {
        let payload = "hello world".data(using: .utf8)!
        let b64 = payload.base64EncodedString()
        let json = #"{"version":4,"type":"stdout","data":"\#(b64)"}"#.data(using: .utf8)!

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
        let json = #"{"version":4,"type":"stderr","data":"\#(b64)"}"#.data(using: .utf8)!

        switch decodeResponse(json) {
        case .stderr(let data):
            XCTAssertEqual(data, payload)
        default:
            XCTFail("Expected .stderr")
        }
    }

    func testDecodeExit() throws {
        let json = #"{"version":4,"type":"exit","exitCode":42}"#.data(using: .utf8)!

        switch decodeResponse(json) {
        case .exit(let code):
            XCTAssertEqual(code, 42)
        default:
            XCTFail("Expected .exit")
        }
    }

    func testDecodeExitZero() throws {
        let json = #"{"version":4,"type":"exit","exitCode":0}"#.data(using: .utf8)!

        switch decodeResponse(json) {
        case .exit(let code):
            XCTAssertEqual(code, 0)
        default:
            XCTFail("Expected .exit")
        }
    }

    func testDecodeExit255() throws {
        let json = #"{"version":4,"type":"exit","exitCode":255}"#.data(using: .utf8)!

        switch decodeResponse(json) {
        case .exit(let code):
            XCTAssertEqual(code, 255)
        default:
            XCTFail("Expected .exit")
        }
    }

    func testDecodeError() throws {
        let json = #"{"version":4,"type":"error","message":"image not found"}"#.data(using: .utf8)!

        switch decodeResponse(json) {
        case .error(let message):
            XCTAssertEqual(message, "image not found")
        default:
            XCTFail("Expected .error")
        }
    }

    // MARK: - Response decoding: empty base64 is valid empty output

    func testDecodeStdoutEmptyBase64StringYieldsEmpty() throws {
        let json = #"{"version":4,"type":"stdout","data":""}"#.data(using: .utf8)!

        switch decodeResponse(json) {
        case .stdout(let data):
            XCTAssertTrue(data.isEmpty)
        default:
            XCTFail("Expected .stdout with empty data")
        }
    }

    func testDecodeStderrEmptyBase64StringYieldsEmpty() throws {
        let json = #"{"version":4,"type":"stderr","data":""}"#.data(using: .utf8)!

        switch decodeResponse(json) {
        case .stderr(let data):
            XCTAssertTrue(data.isEmpty)
        default:
            XCTFail("Expected .stderr with empty data")
        }
    }

    func testDecodeStdoutMissingDataIsProtocolError() throws {
        let json = #"{"version":4,"type":"stdout"}"#.data(using: .utf8)!

        switch decodeResponse(json) {
        case .protocolError:
            break
        default:
            XCTFail("Expected .protocolError for missing data")
        }
    }

    // MARK: - Response decoding: strict protocol errors (never success)

    func testDecodeStdoutInvalidBase64IsProtocolError() throws {
        let json = #"{"version":4,"type":"stdout","data":"!!! not base64"}"#.data(using: .utf8)!

        switch decodeResponse(json) {
        case .protocolError:
            break
        default:
            XCTFail("Expected .protocolError for invalid base64, not silent empty output")
        }
    }

    func testDecodeExitMissingCodeIsProtocolError() throws {
        let json = #"{"version":4,"type":"exit"}"#.data(using: .utf8)!

        switch decodeResponse(json) {
        case .protocolError:
            break
        default:
            XCTFail("Expected .protocolError for missing exitCode")
        }
    }

    func testDecodeExitOutOfRangeHighIsProtocolError() throws {
        let json = #"{"version":4,"type":"exit","exitCode":256}"#.data(using: .utf8)!

        switch decodeResponse(json) {
        case .protocolError:
            break
        default:
            XCTFail("Expected .protocolError for out-of-range exitCode")
        }
    }

    func testDecodeExitNegativeIsProtocolError() throws {
        let json = #"{"version":4,"type":"exit","exitCode":-1}"#.data(using: .utf8)!

        switch decodeResponse(json) {
        case .protocolError:
            break
        default:
            XCTFail("Expected .protocolError for negative exitCode")
        }
    }

    func testDecodeErrorMissingMessageIsProtocolError() throws {
        let json = #"{"version":4,"type":"error"}"#.data(using: .utf8)!

        switch decodeResponse(json) {
        case .protocolError:
            break
        default:
            XCTFail("Expected .protocolError for missing error message")
        }
    }

    func testDecodeErrorEmptyMessageIsProtocolError() throws {
        let json = #"{"version":4,"type":"error","message":""}"#.data(using: .utf8)!

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
        let json = #"{"version":4,"type":"bogus"}"#.data(using: .utf8)!

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

    func testTerminalNewlineNormalizerConvertsBareLineFeeds() {
        var normalizer = TerminalNewlineNormalizer()
        let output = normalizer.normalize(Data("one\ntwo\n".utf8))
        XCTAssertEqual(output, Data("one\r\ntwo\r\n".utf8))
    }

    func testTerminalNewlineNormalizerPreservesCarriageReturnsAcrossChunks() {
        var normalizer = TerminalNewlineNormalizer()
        let first = normalizer.normalize(Data("one\r".utf8))
        let second = normalizer.normalize(Data("\ntwo\r\n".utf8))
        XCTAssertEqual(first + second, Data("one\r\ntwo\r\n".utf8))
    }
}
