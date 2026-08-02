import AppKit
import Foundation
import FSKit
import OSLog

private let ghostFileMountLogger = Logger(
    subsystem: "org.ghostvm.ghostfile",
    category: "Mount"
)

struct MountedGhostFileShare: Identifiable, Equatable {
    let id: UUID
    let shareID: UUID
    let name: String
    let sourceURL: URL
    let mountPoint: URL
    let removesMountPointOnUnmount: Bool
}

@MainActor
final class GhostFileMountManager: ObservableObject {
    nonisolated private static let extensionBundleIdentifier = "org.ghostvm.ghostfile.fs"

    @Published private(set) var mountedShares: [MountedGhostFileShare] = []
    @Published private(set) var extensionEnabled: Bool?
    @Published private(set) var extensionRepairAvailable = false
    @Published private(set) var extensionStatusDetail: String?
    @Published var errorMessage: String?
    @Published private(set) var isWorking = false
    private var disconnectedShareIDs: Set<UUID> = []

    func refreshExtensionStatus() async {
        do {
            let modules = try await FSClient.shared.installedExtensions
            let identities = modules.filter {
                $0.bundleIdentifier == Self.extensionBundleIdentifier
            }
            let expectedURL = expectedExtensionURL.resolvingSymlinksInPath().standardizedFileURL
            let snapshot = await Task.detached(priority: .utility) {
                Self.registrationSnapshot()
            }.value
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
                extensionRepairAvailable = Bundle.main.bundleURL.path.hasPrefix("/Applications/")
                extensionStatusDetail = "macOS has not registered the embedded GhostFileFS module."
                return
            }

            let selectedCanonicalIdentity = identity.url.resolvingSymlinksInPath().standardizedFileURL == expectedURL
            // FSClient can temporarily report a cached enabled value after the
            // FSKit preference has been disabled, so require the on-disk FSKit
            // state too. The Settings pane doesn't necessarily set PlugInKit's
            // optional "+" election, so that marker is diagnostic only.
            extensionEnabled = identity.isEnabled
                && snapshot.enabledByFSKit
                && selectedCanonicalIdentity
                && !hasStaleIdentity
            extensionRepairAvailable = hasStaleIdentity
                || !snapshot.enabledByFSKit
                || (snapshot.enabledByFSKit && !identity.isEnabled)

            if hasStaleIdentity {
                let staleCount = Set(
                    (identities.map(\.url) + snapshot.urls)
                        .map { $0.resolvingSymlinksInPath().standardizedFileURL }
                        .filter { $0 != expectedURL }
                ).count
                extensionStatusDetail = "Found \(staleCount) stray GhostFileFS registration\(staleCount == 1 ? "" : "s"). macOS may launch the wrong extension; repair registration before mounting."
            } else if !snapshot.enabledByFSKit {
                extensionStatusDetail = "The Extensions toggle and FSKit's enabled-module list are out of sync."
            } else if snapshot.enabledByFSKit && !identity.isEnabled {
                extensionStatusDetail = "FSKit cached a stale disabled state for GhostFileFS."
            } else {
                extensionStatusDetail = nil
            }
        } catch {
            extensionEnabled = false
            extensionRepairAvailable = false
            extensionStatusDetail = nil
            errorMessage = "Unable to inspect FSKit extensions: \(error.localizedDescription)"
        }
    }

    func repairExtensionRegistration() async {
        let appURL = Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL
        guard appURL.path.hasPrefix("/Applications/") else {
            errorMessage = "Move GhostFile to /Applications before repairing its FSKit registration."
            return
        }

        isWorking = true
        extensionEnabled = nil
        defer { isWorking = false }

        do {
            let extensionURL = expectedExtensionURL.resolvingSymlinksInPath().standardizedFileURL
            try await Task.detached(priority: .userInitiated) {
                try Self.run(executable: "/usr/bin/codesign", arguments: ["--verify", "--deep", "--strict", appURL.path])

                let snapshot = Self.registrationSnapshot()
                for staleURL in snapshot.urls where staleURL.resolvingSymlinksInPath().standardizedFileURL != extensionURL {
                    try? Self.run(executable: "/usr/bin/pluginkit", arguments: ["-r", staleURL.path])
                    if let staleApp = Self.containingApp(for: staleURL), staleApp != appURL {
                        try? Self.run(executable: Self.launchServicesRegisterPath, arguments: ["-u", staleApp.path])
                    }
                }

                // Recreate the canonical identity too. A stuck Settings switch
                // can be attached to a stale UUID even when its URL is correct.
                try? Self.run(executable: "/usr/bin/pluginkit", arguments: ["-r", extensionURL.path])
                try? Self.run(executable: Self.launchServicesRegisterPath, arguments: ["-u", appURL.path])
                try Self.run(executable: Self.launchServicesRegisterPath, arguments: ["-f", "-R", "-trusted", appURL.path])

                // FSKit caches module identities in a per-user agent. Restart it
                // only after LaunchServices has created the replacement UUID.
                try? Self.run(executable: "/usr/bin/killall", arguments: ["fskit_agent"])
            }.value

            try? await Task.sleep(for: .seconds(1))
            await refreshExtensionStatus()
            if extensionEnabled == true {
                errorMessage = nil
            } else {
                errorMessage = nil
                extensionStatusDetail = "Registration repaired. Turn on GhostFileFS in System Settings."
                openExtensionSettings()
            }
        } catch {
            extensionEnabled = false
            errorMessage = "Unable to repair FSKit registration: \(error.localizedDescription)"
        }
    }

    func mount(url: URL, accessKey: String, volumeName: String, requestedMountPoint: URL?) async {
        guard !accessKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "Enter the share's access key."
            return
        }
        guard url.scheme == GhostFileProtocol.urlScheme else {
            errorMessage = "GhostFile share URLs must use ghostfile://."
            return
        }
        // Do not trust the status captured when the Mount view first appeared.
        // LaunchServices can discover an Xcode/Downloads copy while the app is
        // already open, and FSKit may otherwise launch that stale registration.
        await refreshExtensionStatus()
        guard extensionEnabled == true else {
            errorMessage = extensionStatusDetail
                ?? "Enable the GhostFile file system extension in System Settings first."
            return
        }

        isWorking = true
        defer { isWorking = false }
        do {
            var resourceComponents = URLComponents(url: url, resolvingAgainstBaseURL: false)
            var queryItems = resourceComponents?.queryItems ?? []
            queryItems.removeAll {
                $0.name == "access_key" || $0.name == GhostFileProtocol.mountInstanceQueryName
            }
            let mountInstance = UUID()
            queryItems.append(URLQueryItem(name: "access_key", value: accessKey))
            queryItems.append(URLQueryItem(
                name: GhostFileProtocol.mountInstanceQueryName,
                value: mountInstance.uuidString.lowercased()
            ))
            resourceComponents?.queryItems = queryItems
            guard let resourceURL = resourceComponents?.url else {
                throw MountFailure("Invalid share URL")
            }
            guard let shareID = shareID(from: resourceURL) else {
                throw MountFailure("Invalid GhostFile share URL")
            }

            let mountPoint: URL
            let removesMountPointOnUnmount: Bool
            let isAccessingMountPoint = requestedMountPoint?.startAccessingSecurityScopedResource() ?? false
            defer {
                if isAccessingMountPoint {
                    requestedMountPoint?.stopAccessingSecurityScopedResource()
                }
            }
            if let requestedMountPoint {
                mountPoint = requestedMountPoint.standardizedFileURL
                try validateUserSelectedMountPoint(mountPoint)
                removesMountPointOnUnmount = false
            } else {
                let mountRoot = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("GhostFiles", isDirectory: true)
                try FileManager.default.createDirectory(at: mountRoot, withIntermediateDirectories: true)
                let safeName = sanitizedVolumeName(volumeName)
                mountPoint = uniqueMountPoint(root: mountRoot, name: safeName)
                try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: false)
                removesMountPointOnUnmount = true
            }

            // Ignore an earlier disappearance of this share, but retain any
            // removal notification that arrives while the mount is in flight.
            disconnectedShareIDs.remove(shareID)

            do {
                ghostFileMountLogger.info(
                    "Mount invocation starting share=\(shareID.uuidString.lowercased(), privacy: .public) instance=\(mountInstance.uuidString.lowercased(), privacy: .public) target=\(mountPoint.path, privacy: .private(mask: .hash))"
                )
                try await Task.detached(priority: .userInitiated) {
                    try Self.run(
                        executable: "/sbin/mount",
                        arguments: [
                            "-F", "-t", "ghostfile",
                            "-o", "rdonly,nobrowse,nodev,nosuid",
                            resourceURL.absoluteString,
                            mountPoint.path,
                        ],
                        timeout: 25
                    )
                }.value
                ghostFileMountLogger.info(
                    "Mount invocation completed share=\(shareID.uuidString.lowercased(), privacy: .public) instance=\(mountInstance.uuidString.lowercased(), privacy: .public)"
                )
            } catch {
                ghostFileMountLogger.error(
                    "Mount invocation failed share=\(shareID.uuidString.lowercased(), privacy: .public) instance=\(mountInstance.uuidString.lowercased(), privacy: .public) error=\(String(describing: error), privacy: .public)"
                )
                if removesMountPointOnUnmount {
                    try? FileManager.default.removeItem(at: mountPoint)
                }
                throw error
            }

            mountedShares.append(.init(
                id: UUID(),
                shareID: shareID,
                name: volumeName,
                sourceURL: url,
                mountPoint: mountPoint,
                removesMountPointOnUnmount: removesMountPointOnUnmount
            ))
            errorMessage = nil
            if disconnectedShareIDs.contains(shareID),
               let mountedShare = mountedShares.last {
                await unmount(mountedShare, force: true)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func unmount(_ mountedShare: MountedGhostFileShare, force: Bool = false) async {
        isWorking = true
        defer { isWorking = false }
        do {
            do {
                try await Self.runUnmount(mountedShare.mountPoint, force: force)
            } catch where !force && Self.isDeviceBusy(error) {
                // The user explicitly requested an unmount and GhostFile
                // volumes are read-only network mounts. A forced retry is the
                // appropriate recovery for a wedged FSKit vnode reference.
                try await Self.runUnmount(mountedShare.mountPoint, force: true)
            }
            if mountedShare.removesMountPointOnUnmount {
                try? FileManager.default.removeItem(at: mountedShare.mountPoint)
            }
            mountedShares.removeAll { $0.id == mountedShare.id }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func unmountDisconnectedShare(withID shareID: UUID) async {
        disconnectedShareIDs.insert(shareID)
        let disconnectedMounts = mountedShares.filter { $0.shareID == shareID }
        for mountedShare in disconnectedMounts {
            await unmount(mountedShare, force: true)
        }
    }

    func reveal(_ mountedShare: MountedGhostFileShare) {
        NSWorkspace.shared.activateFileViewerSelecting([mountedShare.mountPoint])
    }

    private static func runUnmount(_ mountPoint: URL, force: Bool) async throws {
        try await Task.detached(priority: .userInitiated) {
            let arguments = force ? ["-f", mountPoint.path] : [mountPoint.path]
            try Self.run(executable: "/sbin/umount", arguments: arguments, timeout: 10)
        }.value
    }

    private nonisolated static func isDeviceBusy(_ error: Error) -> Bool {
        let detail = error.localizedDescription.lowercased()
        return detail.contains("device busy") || detail.contains("resource busy")
    }

    func openExtensionSettings() {
        extensionEnabled = nil

        // Newer FSKit runtimes provide this official API. Keep the runtime
        // check so builds made with the 26.4 SDK use it as soon as it exists.
        let client = FSClient.shared as NSObject
        let selector = NSSelectorFromString("openFileSystemExtensionsSettings")
        if client.responds(to: selector) {
            typealias OpenSettings = @convention(c) (AnyObject, Selector) -> Bool
            let implementation = client.method(for: selector)
            if unsafeBitCast(implementation, to: OpenSettings.self)(client, selector) {
                return
            }
        }

        // Older macOS 26 releases support the Extensions preferences route
        // with an extension-point filter, which avoids the generic settings
        // page and opens the FSKit Modules category directly.
        guard let url = URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences?extensionPointIdentifier=com.apple.fskit.fsmodule") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private var expectedExtensionURL: URL {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/Extensions/GhostFileFS.appex", isDirectory: true)
    }

    private struct RegistrationSnapshot: Sendable {
        let urls: [URL]
        let enabledByFSKit: Bool
    }

    private nonisolated static let launchServicesRegisterPath =
        "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

    private nonisolated static var enabledModulesURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/group.com.apple.fskit.settings/enabledModules.plist")
    }

    private nonisolated static func registrationSnapshot() -> RegistrationSnapshot {
        let output = (try? runAndCapture(
            executable: "/usr/bin/pluginkit",
            arguments: ["-v", "-m", "-A", "-D", "-p", "com.apple.fskit.fsmodule", "-i", extensionBundleIdentifier]
        )) ?? ""
        let matchingLines = output.split(separator: "\n").map(String.init).filter {
            $0.contains(extensionBundleIdentifier)
        }
        let urls = matchingLines.compactMap { line -> URL? in
            guard let path = line.split(separator: "\t", omittingEmptySubsequences: true).last,
                  path.hasPrefix("/") else { return nil }
            return URL(fileURLWithPath: String(path), isDirectory: true)
        }
        let enabledModules = (try? Data(contentsOf: enabledModulesURL)).flatMap {
            try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String]
        } ?? []
        return RegistrationSnapshot(
            urls: urls,
            enabledByFSKit: enabledModules.contains(extensionBundleIdentifier)
        )
    }

    private nonisolated static func containingApp(for url: URL) -> URL? {
        var candidate = url
        while candidate.path != "/" {
            if candidate.pathExtension == "app" { return candidate }
            candidate.deleteLastPathComponent()
        }
        return nil
    }

    private func sanitizedVolumeName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = trimmed.isEmpty ? "GhostFile Share" : trimmed
        let sanitized = source.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: "\0", with: "")
        return String(sanitized.prefix(80))
    }

    private func uniqueMountPoint(root: URL, name: String) -> URL {
        var candidate = root.appendingPathComponent(name, isDirectory: true)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = root.appendingPathComponent("\(name) \(suffix)", isDirectory: true)
            suffix += 1
        }
        return candidate
    }

    private func validateUserSelectedMountPoint(_ mountPoint: URL) throws {
        guard mountPoint.isFileURL else {
            throw MountFailure("The mount point must be a local folder.")
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: mountPoint.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw MountFailure("The selected mount point is not a folder.")
        }

        let contents = try FileManager.default.contentsOfDirectory(
            at: mountPoint,
            includingPropertiesForKeys: nil,
            options: []
        )
        guard contents.isEmpty else {
            throw MountFailure("The selected mount point must be empty.")
        }
    }

    private func shareID(from url: URL) -> UUID? {
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count == 3, parts[0] == "v1", parts[1] == "shares" else { return nil }
        return UUID(uuidString: String(parts[2]))
    }

    nonisolated private static func run(
        executable: String,
        arguments: [String],
        timeout: TimeInterval? = nil
    ) throws {
        _ = try runAndCapture(executable: executable, arguments: arguments, timeout: timeout)
    }

    nonisolated private static func runAndCapture(
        executable: String,
        arguments: [String],
        timeout: TimeInterval? = nil
    ) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        if let timeout,
           finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 2)
            }
            throw MountFailure("Mount timed out after \(Int(timeout)) seconds. Verify the share is still online and reachable over UDP.")
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        if timeout == nil { process.waitUntilExit() }
        let detail = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard process.terminationStatus == 0 else {
            throw MountFailure(detail.isEmpty ? "Command exited with status \(process.terminationStatus)" : detail)
        }
        return detail
    }

    private struct MountFailure: LocalizedError {
        let detail: String
        init(_ detail: String) { self.detail = detail }
        var errorDescription: String? { detail }
    }
}
