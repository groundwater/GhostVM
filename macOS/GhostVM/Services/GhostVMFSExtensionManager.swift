import AppKit
import Combine
import Darwin
import Foundation
import FSKit

enum GhostVMFSExtensionHealth: Equatable {
    case checking
    case ready
    case needsApplicationInstall
    case missingEmbeddedExtension
    case notRegistered
    case duplicateRegistrations(Int)
    case disabled
    case scanFailed(String)

    var requiresAttention: Bool {
        switch self {
        case .checking, .ready:
            return false
        case .needsApplicationInstall, .missingEmbeddedExtension, .notRegistered,
             .duplicateRegistrations, .disabled, .scanFailed:
            return true
        }
    }
}

extension Notification.Name {
    static let ghostVMFSExtensionNeedsAttention = Notification.Name(
        "org.ghostvm.ghostvm.fs-needs-attention"
    )
}

@MainActor
final class GhostVMFSExtensionManager: ObservableObject {
    nonisolated static let extensionBundleIdentifier = "org.ghostvm.ghostvm.fs"
    nonisolated static let extensionRelativePath = "Contents/Extensions/GhostVMFS.appex"

    @Published private(set) var extensionEnabled: Bool?
    @Published private(set) var health: GhostVMFSExtensionHealth = .checking
    @Published private(set) var repairAvailable = false
    @Published private(set) var statusDetail: String?
    @Published private(set) var isWorking = false
    @Published var errorMessage: String?

    func refresh() async {
        extensionEnabled = nil
        health = .checking

        let appURL = Self.appURL
        let extensionURL = Self.expectedExtensionURL
        guard FileManager.default.fileExists(atPath: extensionURL.path) else {
            extensionEnabled = false
            repairAvailable = false
            health = .missingEmbeddedExtension
            statusDetail = "This copy of GhostVM does not contain the GhostVMFS module. Reinstall GhostVM from the disk image."
            return
        }

        do {
            let modules = try await FSClient.shared.installedExtensions
            let identities = modules.filter {
                $0.bundleIdentifier == Self.extensionBundleIdentifier
            }
            let snapshot = await Task.detached(priority: .utility) {
                Self.registrationSnapshot()
            }.value
            let expectedURL = extensionURL.resolvingSymlinksInPath().standardizedFileURL
            let identity = identities.first {
                $0.url.resolvingSymlinksInPath().standardizedFileURL == expectedURL
            } ?? identities.first
            let hasStaleIdentity = identities.contains {
                $0.url.resolvingSymlinksInPath().standardizedFileURL != expectedURL
            } || snapshot.urls.contains {
                $0.resolvingSymlinksInPath().standardizedFileURL != expectedURL
            }

            guard let identity else {
                extensionEnabled = false
                if Self.isInstalledApplication(appURL) {
                    health = .notRegistered
                    repairAvailable = true
                    statusDetail = "macOS has not registered GhostVMFS as an FSKit module."
                } else {
                    health = .needsApplicationInstall
                    repairAvailable = false
                    statusDetail = "Move GhostVM to Applications before installing its file system extension."
                }
                return
            }

            let selectedCanonicalIdentity = identity.url
                .resolvingSymlinksInPath().standardizedFileURL == expectedURL
            extensionEnabled = identity.isEnabled
                && snapshot.enabledByFSKit
                && selectedCanonicalIdentity
                && !hasStaleIdentity
            repairAvailable = hasStaleIdentity
                || !snapshot.enabledByFSKit
                || (snapshot.enabledByFSKit && !identity.isEnabled)

            if !Self.isInstalledApplication(appURL) {
                health = .needsApplicationInstall
                repairAvailable = false
                statusDetail = "Move GhostVM to Applications before installing its file system extension."
            } else if hasStaleIdentity {
                let staleCount = Set(
                    (identities.map(\.url) + snapshot.urls)
                        .map { $0.resolvingSymlinksInPath().standardizedFileURL }
                        .filter { $0 != expectedURL }
                ).count
                health = .duplicateRegistrations(staleCount)
                statusDetail = "Found \(staleCount) stray GhostVMFS registration\(staleCount == 1 ? "" : "s"). macOS may launch the wrong extension."
            } else if !snapshot.enabledByFSKit {
                health = .disabled
                statusDetail = "Turn on GhostVMFS in System Settings under File System Extensions."
            } else if !identity.isEnabled {
                health = .disabled
                statusDetail = "FSKit cached a stale disabled state for GhostVMFS."
            } else {
                health = .ready
                statusDetail = nil
                errorMessage = nil
            }
        } catch {
            extensionEnabled = false
            repairAvailable = false
            health = .scanFailed(error.localizedDescription)
            statusDetail = "GhostVM could not inspect FSKit extensions."
            errorMessage = "Unable to inspect FSKit extensions: \(error.localizedDescription)"
        }
    }

