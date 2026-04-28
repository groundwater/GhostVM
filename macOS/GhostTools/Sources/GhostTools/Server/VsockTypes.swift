import Foundation

/// AF_VSOCK socket family constant (40 on macOS)
let AF_VSOCK: Int32 = 40

/// VMADDR_CID_ANY - accept connections from any CID
let VMADDR_CID_ANY: UInt32 = 0xFFFFFFFF

/// sockaddr_vm structure for vsock addressing
/// Must match the kernel's sockaddr_vm layout
struct sockaddr_vm {
    var svm_len: UInt8
    var svm_family: UInt8
    var svm_reserved1: UInt16
    var svm_port: UInt32
    var svm_cid: UInt32
    var svm_zero: (UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 0)

    init(port: UInt32, cid: UInt32 = VMADDR_CID_ANY) {
        self.svm_len = UInt8(MemoryLayout<sockaddr_vm>.size)
        self.svm_family = UInt8(AF_VSOCK)
        self.svm_reserved1 = 0
        self.svm_port = port
        self.svm_cid = cid
    }
}

/// Errors that can occur in vsock servers
enum VsockServerError: Error, LocalizedError {
    case socketCreationFailed(Int32)
    case bindFailed(Int32)
    case listenFailed(Int32)
    case acceptFailed(Int32)
    case readFailed(Int32)
    case writeFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .socketCreationFailed(let errno):
            return "Failed to create socket: errno \(errno)"
        case .bindFailed(let errno):
            return "Failed to bind socket: errno \(errno)"
        case .listenFailed(let errno):
            return "Failed to listen: errno \(errno)"
        case .acceptFailed(let errno):
            return "Failed to accept connection: errno \(errno)"
        case .readFailed(let errno):
            return "Failed to read from socket: errno \(errno)"
        case .writeFailed(let errno):
            return "Failed to write to socket: errno \(errno)"
        }
    }
}
