import XCTest
@testable import GhostVMKit

final class ContainerRunPolicyTests: XCTestCase {

    private func request(
        version: Int = 1,
        operation: String = "run",
        image: String = "alpine",
        command: [String] = ["echo", "hello"],
        stdin: Bool? = nil,
        tty: Bool? = nil,
        columns: UInt16? = nil,
        rows: UInt16? = nil,
        volumes: [ContainerRunVolume]? = nil,
        environment: [String]? = nil,
        workingDirectory: String? = nil,
        user: String? = nil,
        cpus: Int? = nil,
        memoryBytes: UInt64? = nil
    ) -> ContainerRunRequest {
        ContainerRunRequest(
            version: version,
            operation: operation,
            image: image,
            command: command,
            stdin: stdin,
            tty: tty,
            columns: columns,
            rows: rows,
            volumes: volumes,
            environment: environment,
            workingDirectory: workingDirectory,
            user: user,
            cpus: cpus,
            memoryBytes: memoryBytes
        )
    }

    private func assertRejected(
        _ request: ContainerRunRequest,
        expected: ContainerPolicyError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            _ = try ContainerRunPolicy.validate(request)
            XCTFail("Expected \(expected) to be thrown", file: file, line: line)
        } catch let error as ContainerPolicyError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Expected ContainerPolicyError, got \(error)", file: file, line: line)
        }
    }

    // MARK: - Valid requests

    func testValidRequestPasses() throws {
        let run = try ContainerRunPolicy.validate(request())
        XCTAssertEqual(run.image, "alpine")
        XCTAssertEqual(run.command, ["echo", "hello"])
        XCTAssertFalse(run.attachStdin)
    }

    func testAttachedStdinPasses() throws {
        let run = try ContainerRunPolicy.validate(request(command: ["cat"], stdin: true))
        XCTAssertTrue(run.attachStdin)
        XCTAssertEqual(
            run.containerArguments(vmHash: "12345", uniqueSuffix: "abcd1234"),
            ["run", "-i", "--cpus", "2", "--memory-bytes", "1073741824", "--id", "gv-12345-abcd1234", "--image", "alpine", "--", "cat"]
        )
    }

    func testInteractiveTTYPasses() throws {
        let run = try ContainerRunPolicy.validate(request(
            version: 2,
            command: ["/bin/sh"],
            stdin: true,
            tty: true,
            columns: 120,
            rows: 40
        ))
        XCTAssertTrue(run.attachStdin)
        XCTAssertTrue(run.allocateTTY)
        XCTAssertEqual(run.terminalColumns, 120)
        XCTAssertEqual(run.terminalRows, 40)
        XCTAssertEqual(
            run.containerArguments(vmHash: "12345", uniqueSuffix: "abcd1234"),
            ["run", "-i", "-t", "--tty-size", "120", "40", "--cpus", "2", "--memory-bytes", "1073741824", "--id", "gv-12345-abcd1234", "--image", "alpine", "--", "/bin/sh"]
        )
    }

    func testEmptyCommandIsAllowed() throws {
        let run = try ContainerRunPolicy.validate(request(command: []))
        XCTAssertEqual(run.command, [])
    }

    func testReadOnlyVolumePasses() throws {
        let volume = ContainerRunVolume(guestPath: "/home/user/src", destination: "/src", readOnly: true)
        let run = try ContainerRunPolicy.validate(request(volumes: [volume]))
        XCTAssertEqual(run.volumes, [volume])
    }

    func testVersion4RunConfigurationPasses() throws {
        let run = try ContainerRunPolicy.validate(request(
            version: 4,
            environment: ["MODE=production"],
            workingDirectory: "/app",
            user: "1000:1000",
            cpus: 4,
            memoryBytes: 2 * 1024 * 1024 * 1024
        ))
        XCTAssertEqual(run.environment, ["MODE=production"])
        XCTAssertEqual(run.workingDirectory, "/app")
        XCTAssertEqual(run.user, "1000:1000")
        XCTAssertEqual(run.cpus, 4)
        XCTAssertEqual(run.memoryBytes, 2 * 1024 * 1024 * 1024)
        XCTAssertEqual(
            run.containerArguments(vmHash: "12345", uniqueSuffix: "abcd1234"),
            ["run", "--env", "MODE=production", "--workdir", "/app", "--user", "1000:1000", "--cpus", "4", "--memory-bytes", "2147483648", "--id", "gv-12345-abcd1234", "--image", "alpine", "--", "echo", "hello"]
        )
    }

    /// `container run` parses post-image arguments with captureForPassthrough,
    /// so command elements starting with '-' reach the container verbatim.
    func testCommandArgumentsStartingWithDashAreAllowed() throws {
        let run = try ContainerRunPolicy.validate(request(command: ["echo", "-n", "hi"]))
        XCTAssertEqual(run.command, ["echo", "-n", "hi"])
    }

    func testLimitsAreAcceptedAtBoundaries() throws {
        let image = String(repeating: "a", count: ContainerRunPolicy.maxImageLength)
        let command = [String](repeating: String(repeating: "b", count: ContainerRunPolicy.maxCommandArgumentLength), count: ContainerRunPolicy.maxCommandCount)
        XCTAssertNoThrow(try ContainerRunPolicy.validate(request(image: image, command: command)))
    }

    // MARK: - Rejected requests

    func testRejectsUnsupportedVersion() {
        assertRejected(request(version: 5), expected: .unsupportedVersion(found: 5))
    }

    func testRejectsTTYOnVersion1() {
        assertRejected(request(version: 1, tty: true), expected: .ttyRequiresProtocolVersion2)
    }

    func testRejectsZeroTerminalSize() {
        assertRejected(
            request(version: 2, tty: true, columns: 0, rows: 24),
            expected: .invalidTerminalSize
        )
    }

    func testRejectsVersion4OptionsOnOlderProtocol() {
        assertRejected(
            request(version: 3, environment: ["MODE=production"]),
            expected: .runOptionsRequireProtocolVersion4
        )
    }

    func testRejectsInvalidRunConfiguration() {
        assertRejected(request(version: 4, environment: ["BAD-NAME=value"]), expected: .invalidEnvironment)
        assertRejected(request(version: 4, workingDirectory: "relative"), expected: .invalidWorkingDirectory)
        assertRejected(request(version: 4, user: "bad user"), expected: .invalidUser)
        assertRejected(request(version: 4, cpus: 0), expected: .invalidCPUs(min: 1, max: 64))
        assertRejected(
            request(version: 4, memoryBytes: 64 * 1024 * 1024),
            expected: .invalidMemory(min: ContainerRunPolicy.minimumMemoryBytes, max: ContainerRunPolicy.maximumMemoryBytes)
        )
    }

    func testRejectsUnsupportedOperation() {
        assertRejected(request(operation: "exec"), expected: .unsupportedOperation(found: "exec"))
    }

    func testRejectsEmptyImage() {
        assertRejected(request(image: ""), expected: .emptyImage)
    }

    func testRejectsImageStartingWithDash() {
        assertRejected(request(image: "-alpine"), expected: .imageStartsWithDash)
    }

    func testRejectsImageContainingNUL() {
        assertRejected(request(image: "alp\0ine"), expected: .imageContainsNUL)
    }

    func testRejectsImageContainingWhitespace() {
        assertRejected(request(image: "alp ine"), expected: .imageContainsWhitespaceOrControl)
        assertRejected(request(image: "alp\tine"), expected: .imageContainsWhitespaceOrControl)
        assertRejected(request(image: "alp\nine"), expected: .imageContainsWhitespaceOrControl)
        assertRejected(request(image: "alp\r\nine"), expected: .imageContainsWhitespaceOrControl)
    }

    func testRejectsImageContainingControlCharacters() {
        assertRejected(request(image: "alp\u{1B}ine"), expected: .imageContainsWhitespaceOrControl)
        assertRejected(request(image: "alp\u{7F}ine"), expected: .imageContainsWhitespaceOrControl)
    }

    func testRejectsImageTooLong() {
        let image = String(repeating: "a", count: ContainerRunPolicy.maxImageLength + 1)
        assertRejected(request(image: image), expected: .imageTooLong(max: ContainerRunPolicy.maxImageLength))
    }

    func testRejectsTooManyCommandArguments() {
        let command = [String](repeating: "x", count: ContainerRunPolicy.maxCommandCount + 1)
        assertRejected(request(command: command), expected: .tooManyCommandArguments(max: ContainerRunPolicy.maxCommandCount))
    }

    func testRejectsCommandArgumentTooLong() {
        let command = [String(repeating: "b", count: ContainerRunPolicy.maxCommandArgumentLength + 1)]
        assertRejected(request(command: command), expected: .commandArgumentTooLong(max: ContainerRunPolicy.maxCommandArgumentLength))
    }

    func testRejectsCommandArgumentContainingNUL() {
        assertRejected(request(command: ["echo", "a\0b"]), expected: .commandArgumentContainsNUL)
    }

    func testAcceptsReadWriteVolume() throws {
        let volume = ContainerRunVolume(guestPath: "/data", destination: "/data", readOnly: false)
        let run = try ContainerRunPolicy.validate(request(volumes: [volume]))
        XCTAssertEqual(run.volumes, [volume])
    }

    func testRejectsDuplicateVolumeDestination() {
        let volumes = [
            ContainerRunVolume(guestPath: "/one", destination: "/data", readOnly: true),
            ContainerRunVolume(guestPath: "/two", destination: "/data", readOnly: true),
        ]
        assertRejected(request(volumes: volumes), expected: .duplicateVolumeDestination("/data"))
    }

    func testRejectsVolumeDestinationTraversal() {
        let volume = ContainerRunVolume(guestPath: "/data", destination: "/mnt/../", readOnly: true)
        assertRejected(request(volumes: [volume]), expected: .invalidVolumeDestination)
    }

    // MARK: - argv construction

    func testContainerArguments() throws {
        let run = try ContainerRunPolicy.validate(request(image: "alpine", command: ["echo", "hello"]))
        let argv = run.containerArguments(vmHash: "12345", uniqueSuffix: "abcd1234")
        XCTAssertEqual(argv, ["run", "--cpus", "2", "--memory-bytes", "1073741824", "--id", "gv-12345-abcd1234", "--image", "alpine", "--", "echo", "hello"])
    }

    func testContainerArgumentsSanitizesNameComponents() throws {
        let run = try ContainerRunPolicy.validate(request(image: "alpine", command: []))
        let argv = run.containerArguments(vmHash: "Weird Hash!", uniqueSuffix: "ABCD1234")
        let idIndex = try XCTUnwrap(argv.firstIndex(of: "--id"))
        XCTAssertEqual(argv[idIndex + 1], "gv-weird-hash--abcd1234")
        // Executable path is never part of argv; the runner supplies it.
        XCTAssertFalse(argv.contains("ghostvm-container-runtime"))
    }

    func testContainerArgumentsCapsNameAtAppleLimit() throws {
        let run = try ContainerRunPolicy.validate(request(image: "alpine", command: []))
        let argv = run.containerArguments(
            vmHash: String(repeating: "h", count: 64),
            uniqueSuffix: String(repeating: "s", count: 32)
        )
        let idIndex = try XCTUnwrap(argv.firstIndex(of: "--id"))
        let name = argv[idIndex + 1]
        XCTAssertLessThanOrEqual(name.count, ContainerRunPolicy.maxContainerNameLength)
        XCTAssertEqual(ContainerRunPolicy.maxContainerNameLength, 63)
        XCTAssertTrue(name.hasPrefix("gv-"))
        // Truncation must not leave a trailing separator.
        XCTAssertTrue(name.last?.isLetter == true || name.last?.isNumber == true)
    }

    // MARK: - Name component sanitization

    func testSanitizedNameComponent() {
        XCTAssertEqual(ContainerRunPolicy.sanitizedNameComponent("12345"), "12345")
        XCTAssertEqual(ContainerRunPolicy.sanitizedNameComponent("My VM.Hash_1"), "my-vm.hash_1")
        XCTAssertEqual(ContainerRunPolicy.sanitizedNameComponent("--bad"), "bad")
        XCTAssertEqual(ContainerRunPolicy.sanitizedNameComponent(""), "x")
        XCTAssertEqual(ContainerRunPolicy.sanitizedNameComponent("!!!"), "x")
        XCTAssertEqual(ContainerRunPolicy.sanitizedNameComponent(String(repeating: "a", count: 100)).count, 32)
    }
}
