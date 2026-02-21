import XCTest
@testable import GhostTools

final class AsyncVSockIOTests: XCTestCase {
    private func makeSocketPair() throws -> (Int32, Int32) {
        var fds = [Int32](repeating: -1, count: 2)
        let rc = socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
        XCTAssertEqual(rc, 0, "socketpair failed: errno=\(errno)")
        guard rc == 0 else {
            throw AsyncVSockIOError.syscall(op: "socketpair", errno: errno)
        }
        return (fds[0], fds[1])
    }

    func testWriteAllAndRead() async throws {
        let (fdA, fdB) = try makeSocketPair()
        let ioA = AsyncVSockIO(fd: fdA, ownsFD: true)
        let ioB = AsyncVSockIO(fd: fdB, ownsFD: true)

        try await ioA.writeAll(Data("hello".utf8))
        let data = try await ioB.read(maxBytes: 32)
        XCTAssertEqual(String(data: data ?? Data(), encoding: .utf8), "hello")

        ioA.close()
        ioB.close()
    }

    func testReadExactlyThrowsOnEarlyEOF() async throws {
        let (fdA, fdB) = try makeSocketPair()
        let ioA = AsyncVSockIO(fd: fdA, ownsFD: true)
        let ioB = AsyncVSockIO(fd: fdB, ownsFD: true)

        try await ioA.writeAll(Data([1, 2, 3]))
        ioA.close()

        do {
            _ = try await ioB.readExactly(4)
            XCTFail("Expected eofBeforeExpected")
        } catch let AsyncVSockIOError.eofBeforeExpected(expected, received) {
            XCTAssertEqual(expected, 4)
            XCTAssertEqual(received, 3)
        }

        ioB.close()
    }

    func testReadReturnsNilOnEOF() async throws {
        let (fdA, fdB) = try makeSocketPair()
        let ioA = AsyncVSockIO(fd: fdA, ownsFD: true)
        let ioB = AsyncVSockIO(fd: fdB, ownsFD: true)

        ioA.close()
        let read = try await ioB.read(maxBytes: 16)
        XCTAssertNil(read)

        ioB.close()
    }

    func testCancellationDuringRead() async throws {
        let (fdA, fdB) = try makeSocketPair()
        let ioA = AsyncVSockIO(fd: fdA, ownsFD: true)
        let ioB = AsyncVSockIO(fd: fdB, ownsFD: true)

        let task = Task {
            try await ioB.read(maxBytes: 16)
        }

        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch AsyncVSockIOError.cancelled {
            // expected
        }

        ioA.close()
        ioB.close()
    }

    func testCloseIsIdempotent() async throws {
        let (fdA, fdB) = try makeSocketPair()
        let ioA = AsyncVSockIO(fd: fdA, ownsFD: true)
        let ioB = AsyncVSockIO(fd: fdB, ownsFD: true)

        ioA.close()
        ioA.close()

        do {
            try await ioA.writeAll(Data("x".utf8))
            XCTFail("Expected closed error")
        } catch AsyncVSockIOError.closed {
            // expected
        }

        ioB.close()
    }

    func testPipeBidirectionalCopiesBothDirections() async throws {
        let (fdL1, fdL2) = try makeSocketPair()
        let (fdR1, fdR2) = try makeSocketPair()

        let bridgeLeft = AsyncVSockIO(fd: fdL2, ownsFD: true)
        let bridgeRight = AsyncVSockIO(fd: fdR2, ownsFD: true)
        let clientLeft = AsyncVSockIO(fd: fdL1, ownsFD: true)
        let clientRight = AsyncVSockIO(fd: fdR1, ownsFD: true)

        let bridgeTask = Task {
            try await pipeBidirectional(bridgeLeft, bridgeRight)
        }

        try await clientLeft.writeAll(Data("left->right".utf8))
        let fromLeft = try await clientRight.readExactly("left->right".utf8.count)
        XCTAssertEqual(String(data: fromLeft, encoding: .utf8), "left->right")

        try await clientRight.writeAll(Data("right->left".utf8))
        let fromRight = try await clientLeft.readExactly("right->left".utf8.count)
        XCTAssertEqual(String(data: fromRight, encoding: .utf8), "right->left")

        clientLeft.close()
        clientRight.close()

        _ = try? await bridgeTask.value
        bridgeLeft.close()
        bridgeRight.close()
    }
}
