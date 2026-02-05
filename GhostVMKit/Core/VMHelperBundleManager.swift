import Foundation

/// Manages creation and lifecycle of helper app bundles for individual VMs.
/// Each VM can have its own Dock icon via a lightweight helper app bundle.
public final class VMHelperBundleManager {
    private let fileManager = FileManager.default

    public init() {}

    /// Creates a helper app bundle for the given VM.
    /// - Parameters:
    ///   - vmBundleURL: URL of the VM bundle (.ghostvm)
    ///   - vmName: Display name for the VM
    ///   - vmUUID: Unique identifier for the VM (used in bundle ID)
    ///   - sourceHelperURL: URL to the GhostVMHelper executable in the main app bundle
    ///   - customIconURL: Optional URL to a custom PNG icon
    /// - Returns: URL to the created helper app bundle
    public func createHelperBundle(
        vmBundleURL: URL,
        vmName: String,
        vmUUID: String,
        sourceHelperURL: URL,
        customIconURL: URL? = nil
    ) throws -> URL {
        let layout = VMFileLayout(bundleURL: vmBundleURL)
        let helperAppURL = layout.helperAppURL(vmName: vmName)

        // Clean up existing helper if present
        if fileManager.fileExists(atPath: helperAppURL.path) {
            try fileManager.removeItem(at: helperAppURL)
        }

        // Create helper app bundle structure
        let contentsURL = helperAppURL.appendingPathComponent("Contents")
        let macOSURL = contentsURL.appendingPathComponent("MacOS")
        let resourcesURL = contentsURL.appendingPathComponent("Resources")

        try fileManager.createDirectory(at: macOSURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: resourcesURL, withIntermediateDirectories: true)

        // Copy the helper executable
        let executableURL = macOSURL.appendingPathComponent("GhostVMHelper")
        try fileManager.copyItem(at: sourceHelperURL, to: executableURL)

        // Make executable
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)

        // Generate Info.plist
        let infoPlist = generateInfoPlist(vmName: vmName, vmUUID: vmUUID)
        let infoPlistURL = contentsURL.appendingPathComponent("Info.plist")
        try infoPlist.write(to: infoPlistURL, atomically: true, encoding: .utf8)

        // Handle icon
        if let customIconURL = customIconURL, fileManager.fileExists(atPath: customIconURL.path) {
            // Convert PNG to ICNS and copy
            let icnsURL = resourcesURL.appendingPathComponent("AppIcon.icns")
            try convertPNGtoICNS(pngURL: customIconURL, icnsURL: icnsURL)
        } else {
            // Try to copy the main app's icon as default
            if let mainAppIconURL = findMainAppIcon() {
                let icnsURL = resourcesURL.appendingPathComponent("AppIcon.icns")
                try? fileManager.copyItem(at: mainAppIconURL, to: icnsURL)
            }
        }

        // Touch the bundle to invalidate icon cache
        try fileManager.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: helperAppURL.path
        )

        return helperAppURL
    }

    /// Removes the helper app bundle for a VM.
    public func removeHelperBundle(vmBundleURL: URL, vmName: String) throws {
        let layout = VMFileLayout(bundleURL: vmBundleURL)
        let helperAppURL = layout.helperAppURL(vmName: vmName)

        if fileManager.fileExists(atPath: helperAppURL.path) {
            try fileManager.removeItem(at: helperAppURL)
        }

        // Also try to remove the helper directory if empty
        let helperDir = layout.helperDirectoryURL
        if fileManager.fileExists(atPath: helperDir.path) {
            let contents = try? fileManager.contentsOfDirectory(atPath: helperDir.path)
            if contents?.isEmpty == true {
                try? fileManager.removeItem(at: helperDir)
            }
        }
    }

    /// Checks if a helper bundle exists for the VM.
    public func helperBundleExists(vmBundleURL: URL, vmName: String) -> Bool {
        let layout = VMFileLayout(bundleURL: vmBundleURL)
        let helperAppURL = layout.helperAppURL(vmName: vmName)
        return fileManager.fileExists(atPath: helperAppURL.path)
    }

    /// Gets the URL to the helper bundle if it exists.
    public func helperBundleURL(vmBundleURL: URL, vmName: String) -> URL? {
        let layout = VMFileLayout(bundleURL: vmBundleURL)
        let helperAppURL = layout.helperAppURL(vmName: vmName)
        return fileManager.fileExists(atPath: helperAppURL.path) ? helperAppURL : nil
    }

    // MARK: - Private

    private func generateInfoPlist(vmName: String, vmUUID: String) -> String {
        let sanitizedUUID = vmUUID.replacingOccurrences(of: "-", with: "")
        let bundleIdentifier = "com.ghostvm.VMHelper.\(sanitizedUUID)"
        let displayName = "GhostVM - \(vmName)"

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleDevelopmentRegion</key>
            <string>en</string>
            <key>CFBundleExecutable</key>
            <string>GhostVMHelper</string>
            <key>CFBundleIconFile</key>
            <string>AppIcon</string>
            <key>CFBundleIdentifier</key>
            <string>\(bundleIdentifier)</string>
            <key>CFBundleInfoDictionaryVersion</key>
            <string>6.0</string>
            <key>CFBundleName</key>
            <string>\(vmName)</string>
            <key>CFBundleDisplayName</key>
            <string>\(displayName)</string>
            <key>CFBundlePackageType</key>
            <string>APPL</string>
            <key>CFBundleShortVersionString</key>
            <string>1.0</string>
            <key>CFBundleVersion</key>
            <string>1</string>
            <key>LSMinimumSystemVersion</key>
            <string>15.0</string>
            <key>LSUIElement</key>
            <false/>
            <key>NSHighResolutionCapable</key>
            <true/>
            <key>NSPrincipalClass</key>
            <string>NSApplication</string>
        </dict>
        </plist>
        """
    }

    private func findMainAppIcon() -> URL? {
        // Try to find the main app's icon
        guard let mainBundle = Bundle.main.resourceURL else { return nil }
        let appBundle = mainBundle.deletingLastPathComponent()
        let resourcesURL = appBundle.appendingPathComponent("Resources")

        // Look for common icon names
        for iconName in ["AppIcon.icns", "GhostVM.icns", "Assets.car"] {
            let iconURL = resourcesURL.appendingPathComponent(iconName)
            if fileManager.fileExists(atPath: iconURL.path) && iconName.hasSuffix(".icns") {
                return iconURL
            }
        }

        return nil
    }

    private func convertPNGtoICNS(pngURL: URL, icnsURL: URL) throws {
        // Create a temporary iconset directory
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let iconsetURL = tempDir.appendingPathComponent("icon.iconset")
        try fileManager.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

        defer {
            try? fileManager.removeItem(at: tempDir)
        }

        // Copy PNG to various sizes (iconutil requires specific sizes)
        // For simplicity, we'll use the same image at different sizes
        let sizes = [16, 32, 128, 256, 512]
        for size in sizes {
            let destURL = iconsetURL.appendingPathComponent("icon_\(size)x\(size).png")
            try? fileManager.copyItem(at: pngURL, to: destURL)

            let dest2xURL = iconsetURL.appendingPathComponent("icon_\(size)x\(size)@2x.png")
            try? fileManager.copyItem(at: pngURL, to: dest2xURL)
        }

        // Run iconutil to create icns
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        process.arguments = ["-c", "icns", iconsetURL.path, "-o", icnsURL.path]

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            // Fallback: just copy the PNG if iconutil fails
            try? fileManager.copyItem(at: pngURL, to: icnsURL)
        }
    }
}
