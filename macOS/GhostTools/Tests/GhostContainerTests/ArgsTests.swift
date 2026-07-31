@testable import ghost_container
import XCTest

final class ArgsTests: XCTestCase {

    func testNoArgumentsReturnsHelp() {
        let result = parseArguments([])
        guard case .success(let opts) = result, case .help = opts.action else {
            return XCTFail("Expected .help, got \(result)")
        }
    }

    func testHelpFlag() {
        for flag in ["--help", "-h", "help"] {
            let result = parseArguments([flag])
            guard case .success(let opts) = result, case .help = opts.action else {
                return XCTFail("Expected .help for '\(flag)', got \(result)")
            }
        }
    }

    func testVersionFlag() {
        for flag in ["--version", "-v"] {
            let result = parseArguments([flag])
            guard case .success(let opts) = result, case .version = opts.action else {
                return XCTFail("Expected .version for '\(flag)', got \(result)")
            }
        }
    }

    func testRunWithImageOnly() {
        let result = parseArguments(["run", "alpine"])
        guard case .success(let opts) = result,
              case .run(let image, let command, let volumes, let interactive, let tty) = opts.action else {
            return XCTFail("Expected .run, got \(result)")
        }
        XCTAssertEqual(image, "alpine")
        XCTAssertEqual(command, [])
        XCTAssertEqual(volumes, [])
        XCTAssertFalse(interactive)
        XCTAssertFalse(tty)
    }

    func testRunWithCommand() {
        let result = parseArguments(["run", "alpine", "echo", "hello"])
        guard case .success(let opts) = result,
              case .run(let image, let command, _, _, _) = opts.action else {
            return XCTFail("Expected .run, got \(result)")
        }
        XCTAssertEqual(image, "alpine")
        XCTAssertEqual(command, ["echo", "hello"])
    }

    func testCommandMayBeginWithDash() {
        let result = parseArguments(["run", "alpine", "-c", "--flag", "-n"])
        guard case .success(let opts) = result,
              case .run(let image, let command, _, _, _) = opts.action else {
            return XCTFail("Expected .run, got \(result)")
        }
        XCTAssertEqual(image, "alpine")
        XCTAssertEqual(command, ["-c", "--flag", "-n"])
    }

    func testRejectsFlagBeforeImage() {
        let result = parseArguments(["run", "--some-flag", "alpine"])
        guard case .failure(let err) = result else {
            return XCTFail("Expected failure for flag-before-image, got \(result)")
        }
        XCTAssertEqual(err.errorDescription, "invalid IMAGE: image name must not start with '-'")
    }

    func testRejectsUnknownSubcommand() {
        let result = parseArguments(["bogus"])
        guard case .failure(let err) = result else {
            return XCTFail("Expected failure, got \(result)")
        }
        if case .unknownSubcommand(let sub) = err {
            XCTAssertEqual(sub, "bogus")
        } else {
            XCTFail("Expected .unknownSubcommand, got \(err)")
        }
    }

    func testRejectsMissingImage() {
        let result = parseArguments(["run"])
        guard case .failure(let err) = result else {
            return XCTFail("Expected failure, got \(result)")
        }
        if case .missingImage = err {} else {
            XCTFail("Expected .missingImage, got \(err)")
        }
    }

    func testRejectsEmptyImage() {
        XCTAssertNotNil(validateImage(""))
    }

    func testRejectsNullInImage() {
        XCTAssertNotNil(validateImage("alpine\0evil"))
    }

    func testRejectsLeadingDashInImage() {
        XCTAssertNotNil(validateImage("-evil"))
    }

    func testRejectsTooLongImage() {
        // Length is measured in UTF-8 bytes.
        XCTAssertNotNil(validateImage(String(repeating: "a", count: 257)))
    }

    func testRejectsTooLongImageByUtf8Bytes() {
        // 256 'a' is exactly at the limit → accepted.
        XCTAssertNil(validateImage(String(repeating: "a", count: 256)))
        // A single 2-byte UTF-8 char pushes past 256 bytes even though char count
        // is 1 + a few ascii — verify byte-based measurement.
        // 255 'a' (255 bytes) + one 2-byte char (é) = 257 bytes → rejected.
        let s = String(repeating: "a", count: 255) + "é"
        XCTAssertGreaterThan(s.utf8.count, 256)
        XCTAssertNotNil(validateImage(s))
    }

    func testRejectsWhitespaceInImage() {
        XCTAssertNotNil(validateImage("alpine latest"))
        XCTAssertNotNil(validateImage("alpine\tlatest"))
        XCTAssertNotNil(validateImage("alpine\nlatest"))
    }

    func testValidImageAccepted() {
        XCTAssertNil(validateImage("alpine"))
        XCTAssertNil(validateImage("ubuntu:24.04"))
        XCTAssertNil(validateImage("registry.example.com/my/img:v1"))
    }

    // MARK: - Command argument validation

    func testRejectsTooManyCommandArgs() {
        var argv = ["run", "alpine"]
        argv.append(contentsOf: (0..<65).map { "c\($0)" })
        let result = parseArguments(argv)
        guard case .failure(let err) = result else {
            return XCTFail("Expected failure for too many command args, got \(result)")
        }
        if case .tooManyCommands(let max) = err {
            XCTAssertEqual(max, 64)
        } else {
            XCTFail("Expected .tooManyCommands, got \(err)")
        }
    }

