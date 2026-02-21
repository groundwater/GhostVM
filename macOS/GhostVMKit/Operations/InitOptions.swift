import Foundation

/// Options for initializing a new macOS VM.
public struct InitOptions {
    public var cpus: Int
    public var memoryGiB: UInt64
    public var diskGiB: UInt64
    public var restoreImagePath: String?
    public var sharedFolderPath: String?
    public var sharedFolderWritable: Bool
    public var sharedFolders: [SharedFolderConfig]
    public var networkConfig: NetworkConfig?

    public init(
        cpus: Int = 4,
        memoryGiB: UInt64 = 8,
        diskGiB: UInt64 = 64,
        restoreImagePath: String? = nil,
        sharedFolderPath: String? = nil,
        sharedFolderWritable: Bool = false,
        sharedFolders: [SharedFolderConfig] = [],
        networkConfig: NetworkConfig? = nil
    ) {
        self.cpus = cpus
        self.memoryGiB = memoryGiB
        self.diskGiB = diskGiB
        self.restoreImagePath = restoreImagePath
        self.sharedFolderPath = sharedFolderPath
        self.sharedFolderWritable = sharedFolderWritable
        self.sharedFolders = sharedFolders
        self.networkConfig = networkConfig
    }
}