    func repairRegistration() async {
        let appURL = Self.appURL
        guard Self.isInstalledApplication(appURL) else {
            health = .needsApplicationInstall
            errorMessage = "Move GhostVM to /Applications before repairing its FSKit registration."
            return
        }
        guard !Self.hasMountedGhostVMVolumes() else {
            statusDetail = "Stop all containers using guest directory mounts before repairing GhostVMFS."
            return
        }

        isWorking = true
        extensionEnabled = nil
        defer { isWorking = false }

        do {
            let extensionURL = Self.expectedExtensionURL
            try await Task.detached(priority: .userInitiated) {
                try Self.run(
                    executable: "/usr/bin/codesign",
                    arguments: ["--verify", "--deep", "--strict", appURL.path]
                )

                let snapshot = Self.registrationSnapshot()
                for staleURL in snapshot.urls where
                    staleURL.resolvingSymlinksInPath().standardizedFileURL
                        != extensionURL.resolvingSymlinksInPath().standardizedFileURL {
                    try? Self.run(executable: "/usr/bin/pluginkit", arguments: ["-r", staleURL.path])
                    if let staleApp = Self.containingApp(for: staleURL), staleApp != appURL {
                        try? Self.run(
                            executable: Self.launchServicesRegisterPath,
                            arguments: ["-u", staleApp.path]
                        )
                    }
                }

                // Recreate the canonical identity too. System Settings can keep
                // its switch attached to an obsolete PlugInKit UUID.
                try? Self.run(executable: "/usr/bin/pluginkit", arguments: ["-r", extensionURL.path])
                try? Self.run(
                    executable: Self.launchServicesRegisterPath,
                    arguments: ["-u", appURL.path]
                )
                try Self.run(
                    executable: Self.launchServicesRegisterPath,
                    arguments: ["-f", "-R", "-trusted", appURL.path]
                )
                try? Self.run(executable: "/usr/bin/killall", arguments: ["fskit_agent"])
            }.value

            try? await Task.sleep(for: .seconds(1))
            await refresh()
            errorMessage = nil
            if extensionEnabled != true {
                statusDetail = "Registration repaired. Turn on GhostVMFS in System Settings."
                openSettings()
            }
        } catch {
            extensionEnabled = false
            errorMessage = "Unable to repair FSKit registration: \(error.localizedDescription)"
        }
    }

    func openSettings() {
        extensionEnabled = nil

        let client = FSClient.shared as NSObject
        let selector = NSSelectorFromString("openFileSystemExtensionsSettings")
        if client.responds(to: selector) {
            typealias OpenSettings = @convention(c) (AnyObject, Selector) -> Bool
            let implementation = client.method(for: selector)
            if unsafeBitCast(implementation, to: OpenSettings.self)(client, selector) {
                return
            }
        }

        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.ExtensionsPreferences?extensionPointIdentifier=com.apple.fskit.fsmodule"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    nonisolated static func reportNeedsAttention() {
        NotificationCenter.default.post(name: .ghostVMFSExtensionNeedsAttention, object: nil)
    }

    struct RegistrationSnapshot: Sendable {
        let urls: [URL]
        let enabledByFSKit: Bool
    }

    nonisolated static let launchServicesRegisterPath =
        "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

    nonisolated static var appURL: URL {
        Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL
    }

    nonisolated static var expectedExtensionURL: URL {
        appURL.appendingPathComponent(extensionRelativePath, isDirectory: true)
    }

    nonisolated static var enabledModulesURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/group.com.apple.fskit.settings/enabledModules.plist")
    }

    nonisolated static func registrationSnapshot() -> RegistrationSnapshot {
        let output = (try? runAndCapture(
            executable: "/usr/bin/pluginkit",
            arguments: [
                "-v", "-m", "-A", "-D",
                "-p", "com.apple.fskit.fsmodule",
                "-i", extensionBundleIdentifier,
            ]
        )) ?? ""
        let enabledModules = (try? Data(contentsOf: enabledModulesURL)).map {
            enabledModuleIdentifiers(from: $0)
        } ?? []
        return RegistrationSnapshot(
            urls: registrationURLs(from: output),
            enabledByFSKit: enabledModules.contains(extensionBundleIdentifier)
        )
    }

    nonisolated static func registrationURLs(from output: String) -> [URL] {
        output.split(separator: "\n").compactMap { line -> URL? in
            guard line.contains(extensionBundleIdentifier),
                  let path = line.split(separator: "\t", omittingEmptySubsequences: true).last,
                  path.hasPrefix("/") else { return nil }
            return URL(fileURLWithPath: String(path), isDirectory: true)
        }
    }

    nonisolated static func enabledModuleIdentifiers(from data: Data) -> Set<String> {
        let modules = (try? PropertyListSerialization.propertyList(
            from: data,
            format: nil
        )) as? [String]
        return Set(modules ?? [])
    }

    nonisolated static func isInstalledApplication(_ url: URL) -> Bool {
        url.path.hasPrefix("/Applications/")
    }

    nonisolated private static func containingApp(for url: URL) -> URL? {
        var candidate = url
        while candidate.path != "/" {
            if candidate.pathExtension == "app" { return candidate }
            candidate.deleteLastPathComponent()
        }
        return nil
    }

    nonisolated private static func hasMountedGhostVMVolumes() -> Bool {
        var fileSystems: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&fileSystems, MNT_NOWAIT)
        guard count > 0, let fileSystems else { return false }
        for index in 0..<Int(count) {
            var fileSystem = fileSystems[index]
            let type = withUnsafeBytes(of: &fileSystem.f_fstypename) { bytes -> String in
                guard let address = bytes.baseAddress else { return "" }
                return String(cString: address.assumingMemoryBound(to: CChar.self))
            }
            if type == "ghostvm" { return true }
        }
        return false
    }

    nonisolated private static func run(executable: String, arguments: [String]) throws {
        _ = try runAndCapture(executable: executable, arguments: arguments)
    }

    nonisolated private static func runAndCapture(
        executable: String,
        arguments: [String]
    ) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let detail = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard process.terminationStatus == 0 else {
            throw ExtensionCommandFailure(
                detail.isEmpty
                    ? "Command exited with status \(process.terminationStatus)"
                    : detail
            )
        }
        return detail
    }

    private struct ExtensionCommandFailure: LocalizedError {
        let detail: String
        init(_ detail: String) { self.detail = detail }
        var errorDescription: String? { detail }
    }
}
