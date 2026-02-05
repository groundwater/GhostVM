import Foundation

/// Manages copying and lifecycle of helper app bundles for individual VMs.
///
/// The helper app is a signed bundle that runs VMs independently with their own Dock icon.
/// We copy it without modification to preserve the code signature.
/// Custom icons are loaded at runtime by the helper via NSDockTile.
public final class VMHelperBundleManager {
    private let fileManager = FileManager.default

    public init() {}

    /// Copies the signed helper app to the VM bundle.
    ///
    /// The helper is copied as-is to preserve its code signature.
    /// Custom icons are loaded at runtime by the helper from the VM bundle.
    ///
    /// - Parameters:
    ///   - vmBundleURL: URL of the VM bundle (.ghostvm)
    ///   - sourceHelperAppURL: URL to the signed GhostVMHelper.app in the main app bundle
    /// - Returns: URL to the copied helper app bundle
    public func copyHelperApp(vmBundleURL: URL, sourceHelperAppURL: URL) throws -> URL {
        let layout = VMFileLayout(bundleURL: vmBundleURL)
        let destHelperURL = layout.helperDirectoryURL.appendingPathComponent("GhostVMHelper.app")

        // Ensure helper directory exists
        try fileManager.createDirectory(at: layout.helperDirectoryURL, withIntermediateDirectories: true)

        // Remove existing helper if present
        if fileManager.fileExists(atPath: destHelperURL.path) {
            try fileManager.removeItem(at: destHelperURL)
        }

        // Copy the entire signed app bundle (preserves signature)
        try fileManager.copyItem(at: sourceHelperAppURL, to: destHelperURL)

        return destHelperURL
    }

    /// Returns the URL to the helper app for a VM, or nil if not present.
    public func helperAppURL(vmBundleURL: URL) -> URL? {
        let layout = VMFileLayout(bundleURL: vmBundleURL)
        let helperURL = layout.helperDirectoryURL.appendingPathComponent("GhostVMHelper.app")
        return fileManager.fileExists(atPath: helperURL.path) ? helperURL : nil
    }

    /// Checks if a helper app exists for the VM.
    public func helperAppExists(vmBundleURL: URL) -> Bool {
        return helperAppURL(vmBundleURL: vmBundleURL) != nil
    }

    /// Removes the helper app from a VM bundle.
    public func removeHelperApp(vmBundleURL: URL) throws {
        let layout = VMFileLayout(bundleURL: vmBundleURL)
        let helperURL = layout.helperDirectoryURL.appendingPathComponent("GhostVMHelper.app")

        if fileManager.fileExists(atPath: helperURL.path) {
            try fileManager.removeItem(at: helperURL)
        }

        // Remove helper directory if empty
        if fileManager.fileExists(atPath: layout.helperDirectoryURL.path) {
            let contents = try? fileManager.contentsOfDirectory(atPath: layout.helperDirectoryURL.path)
            if contents?.isEmpty == true {
                try? fileManager.removeItem(at: layout.helperDirectoryURL)
            }
        }
    }

    /// Finds the GhostVMHelper.app in the main app bundle.
    /// Returns nil if not found.
    public static func findHelperInMainBundle() -> URL? {
        guard let mainBundleURL = Bundle.main.bundleURL as URL? else { return nil }

        // Helper is embedded at Contents/PlugIns/Helpers/GhostVMHelper.app
        let helperURL = mainBundleURL
            .appendingPathComponent("Contents")
            .appendingPathComponent("PlugIns")
            .appendingPathComponent("Helpers")
            .appendingPathComponent("GhostVMHelper.app")

        return FileManager.default.fileExists(atPath: helperURL.path) ? helperURL : nil
    }
}
