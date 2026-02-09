import Foundation

/// Manages copying and lifecycle of helper app bundles for individual VMs.
///
/// The helper app is a signed bundle that runs VMs independently with their own Dock icon.
/// The bundle is copied unmodified (preserving the code signature), then renamed to match
/// the VM name so macOS shows it correctly in the Dock and CMD+TAB.
public final class VMHelperBundleManager {
    private let fileManager = FileManager.default

    public init() {}

    /// Copies the helper app to the VM bundle unmodified, then renames the .app folder
    /// to the VM name so macOS shows it correctly in the Dock and CMD+TAB.
    ///
    /// - Parameters:
    ///   - vmBundleURL: URL of the VM bundle (.ghostvm)
    ///   - sourceHelperAppURL: URL to the signed GhostVMHelper.app in the main app bundle
    /// - Returns: URL to the copied helper app bundle
    public func copyHelperApp(vmBundleURL: URL, sourceHelperAppURL: URL) throws -> URL {
        let layout = VMFileLayout(bundleURL: vmBundleURL)
        let vmName = vmBundleURL.deletingPathExtension().lastPathComponent
        let finalHelperURL = layout.helperAppURL(vmName: vmName)
        let tempHelperURL = layout.helperDirectoryURL.appendingPathComponent("GhostVMHelper.app")

        // Ensure helper directory exists
        try fileManager.createDirectory(at: layout.helperDirectoryURL, withIntermediateDirectories: true)

        // Remove existing helpers (both new-style and legacy)
        for url in [finalHelperURL, tempHelperURL] {
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
        }

        // Copy the entire app bundle unmodified (preserves code signature)
        try fileManager.copyItem(at: sourceHelperAppURL, to: tempHelperURL)

        // Copy GhostTools.dmg into the helper's Resources so the helper process can find it
        copyGhostToolsDMG(into: tempHelperURL)

        // Rename to VM-named .app folder for Dock/CMD+TAB label
        try fileManager.moveItem(at: tempHelperURL, to: finalHelperURL)

        return finalHelperURL
    }

    /// Returns the URL to the helper app for a VM, or nil if not present.
    public func helperAppURL(vmBundleURL: URL) -> URL? {
        let layout = VMFileLayout(bundleURL: vmBundleURL)
        let vmName = vmBundleURL.deletingPathExtension().lastPathComponent

        // Check for VM-named helper first
        let namedURL = layout.helperAppURL(vmName: vmName)
        if fileManager.fileExists(atPath: namedURL.path) {
            return namedURL
        }

        // Fall back to legacy GhostVMHelper.app
        let legacyURL = layout.helperDirectoryURL.appendingPathComponent("GhostVMHelper.app")
        if fileManager.fileExists(atPath: legacyURL.path) {
            return legacyURL
        }

        return nil
    }

    /// Checks if a helper app exists for the VM.
    public func helperAppExists(vmBundleURL: URL) -> Bool {
        return helperAppURL(vmBundleURL: vmBundleURL) != nil
    }

    /// Removes the helper app from a VM bundle.
    public func removeHelperApp(vmBundleURL: URL) throws {
        let layout = VMFileLayout(bundleURL: vmBundleURL)
        let vmName = vmBundleURL.deletingPathExtension().lastPathComponent

        // Remove both VM-named and legacy helpers
        let namedURL = layout.helperAppURL(vmName: vmName)
        let legacyURL = layout.helperDirectoryURL.appendingPathComponent("GhostVMHelper.app")

        for url in [namedURL, legacyURL] {
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
        }

        // Remove helper directory if empty
        if fileManager.fileExists(atPath: layout.helperDirectoryURL.path) {
            let contents = try? fileManager.contentsOfDirectory(atPath: layout.helperDirectoryURL.path)
            if contents?.isEmpty == true {
                try? fileManager.removeItem(at: layout.helperDirectoryURL)
            }
        }
    }

    // MARK: - Private helpers

    /// Copies GhostTools.dmg from the main GhostVM.app bundle into the helper app's Resources.
    /// Fails silently if the DMG is not found (it's optional in project.yml).
    private func copyGhostToolsDMG(into helperAppURL: URL) {
        guard let dmgURL = Bundle.main.url(forResource: "GhostTools", withExtension: "dmg") else {
            return
        }

        let destURL = helperAppURL
            .appendingPathComponent("Contents")
            .appendingPathComponent("Resources")
            .appendingPathComponent("GhostTools.dmg")

        try? fileManager.copyItem(at: dmgURL, to: destURL)
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
