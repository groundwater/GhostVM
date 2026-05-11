// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "macos-vsock-write-loss",
    platforms: [.macOS(.v14)],
    targets: [
        // Runs INSIDE a macOS guest VM. Listens on AF_VSOCK, writes N bytes
        // using non-blocking I/O + kqueue (EVFILT_WRITE), and reports stats.
        .executableTarget(name: "VsockSender", path: "Sources/VsockSender"),
        // Runs ON the macOS host. Uses Virtualization.framework
        // (VZVirtioSocketDevice) to connect to a running VM and reads bytes.
        .executableTarget(name: "VsockReceiver", path: "Sources/VsockReceiver"),
    ]
)
