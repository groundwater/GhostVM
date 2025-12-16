import Foundation

/// Provides URLs for all files within a VM bundle.
public final class VMFileLayout {
    private let fileManager = FileManager.default
    public let bundleURL: URL

    public init(bundleURL: URL) {
        self.bundleURL = bundleURL
    }

    public var configURL: URL { bundleURL.appendingPathComponent("config.json") }
    public var diskURL: URL { bundleURL.appendingPathComponent("disk.img") }
    public var hardwareModelURL: URL { bundleURL.appendingPathComponent("HardwareModel.bin") }
    public var machineIdentifierURL: URL { bundleURL.appendingPathComponent("MachineIdentifier.bin") }
    public var auxiliaryStorageURL: URL { bundleURL.appendingPathComponent("AuxiliaryStorage.bin") }
    public var pidFileURL: URL { bundleURL.appendingPathComponent("vmctl.pid") }
    public var snapshotsDirectoryURL: URL { bundleURL.appendingPathComponent("Snapshots") }
    public var suspendStateURL: URL { bundleURL.appendingPathComponent("suspend.vzvmsave") }

    public func ensureBundleDirectory() throws {
        if !fileManager.fileExists(atPath: bundleURL.path) {
            try fileManager.createDirectory(at: bundleURL, withIntermediateDirectories: true, attributes: nil)
        }
    }
}