    func testAcceptsMaxCommandArgs() {
        var argv = ["run", "alpine"]
        argv.append(contentsOf: (0..<64).map { "c\($0)" })
        let result = parseArguments(argv)
        guard case .success(let opts) = result,
              case .run(_, let command, _, _, _) = opts.action else {
            return XCTFail("Expected .run with 64 command args, got \(result)")
        }
        XCTAssertEqual(command.count, 64)
    }

    func testRejectsNullInCommandArg() {
        let result = parseArguments(["run", "alpine", "echo\0evil"])
        guard case .failure(let err) = result else {
            return XCTFail("Expected failure for NUL in command arg, got \(result)")
        }
        if case .invalidCommand(let index, _) = err {
            XCTAssertEqual(index, 0)
        } else {
            XCTFail("Expected .invalidCommand, got \(err)")
        }
    }

    func testRejectsTooLongCommandArgByUtf8Bytes() {
        // 4096 bytes accepted, 4097 rejected.
        let ok = String(repeating: "a", count: 4096)
        let result = parseArguments(["run", "alpine", ok])
        guard case .success = result else {
            return XCTFail("Expected success for 4096-byte arg, got \(result)")
        }

        let tooLong = String(repeating: "a", count: 4097)
        let result2 = parseArguments(["run", "alpine", tooLong])
        guard case .failure(let err) = result2 else {
            return XCTFail("Expected failure for 4097-byte arg, got \(result2)")
        }
        if case .invalidCommand(let index, _) = err {
            XCTAssertEqual(index, 0)
        } else {
            XCTFail("Expected .invalidCommand, got \(err)")
        }
    }

    func testCommandArgUtf8ByteLengthNotCharCount() {
        // 'é' is 1 char but 2 UTF-8 bytes. 4095 'é' = 8190 bytes → rejected.
        let arg = String(repeating: "é", count: 4095)
        XCTAssertGreaterThan(arg.utf8.count, 4096)
        let result = parseArguments(["run", "alpine", arg])
        guard case .failure = result else {
            return XCTFail("Expected failure for oversized-by-utf8 arg, got \(result)")
        }
    }

    // MARK: - Volumes

    func testParsesReadOnlyVolumeBeforeImage() {
        let result = parseArguments(["run", "-v", "/home/user/src:/src:ro", "alpine", "ls", "/src"])
        guard case .success(let options) = result,
              case .run(let image, let command, let volumes, _, _) = options.action else {
            return XCTFail("Expected volume run, got \(result)")
        }
        XCTAssertEqual(image, "alpine")
        XCTAssertEqual(command, ["ls", "/src"])
        XCTAssertEqual(volumes, [HostContainerVolume(guestPath: "/home/user/src", destination: "/src", readOnly: true)])
    }

    func testParsesLongVolumeFlag() {
        let result = parseArguments(["run", "--volume=/data:/mnt/data:ro", "alpine"])
        guard case .success(let options) = result,
              case .run(_, _, let volumes, _, _) = options.action else {
            return XCTFail("Expected volume run, got \(result)")
        }
        XCTAssertEqual(volumes.first?.destination, "/mnt/data")
    }

    func testRejectsImplicitReadWriteVolume() {
        let result = parseArguments(["run", "-v", "/data:/data", "alpine"])
        guard case .failure(let error) = result else {
            return XCTFail("Expected read-write volume rejection")
        }
        XCTAssertEqual(error.errorDescription, "invalid volume: guest directory mounts are currently read-only; append ':ro'")
    }

    func testRejectsDuplicateVolumeDestination() {
        let result = parseArguments(["run", "-v", "/one:/data:ro", "-v", "/two:/data:ro", "alpine"])
        guard case .failure(let error) = result else {
            return XCTFail("Expected duplicate destination rejection")
        }
        XCTAssertEqual(error.errorDescription, "duplicate container volume destination '/data'")
    }

    func testRejectsVolumeDestinationTraversal() {
        let result = parseArguments(["run", "-v", "/data:/mnt/../:ro", "alpine"])
        guard case .failure = result else {
            return XCTFail("Expected traversal destination rejection")
        }
    }

    func testParsesInteractiveTTYFlags() {
        for flag in ["-it", "-ti"] {
            let result = parseArguments(["run", flag, "alpine", "/bin/sh"])
            guard case .success(let options) = result,
                  case .run(_, let command, _, let interactive, let tty) = options.action else {
                return XCTFail("Expected interactive TTY run for \(flag), got \(result)")
            }
            XCTAssertEqual(command, ["/bin/sh"])
            XCTAssertTrue(interactive)
            XCTAssertTrue(tty)
        }
    }

    func testParsesSeparateInteractiveTTYFlagsMixedWithVolume() {
        let result = parseArguments(["run", "-i", "-v", "/data:/data:ro", "-t", "alpine"])
        guard case .success(let options) = result,
              case .run(_, _, let volumes, let interactive, let tty) = options.action else {
            return XCTFail("Expected interactive TTY volume run, got \(result)")
        }
        XCTAssertEqual(volumes.count, 1)
        XCTAssertTrue(interactive)
        XCTAssertTrue(tty)
    }
}
