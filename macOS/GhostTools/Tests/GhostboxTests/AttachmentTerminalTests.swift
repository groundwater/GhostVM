@testable import ghostbox
import XCTest

final class AttachmentTerminalTests: XCTestCase {
    func testSuspendResumeAndFinishRestoreTerminalMode() throws {
        let master = posix_openpt(O_RDWR | O_NOCTTY)
        XCTAssertGreaterThanOrEqual(master, 0)
        guard master >= 0 else { return }
        defer { Darwin.close(master) }
        XCTAssertEqual(grantpt(master), 0)
        XCTAssertEqual(unlockpt(master), 0)

        let slave = Darwin.open(ptsname(master), O_RDWR | O_NOCTTY)
        XCTAssertGreaterThanOrEqual(slave, 0)
        guard slave >= 0 else { return }
        defer { Darwin.close(slave) }

        let terminal = try RawAttachmentTerminal(fd: slave)
        try terminal.enterRawMode()
        assertRaw(slave)

        XCTAssertTrue(terminal.suspend())
        assertCanonical(slave)

        XCTAssertTrue(terminal.resume())
        assertRaw(slave)

        terminal.finish()
        assertCanonical(slave)
        XCTAssertFalse(terminal.resume())
        assertCanonical(slave)
    }

    private func assertRaw(_ fd: Int32, file: StaticString = #filePath, line: UInt = #line) {
        var attributes = termios()
        XCTAssertEqual(tcgetattr(fd, &attributes), 0, file: file, line: line)
        XCTAssertEqual(attributes.c_lflag & tcflag_t(ICANON | ECHO), 0, file: file, line: line)
    }

    private func assertCanonical(_ fd: Int32, file: StaticString = #filePath, line: UInt = #line) {
        var attributes = termios()
        XCTAssertEqual(tcgetattr(fd, &attributes), 0, file: file, line: line)
        XCTAssertNotEqual(attributes.c_lflag & tcflag_t(ICANON), 0, file: file, line: line)
    }
}
