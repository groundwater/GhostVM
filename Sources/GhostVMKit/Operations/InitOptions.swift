import Foundation

/// Options for initializing a new VM.
public struct InitOptions {
    public var cpus: Int
    public var memoryGiB: UInt64
    public var diskGiB: UInt64
    public var restoreImagePath: String?
    public var sharedFolderPath: String?
    public var sharedFolderWritable: Bool

    public init(
        cpus: Int = 4,
        memoryGiB: UInt64 = 8,
        diskGiB: UInt64 = 64,
        restoreImagePath: String? = nil,
        sharedFolderPath: String? = nil,
        sharedFolderWritable: Bool = false
    ) {
        self.cpus = cpus
        self.memoryGiB = memoryGiB
        self.diskGiB = diskGiB
        self.restoreImagePath = restoreImagePath
        self.sharedFolderPath = sharedFolderPath
        self.sharedFolderWritable = sharedFolderWritable
    }
}
