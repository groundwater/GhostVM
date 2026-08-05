@testable import ghostbox
import Darwin
import Foundation
import XCTest

final class PortForwarderTests: XCTestCase {
    func testForwardsTCPInBothDirections() throws {
        let (targetListener, targetPort) = try makeListener(port: 0)
        defer { Darwin.close(targetListener) }

        let (reservation, publishedPort) = try makeListener(port: 0)
        Darwin.close(reservation)
        let forwarder = try PublishedPortForwarder(PublishedPort(
            hostAddress: "127.0.0.1",
            hostPort: publishedPort,
            containerPort: targetPort
        ))
        defer { forwarder.stop() }
        forwarder.start(targetAddress: "127.0.0.1")

        let served = expectation(description: "target served relayed request")
        DispatchQueue.global(qos: .userInitiated).async {
            let connection = Darwin.accept(targetListener, nil, nil)
            guard connection >= 0 else {
                served.fulfill()
                return
            }
            defer { Darwin.close(connection) }
            var request = [UInt8](repeating: 0, count: 4)
            if Darwin.read(connection, &request, request.count) == 4, Data(request) == Data("ping".utf8) {
                _ = writeBytes(fd: connection, Array("pong".utf8))
            }
            served.fulfill()
        }

        let client = try connect(port: publishedPort)
        defer { Darwin.close(client) }
        XCTAssertTrue(writeBytes(fd: client, Array("ping".utf8)))
        var response = [UInt8](repeating: 0, count: 4)
        XCTAssertEqual(Darwin.read(client, &response, response.count), 4)
        XCTAssertEqual(Data(response), Data("pong".utf8))
        wait(for: [served], timeout: 2)
    }

    private func makeListener(port: UInt16) throws -> (Int32, UInt16) {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw PortForwardError.socket(operation: "socket", code: errno) }
        do {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard result == 0, Darwin.listen(fd, 4) == 0 else {
                throw PortForwardError.socket(operation: "bind/listen", code: errno)
            }
            var bound = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let lookup = withUnsafeMutablePointer(to: &bound) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.getsockname(fd, $0, &length)
                }
            }
            guard lookup == 0 else { throw PortForwardError.socket(operation: "getsockname", code: errno) }
            return (fd, UInt16(bigEndian: bound.sin_port))
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    private func connect(port: UInt16) throws -> Int32 {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw PortForwardError.socket(operation: "socket", code: errno) }
        do {
            var timeout = timeval(tv_sec: 2, tv_usec: 0)
            _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard result == 0 else { throw PortForwardError.socket(operation: "connect", code: errno) }
            return fd
        } catch {
            Darwin.close(fd)
            throw error
        }
    }
}
