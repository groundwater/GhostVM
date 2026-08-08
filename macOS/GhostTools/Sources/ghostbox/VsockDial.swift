import Foundation

/// sockaddr_vm structure for AF_VSOCK addressing.
/// Must match the kernel's sockaddr_vm layout exactly (12 bytes on Darwin).
struct sockaddr_vm {
    var svm_len: UInt8
    var svm_family: UInt8
    var svm_reserved1: UInt16
    var svm_port: UInt32
    var svm_cid: UInt32

    init(port: UInt32, cid: UInt32) {
        self.svm_len = UInt8(MemoryLayout<sockaddr_vm>.size)
        self.svm_family = UInt8(AF_VSOCK)
        self.svm_reserved1 = 0
        self.svm_port = port
        self.svm_cid = cid
    }
}

enum VsockDialError: Error, CustomStringConvertible {
    case socketCreationFailed(errno: Int32)
    case connectFailed(errno: Int32)

    var description: String {
        switch self {
        case .socketCreationFailed(let err):
            return "socket(AF_VSOCK) failed: errno \(err) (\(String(cString: strerror(err))))"
        case .connectFailed(let err):
            return "connect() failed: errno \(err) (\(String(cString: strerror(err))))"
        }
    }
}

/// Dial the host via AF_VSOCK, returning a blocking file descriptor.
/// Uses `VMADDR_CID_HOST` (2) to reach the VM host.
func vsockDialHost(port: UInt32) throws -> Int32 {
    let fd = socket(AF_VSOCK, SOCK_STREAM, 0)
    guard fd >= 0 else {
        throw VsockDialError.socketCreationFailed(errno: errno)
    }

    var addr = sockaddr_vm(port: port, cid: VMADDR_CID_HOST)

    let rc = withUnsafePointer(to: &addr) { addrPtr in
        addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
            Darwin.connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_vm>.size))
        }
    }

    guard rc == 0 else {
        let err = errno
        Darwin.close(fd)
        throw VsockDialError.connectFailed(errno: err)
    }

    return fd
}

/// Write all bytes to a blocking fd, retrying on EINTR.
@discardableResult
func writeAll(fd: Int32, _ data: Data) -> Bool {
    if data.isEmpty { return true }
    return data.withUnsafeBytes { rawBuffer -> Bool in
        guard let base = rawBuffer.baseAddress else { return false }
        var offset = 0
        while offset < data.count {
            let written = Darwin.write(fd, base.advanced(by: offset), data.count - offset)
            if written < 0 {
                if errno == EINTR { continue }
                return false
            }
            if written == 0 { return false }
            offset += written
        }
        return true
    }
}

/// Write a byte sequence to a fd, retrying on EINTR.
@discardableResult
func writeBytes(fd: Int32, _ bytes: [UInt8]) -> Bool {
    return writeAll(fd: fd, Data(bytes))
}
