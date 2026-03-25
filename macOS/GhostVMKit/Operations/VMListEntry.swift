import Foundation

/// Represents a VM in the list with its current state.
public struct VMListEntry {
    public let name: String
    public let bundleURL: URL
    public let installed: Bool
    public let runningPID: pid_t?
    public let managedInProcess: Bool
    public let cpuCount: Int
    public let memoryBytes: UInt64
    public let diskBytes: UInt64
    public let lastInstallVersion: String?
    public let isSuspended: Bool

    public var isRunning: Bool {
        return managedInProcess || runningPID != nil
    }

    public var statusDescription: String {
        if managedInProcess {
            if let pid = runningPID {
                return "Running (managed by app, PID \(pid))"
            }
            return "Running (managed by app)"
        }
        if let pid = runningPID {
            return "Running (PID \(pid))"
        }
        if !installed {
            return "Not Installed"
        }
        if isSuspended {
            return "Suspended"
        }
        return "Stopped"
    }

    public init(
        name: String,
        bundleURL: URL,
        installed: Bool,
        runningPID: pid_t?,
        managedInProcess: Bool,
        cpuCount: Int,
        memoryBytes: UInt64,
        diskBytes: UInt64,
        lastInstallVersion: String? = nil,
        isSuspended: Bool = false
    ) {
        self.name = name
        self.bundleURL = bundleURL
        self.installed = installed
        self.runningPID = runningPID
        self.managedInProcess = managedInProcess
        self.cpuCount = cpuCount
        self.memoryBytes = memoryBytes
        self.diskBytes = diskBytes
        self.lastInstallVersion = lastInstallVersion
        self.isSuspended = isSuspended
    }

    public func withManagedInProcess(_ value: Bool) -> VMListEntry {
        return VMListEntry(
            name: name,
            bundleURL: bundleURL,
            installed: installed,
            runningPID: runningPID,
            managedInProcess: value,
            cpuCount: cpuCount,
            memoryBytes: memoryBytes,
            diskBytes: diskBytes,
            lastInstallVersion: lastInstallVersion,
            isSuspended: isSuspended
        )
    }
}
