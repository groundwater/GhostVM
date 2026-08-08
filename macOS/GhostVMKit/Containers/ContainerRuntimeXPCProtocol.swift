import Foundation

/// Raw XPC protocol shared by GhostVMHelper and its embedded container runtime.
public enum ContainerRuntimeXPCProtocol {
    public static let serviceName = "org.ghostvm.ghostvm.helper"
    public static let version: UInt64 = 5
    public static let builderImage = "ghcr.io/apple/container-builder-shim/builder:0.13.0"

    public enum Operation {
        public static let ping = "ping"
        public static let build = "build"
        public static let cancel = "cancel"
        public static let resize = "resize"
        public static let invoke = "invoke"
        public static let attach = "attach"
        public static let shutdown = "shutdown"
        public static let ready = "ready"
        public static let exit = "exit"
    }

    public enum Key {
        public static let operation = "operation"
        public static let version = "version"
        public static let runIdentifier = "runIdentifier"
        public static let arguments = "arguments"
        public static let payload = "payload"
        public static let descriptor = "descriptor"
        public static let networkSerialization = "networkSerialization"
        public static let ipv4Subnet = "ipv4Subnet"
        public static let volumeRoot = "volumeRoot"
        public static let imageRoot = "imageRoot"
        public static let ipv4Address = "ipv4Address"
        public static let ipv4Gateway = "ipv4Gateway"
        public static let macAddress = "macAddress"
        public static let mtu = "mtu"
        public static let columns = "columns"
        public static let rows = "rows"
        public static let stdin = "stdin"
        public static let stdout = "stdout"
        public static let stderr = "stderr"
        public static let exitCode = "exitCode"
        public static let error = "error"
        public static let ok = "ok"
    }
}
