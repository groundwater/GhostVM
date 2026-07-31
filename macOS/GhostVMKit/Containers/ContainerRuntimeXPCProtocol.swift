import Foundation

/// Raw XPC protocol shared by GhostVMHelper and its embedded container runtime.
public enum ContainerRuntimeXPCProtocol {
    public static let serviceName = "org.ghostvm.ghostvm.helper"
    public static let version: UInt64 = 1

    public enum Operation {
        public static let ping = "ping"
        public static let run = "run"
        public static let cancel = "cancel"
        public static let resize = "resize"
        public static let shutdown = "shutdown"
        public static let ready = "ready"
        public static let exit = "exit"
    }

    public enum Key {
        public static let operation = "operation"
        public static let version = "version"
        public static let runIdentifier = "runIdentifier"
        public static let arguments = "arguments"
        public static let networkSerialization = "networkSerialization"
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
