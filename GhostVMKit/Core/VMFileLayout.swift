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
    public var efiVariableStoreURL: URL { bundleURL.appendingPathComponent("NVRAM.bin") }

    // MARK: - Helper App Bundle

    /// Directory containing the helper app bundle
    public var helperDirectoryURL: URL { bundleURL.appendingPathComponent("Helper") }

    /// The helper app bundle URL (computed from VM name)
    public func helperAppURL(vmName: String) -> URL {
        let sanitizedName = vmName.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return helperDirectoryURL.appendingPathComponent("GhostVM-\(sanitizedName).app")
    }

    /// Custom icon stored in the VM bundle (PNG format)
    public var customIconURL: URL { bundleURL.appendingPathComponent("icon.png") }

    public func ensureBundleDirectory() throws {
        if !fileManager.fileExists(atPath: bundleURL.path) {
            try fileManager.createDirectory(at: bundleURL, withIntermediateDirectories: true, attributes: nil)
        }
    }
}
