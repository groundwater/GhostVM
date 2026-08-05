@testable import ghostbox
import XCTest

final class VsockDialTests: XCTestCase {

    /// The Darwin sockaddr_vm layout must be exactly 12 bytes (no padding/zero
    /// field): svm_len(1) + svm_family(1) + svm_reserved1(2) + svm_port(4) + svm_cid(4).
    func testSockaddrVmSizeIs12Bytes() {
        XCTAssertEqual(MemoryLayout<ghostbox.sockaddr_vm>.size, 12)
        XCTAssertEqual(MemoryLayout<ghostbox.sockaddr_vm>.stride, 12)
    }

    func testSockaddrVmFieldsInitialized() {
        let addr = ghostbox.sockaddr_vm(port: 5004, cid: 2)
        XCTAssertEqual(addr.svm_len, 12)
        XCTAssertEqual(addr.svm_family, UInt8(ghostbox.AF_VSOCK))
        XCTAssertEqual(addr.svm_reserved1, 0)
        XCTAssertEqual(addr.svm_port, 5004)
        XCTAssertEqual(addr.svm_cid, 2)
    }

    // MARK: - writeAll / writeBytes / write helpers return Bool

    private func makeSocketPair() throws -> (Int32, Int32) {
        var fds = [Int32](repeating: -1, count: 2)
        let rc = socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
        XCTAssertEqual(rc, 0, "socketpair failed: errno=\(errno)")
        guard rc == 0 else {
            throw LineReaderError.ioError(errno: errno, op: "socketpair")
        }
        return (fds[0], fds[1])
    }

    func testWriteAllReturnsTrueOnSuccess() throws {
        let (fdA, fdB) = try makeSocketPair()
        defer {
            Darwin.close(fdA)
            Darwin.close(fdB)
        }
        XCTAssertTrue(writeAll(fd: fdA, Data("hello".utf8)))
    }

    func testWriteAllReturnsTrueForEmptyData() throws {
        let (fdA, fdB) = try makeSocketPair()
        defer {
            Darwin.close(fdA)
            Darwin.close(fdB)
        }
        XCTAssertTrue(writeAll(fd: fdA, Data()))
    }

    func testWriteAllReturnsFalseOnClosedFd() throws {
        let (fdA, fdB) = try makeSocketPair()
        Darwin.close(fdA)
        Darwin.close(fdB)
        // Writing to a closed fd fails.
        XCTAssertFalse(writeAll(fd: fdA, Data("nope".utf8)))
    }

    func testWriteBytesReturnsBool() throws {
        let (fdA, fdB) = try makeSocketPair()
        defer {
            Darwin.close(fdA)
            Darwin.close(fdB)
        }
        XCTAssertTrue(writeBytes(fd: fdA, [0x68, 0x69]))
    }

    func testForwardStdinHalfClosesOnlyWriteSide() throws {
        let (fdA, fdB) = try makeSocketPair()
        defer {
            Darwin.close(fdA)
            Darwin.close(fdB)
        }
        let input = Pipe()
        try input.fileHandleForWriting.write(contentsOf: Data("hello".utf8))
        try input.fileHandleForWriting.close()

        let writer = ContainerInputWriter(fd: fdA)
        forwardStdin(
            inputFD: input.fileHandleForReading.fileDescriptor,
            writer: writer,
            keepWriteSideOpen: false
        )

        let reader = LineReader(fd: fdB, maxLineBytes: 64 * 1024)
        let stdinLine = try XCTUnwrap(reader.readLine())
        let closeLine = try XCTUnwrap(reader.readLine())
        let stdinFrame = try JSONDecoder().decode(HostContainerInputFrame.self, from: stdinLine)
        let closeFrame = try JSONDecoder().decode(HostContainerInputFrame.self, from: closeLine)
        XCTAssertEqual(stdinFrame.type, .stdin)
        XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(stdinFrame.data)), Data("hello".utf8))
        XCTAssertEqual(closeFrame.type, .stdinClose)
        XCTAssertNil(try reader.readLine())

        XCTAssertTrue(writeAll(fd: fdB, Data("response".utf8)))
        var responseBuffer = [UInt8](repeating: 0, count: 8)
        XCTAssertEqual(Darwin.read(fdA, &responseBuffer, responseBuffer.count), 8)
        XCTAssertEqual(Data(responseBuffer), Data("response".utf8))
    }
}
