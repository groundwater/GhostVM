@testable import ghost_container
import XCTest

final class LineReaderTests: XCTestCase {

    private func makeSocketPair() throws -> (Int32, Int32) {
        var fds = [Int32](repeating: -1, count: 2)
        let rc = socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
        XCTAssertEqual(rc, 0, "socketpair failed: errno=\(errno)")
        guard rc == 0 else {
            throw LineReaderError.ioError(errno: errno, op: "socketpair")
        }
        return (fds[0], fds[1])
    }

    func testReadSingleLine() throws {
        let (fdA, fdB) = try makeSocketPair()
        defer {
            Darwin.close(fdA)
            Darwin.close(fdB)
        }

        _ = writeAll(fd: fdA, Data("hello\n".utf8))
        let reader = LineReader(fd: fdB)
        let line = try reader.readLine()
        XCTAssertEqual(line, Data("hello".utf8))
    }

    func testReadMultipleLines() throws {
        let (fdA, fdB) = try makeSocketPair()
        defer {
            Darwin.close(fdA)
            Darwin.close(fdB)
        }

        _ = writeAll(fd: fdA, Data("line1\nline2\nline3\n".utf8))
        let reader = LineReader(fd: fdB)

        XCTAssertEqual(try reader.readLine(), Data("line1".utf8))
        XCTAssertEqual(try reader.readLine(), Data("line2".utf8))
        XCTAssertEqual(try reader.readLine(), Data("line3".utf8))
    }

    func testReadLineAcrossMultipleReads() throws {
        let (fdA, fdB) = try makeSocketPair()
        defer {
            Darwin.close(fdA)
            Darwin.close(fdB)
        }

        let reader = LineReader(fd: fdB)

        _ = writeAll(fd: fdA, Data("partial".utf8))
        // Give the kernel time to deliver
        usleep(10_000)

        // Write the rest with newline
        _ = writeAll(fd: fdA, Data("-line\n".utf8))

        let line = try reader.readLine()
        XCTAssertEqual(line, Data("partial-line".utf8))
    }

    func testReadLineTrailingDataWithoutNewline() throws {
        let (fdA, fdB) = try makeSocketPair()
        defer {
            Darwin.close(fdA)
            Darwin.close(fdB)
        }

        _ = writeAll(fd: fdA, Data("first\ntrailing".utf8))
        let reader = LineReader(fd: fdB)

        XCTAssertEqual(try reader.readLine(), Data("first".utf8))

        // Close write end → EOF on read end
        Darwin.close(fdA)

        let line = try reader.readLine()
        XCTAssertEqual(line, Data("trailing".utf8))

        // Should now get nil
        let next = try reader.readLine()
        XCTAssertNil(next)
    }

    func testReturnsNilOnCleanEOF() throws {
        let (fdA, fdB) = try makeSocketPair()
        Darwin.close(fdA)

        let reader = LineReader(fd: fdB)
        let line = try reader.readLine()
        XCTAssertNil(line)

        Darwin.close(fdB)
    }

    func testThrowsOnLineTooLong() throws {
        let (fdA, fdB) = try makeSocketPair()
        defer {
            Darwin.close(fdA)
            Darwin.close(fdB)
        }

        // Write a long line without newline
        let big = Data((0..<100).map { _ in UInt8(0x61) }) // 100 'a's
        _ = writeAll(fd: fdA, big)

        let reader = LineReader(fd: fdB, maxLineBytes: 10)

        do {
            _ = try reader.readLine()
            XCTFail("Expected lineTooLong error")
        } catch LineReaderError.lineTooLong(let max) {
            XCTAssertEqual(max, 10)
        } catch {
            XCTFail("Expected lineTooLong, got \(error)")
        }
    }

    func testEmptyLine() throws {
        let (fdA, fdB) = try makeSocketPair()
        defer {
            Darwin.close(fdA)
            Darwin.close(fdB)
        }

        _ = writeAll(fd: fdA, Data("\n\n\n".utf8))
        let reader = LineReader(fd: fdB)

        XCTAssertEqual(try reader.readLine(), Data())
        XCTAssertEqual(try reader.readLine(), Data())
        XCTAssertEqual(try reader.readLine(), Data())
    }
}
