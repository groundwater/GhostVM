import Foundation

/// Manages copying and lifecycle of helper app bundles for individual VMs.
///
/// The helper app is a signed bundle that runs VMs independently with their own Dock icon.
/// After copying, we patch the Info.plist with the VM name, rename the .app folder to match
/// the VM name (so macOS shows it correctly in the Dock and CMD+TAB), then ad-hoc re-sign.
public final class VMHelperBundleManager {
    private let fileManager = FileManager.default

    public init() {}

    /// Copies the helper app to the VM bundle, patches its Info.plist with the VM name,
    /// renames the .app folder to the VM name, and re-signs.
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

        // Copy the entire app bundle to temp name
        try fileManager.copyItem(at: sourceHelperAppURL, to: tempHelperURL)

        // Patch Info.plist with VM name and unique bundle ID
        try customizeHelperPlist(
            helperAppURL: tempHelperURL,
            vmName: vmName,
            vmBundlePath: vmBundleURL.standardizedFileURL.path
        )

        // Rename to VM-named .app folder (primary fix for Dock/CMD+TAB label)
        try fileManager.moveItem(at: tempHelperURL, to: finalHelperURL)

        // Re-sign (ad-hoc) to validate the modified bundle
        try resignHelper(at: finalHelperURL)

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

    /// Patches the helper's Info.plist so the Dock and CMD+TAB show the VM name.
    private func customizeHelperPlist(helperAppURL: URL, vmName: String, vmBundlePath: String) throws {
        let plistURL = helperAppURL
            .appendingPathComponent("Contents")
            .appendingPathComponent("Info.plist")

        guard let plistData = fileManager.contents(atPath: plistURL.path),
              let plist = try PropertyListSerialization.propertyList(
                  from: plistData, options: [], format: nil
              ) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [
                NSLocalizedDescriptionKey: "Failed to read helper Info.plist"
            ])
        }

        var mutable = plist
        mutable["CFBundleName"] = vmName
        mutable["CFBundleDisplayName"] = vmName
        mutable["CFBundleIdentifier"] = "com.groundwater.ghostvm.helper.\(vmBundlePath.stableHash)"

        let newData = try PropertyListSerialization.data(
            fromPropertyList: mutable, format: .xml, options: 0
        )
        try newData.write(to: plistURL)
    }

    /// Ad-hoc re-signs the helper bundle after plist modifications.
    private func resignHelper(at helperAppURL: URL) throws {
        let entitlementsURL = helperAppURL
            .appendingPathComponent("Contents")
            .appendingPathComponent("Resources")
            .appendingPathComponent("entitlements.plist")

        var arguments = [
            "/usr/bin/codesign",
            "--force",
            "--sign", "-",
            "--deep",
        ]

        if fileManager.fileExists(atPath: entitlementsURL.path) {
            arguments += ["--entitlements", entitlementsURL.path]
        }

        arguments.append(helperAppURL.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = Array(arguments.dropFirst()) // drop the executable path
        let pipe = Pipe()
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errorOutput = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw CocoaError(.fileWriteUnknown, userInfo: [
                NSLocalizedDescriptionKey: "codesign failed (\(process.terminationStatus)): \(errorOutput)"
            ])
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
