import AppKit
import Combine
import Darwin
import Foundation
import FSKit
import GhostFileKit
import OSLog

private let ghostFileMountLogger = Logger(
    subsystem: "org.ghostvm.ghostfile",
    category: "Mount"
)

struct MountedGhostFileShare: Identifiable, Equatable {
    let id: UUID
    let definitionID: UUID
    let shareID: UUID
    let name: String
    let sourceURL: URL
    let mountPoint: URL
    let removesMountPointOnUnmount: Bool
}

struct SavedGhostFileMount: Identifiable, Codable, Equatable {
    let id: UUID
    let shareID: UUID
    var name: String
    var sourceURL: String
    var mountPointBookmark: Data?
    var readOnly: Bool
}

enum GhostFileSavedMountStatus: Equatable {
    case stopped
    case mounting
    case mounted(URL)
    case online(URL)
    case degraded(URL)
    case error(URL, String)
    case offline(URL)
    case failed(String)

    var isMounted: Bool {
        switch self {
        case .mounted, .online, .degraded, .error, .offline: true
        case .stopped, .mounting, .failed: false
        }
    }
}

enum GhostFileExtensionHealth: Equatable {
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
            false
        case .needsApplicationInstall, .missingEmbeddedExtension, .notRegistered,
             .duplicateRegistrations, .disabled, .scanFailed:
            true
        }
    }
}

protocol GhostFileMountConfigurationStorage {
    func load() throws -> [SavedGhostFileMount]
    func save(_ mounts: [SavedGhostFileMount]) throws
}

struct GhostFileMountJSONStorage: GhostFileMountConfigurationStorage {
    let fileURL: URL

    static var applicationStorage: Self {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GhostFile", isDirectory: true)
        return Self(fileURL: root.appendingPathComponent("mounts.json"))
    }

    func load() throws -> [SavedGhostFileMount] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        return try JSONDecoder().decode([SavedGhostFileMount].self, from: Data(contentsOf: fileURL))
    }

    func save(_ mounts: [SavedGhostFileMount]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(mounts).write(to: fileURL, options: .atomic)
    }
}

@MainActor
final class GhostFileMountManager: ObservableObject {
    nonisolated private static let extensionBundleIdentifier = "org.ghostvm.ghostfile.fs"

    @Published private(set) var mountedShares: [MountedGhostFileShare] = []
    @Published private(set) var extensionEnabled: Bool?
    @Published private(set) var extensionHealth: GhostFileExtensionHealth = .checking
    @Published private(set) var extensionRepairAvailable = false
    @Published private(set) var extensionStatusDetail: String?
    @Published var errorMessage: String?
    @Published private(set) var isWorking = false

    func refreshExtensionStatus() async {
        extensionEnabled = nil
        extensionHealth = .checking
        do {
            let appURL = Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL
            let extensionURL = expectedExtensionURL.resolvingSymlinksInPath().standardizedFileURL
            guard FileManager.default.fileExists(atPath: extensionURL.path) else {
                extensionEnabled = false
                extensionRepairAvailable = false
                extensionHealth = .missingEmbeddedExtension
                extensionStatusDetail = "This copy of GhostFile does not contain the GhostFileFS module. Reinstall GhostFile from the disk image."
                return
            }

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
                if appURL.path.hasPrefix("/Applications/") {
                    extensionHealth = .notRegistered
                    extensionRepairAvailable = true
                    extensionStatusDetail = "macOS has not registered the embedded GhostFileFS module."
                } else {
                    extensionHealth = .needsApplicationInstall
                    extensionRepairAvailable = false
                    extensionStatusDetail = "Move GhostFile to Applications before installing its file system extension."
                }
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

            if !appURL.path.hasPrefix("/Applications/") {
                extensionHealth = .needsApplicationInstall
                extensionRepairAvailable = false
                extensionStatusDetail = "Move GhostFile to Applications before installing its file system extension."
            } else if hasStaleIdentity {
                let staleCount = Set(
                    (identities.map(\.url) + snapshot.urls)
                        .map { $0.resolvingSymlinksInPath().standardizedFileURL }
                        .filter { $0 != expectedURL }
                ).count
                extensionHealth = .duplicateRegistrations(staleCount)
                extensionStatusDetail = "Found \(staleCount) stray GhostFileFS registration\(staleCount == 1 ? "" : "s"). macOS may launch the wrong extension; repair registration before mounting."
            } else if !snapshot.enabledByFSKit {
                extensionHealth = .disabled
                extensionStatusDetail = "The Extensions toggle and FSKit's enabled-module list are out of sync."
            } else if snapshot.enabledByFSKit && !identity.isEnabled {
                extensionHealth = .disabled
                extensionStatusDetail = "FSKit cached a stale disabled state for GhostFileFS."
            } else {
                extensionHealth = .ready
                extensionStatusDetail = nil
            }
        } catch {
            extensionEnabled = false
            extensionRepairAvailable = false
            extensionHealth = .scanFailed(error.localizedDescription)
            extensionStatusDetail = "GhostFile could not inspect the file system extension."
            errorMessage = "Unable to inspect FSKit extensions: \(error.localizedDescription)"
        }
    }

    func repairExtensionRegistration() async {
        let appURL = Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL
        guard appURL.path.hasPrefix("/Applications/") else {
            extensionHealth = .needsApplicationInstall
            errorMessage = "Move GhostFile to /Applications before repairing its FSKit registration."
            return
        }
        guard mountedShares.isEmpty else {
            extensionStatusDetail = "Unmount all GhostFile volumes before repairing the file system extension."
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

    @discardableResult
    func mount(
        definitionID: UUID,
        url: URL,
        accessKey: String,
        volumeName: String,
        requestedMountPoint: URL?
    ) async -> MountedGhostFileShare? {
        guard !accessKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "Enter the share's access key."
            return nil
        }
        guard url.scheme == GhostFileProtocol.urlScheme else {
            errorMessage = "GhostFile share URLs must use ghostfile://."
            return nil
        }
        guard GhostFileProtocol.peerPin(from: url) != nil else {
            errorMessage = "The share URL is missing a valid TLS identity pin. Copy a new link from the sharing Mac."
            return nil
        }
        // Do not trust the status captured when the Mount view first appeared.
        // LaunchServices can discover an Xcode/Downloads copy while the app is
        // already open, and FSKit may otherwise launch that stale registration.
        await refreshExtensionStatus()
        guard extensionEnabled == true else {
            errorMessage = extensionStatusDetail
                ?? "Enable the GhostFile file system extension in System Settings first."
            return nil
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

            do {
                ghostFileMountLogger.info(
                    "Mount invocation starting share=\(shareID.uuidString.lowercased(), privacy: .public) instance=\(mountInstance.uuidString.lowercased(), privacy: .public) target=\(mountPoint.path, privacy: .private(mask: .hash))"
                )
                try await Task.detached(priority: .userInitiated) {
                    try Self.run(
                        executable: "/sbin/mount",
                        arguments: [
                            "-F", "-t", "ghostfile",
                            // GhostFileFS negotiates read-only versus writable
                            // from the share's live capabilities. Forcing
                            // rdonly here made every volume immutable even
                            // when the server explicitly allowed writes.
                            "-o", "nobrowse,nodev,nosuid",
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
                try? FileManager.default.removeItem(
                    at: GhostFileMountHealthStorage.readerURL(for: mountInstance)
                )
                if removesMountPointOnUnmount {
                    try? FileManager.default.removeItem(at: mountPoint)
                }
                throw error
            }

            let mountedShare = MountedGhostFileShare(
                id: mountInstance,
                definitionID: definitionID,
                shareID: shareID,
                name: volumeName,
                sourceURL: url,
                mountPoint: mountPoint,
                removesMountPointOnUnmount: removesMountPointOnUnmount
            )
            mountedShares.append(mountedShare)
            errorMessage = nil
            return mountedShare
        } catch {
            errorMessage = error.localizedDescription
            return nil
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
                // volumes are network mounts. A forced retry is the
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

    func reveal(_ mountedShare: MountedGhostFileShare) {
        NSWorkspace.shared.activateFileViewerSelecting([mountedShare.mountPoint])
    }

    func reconcileMountedShares() -> [MountedGhostFileShare] {
        let missing = mountedShares.filter { !Self.isMounted(at: $0.mountPoint) }
        guard !missing.isEmpty else { return [] }
        let missingIDs = Set(missing.map(\.id))
        mountedShares.removeAll { missingIDs.contains($0.id) }
        for mountedShare in missing where mountedShare.removesMountPointOnUnmount {
            try? FileManager.default.removeItem(at: mountedShare.mountPoint)
        }
        return missing
    }

    private static func runUnmount(_ mountPoint: URL, force: Bool) async throws {
        try await Task.detached(priority: .userInitiated) {
            let arguments = force ? ["-f", mountPoint.path] : [mountPoint.path]
            try Self.run(executable: "/sbin/umount", arguments: arguments, timeout: 10)
        }.value
    }

    private nonisolated static func isMounted(at mountPoint: URL) -> Bool {
        var fileSystems: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&fileSystems, MNT_NOWAIT)
        guard count > 0, let fileSystems else { return false }
        let expectedPath = mountPoint.standardizedFileURL.path

        for index in 0..<Int(count) {
            var fileSystem = fileSystems[index]
            let mountedAt = withUnsafeBytes(of: &fileSystem.f_mntonname) { bytes -> String in
                guard let address = bytes.baseAddress else { return "" }
                return String(cString: address.assumingMemoryBound(to: CChar.self))
            }
            if URL(fileURLWithPath: mountedAt).standardizedFileURL.path == expectedPath {
                return true
            }
        }
        return false
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

@MainActor
final class GhostFileMountLibrary: ObservableObject {
    @Published private(set) var mounts: [SavedGhostFileMount]
    @Published private(set) var errors: [UUID: String] = [:]
    @Published private(set) var workingMountIDs: Set<UUID> = []
    @Published private(set) var healthSnapshots: [UUID: GhostFileMountHealthSnapshot] = [:]
    @Published var generalError: String?

    let manager: GhostFileMountManager
    private let configurationStorage: any GhostFileMountConfigurationStorage
    private let accessKeyStorage: any GhostFileAccessKeyStorage
    private var runtimeIDs: [UUID: UUID] = [:]
    private var managerObserver: AnyCancellable?

    init(
        configurationStorage: any GhostFileMountConfigurationStorage = GhostFileMountJSONStorage.applicationStorage,
        accessKeyStorage: any GhostFileAccessKeyStorage = GhostFileKeychainAccessKeyStorage(
            service: "org.ghostvm.ghostfile.mount-access-key"
        ),
        manager: GhostFileMountManager? = nil
    ) {
        self.configurationStorage = configurationStorage
        self.accessKeyStorage = accessKeyStorage
        self.manager = manager ?? GhostFileMountManager()
        do {
            mounts = try configurationStorage.load()
        } catch {
            mounts = []
            generalError = "Unable to load saved mounts: \(error.localizedDescription)"
        }
        managerObserver = self.manager.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.objectWillChange.send() }
        }
    }

    func mount(withID id: UUID) -> SavedGhostFileMount? {
        mounts.first { $0.id == id }
    }

    func accessKey(for mountID: UUID) throws -> String {
        guard let key = try accessKeyStorage.accessKey(for: mountID), !key.isEmpty else {
            throw GhostFileMountLibraryError.missingAccessKey
        }
        return key
    }

    func requestedMountPoint(for mountID: UUID) -> URL? {
        guard let bookmark = mount(withID: mountID)?.mountPointBookmark else { return nil }
        var stale = false
        return try? URL(
            resolvingBookmarkData: bookmark,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
    }

    @discardableResult
    func addMount(
        name: String,
        sourceURL: String,
        accessKey: String,
        mountPoint: URL? = nil,
        readOnly: Bool = true
    ) throws -> SavedGhostFileMount {
        let trimmedKey = accessKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { throw GhostFileMountLibraryError.emptyAccessKey }
        let mount = try validatedMount(
            id: UUID(),
            name: name,
            sourceURL: sourceURL,
            mountPoint: mountPoint,
            readOnly: readOnly
        )
        try accessKeyStorage.setAccessKey(
            trimmedKey,
            for: mount.id
        )
        do {
            var updated = mounts
            updated.append(mount)
            try configurationStorage.save(updated)
            mounts = updated
            generalError = nil
            return mount
        } catch {
            try? accessKeyStorage.removeAccessKey(for: mount.id)
            throw error
        }
    }

    func updateMount(
        _ mountID: UUID,
        name: String,
        sourceURL: String,
        accessKey: String,
        mountPoint: URL?
    ) throws {
        guard let index = mounts.firstIndex(where: { $0.id == mountID }) else {
            throw GhostFileMountLibraryError.mountNotFound
        }
        guard runtimeIDs[mountID] == nil else {
            throw GhostFileMountLibraryError.unmountBeforeEditing
        }
        let updatedMount = try validatedMount(
            id: mountID,
            name: name,
            sourceURL: sourceURL,
            mountPoint: mountPoint,
            readOnly: mounts[index].readOnly
        )
        let trimmedKey = accessKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { throw GhostFileMountLibraryError.emptyAccessKey }
        let oldMounts = mounts
        let oldKey = try accessKeyStorage.accessKey(for: mountID)
        do {
            try accessKeyStorage.setAccessKey(trimmedKey, for: mountID)
            var updated = mounts
            updated[index] = updatedMount
            try configurationStorage.save(updated)
            mounts = updated
            errors[mountID] = nil
            generalError = nil
        } catch {
            mounts = oldMounts
            if let oldKey {
                try? accessKeyStorage.setAccessKey(oldKey, for: mountID)
            } else {
                try? accessKeyStorage.removeAccessKey(for: mountID)
            }
            throw error
        }
    }

    func status(for mountID: UUID) -> GhostFileSavedMountStatus {
        if workingMountIDs.contains(mountID) { return .mounting }
        if let runtimeID = runtimeIDs[mountID] {
            if let runtime = manager.mountedShares.first(where: { $0.id == runtimeID }) {
                if let snapshot = healthSnapshots[mountID] {
                    switch snapshot.state {
                    case .online: return .online(runtime.mountPoint)
                    case .degraded: return .degraded(runtime.mountPoint)
                    case .error:
                        return .error(runtime.mountPoint, snapshot.detail ?? "A filesystem operation failed")
                    case .offline: return .offline(runtime.mountPoint)
                    }
                }
                return .mounted(runtime.mountPoint)
            }
            runtimeIDs[mountID] = nil
            healthSnapshots[mountID] = nil
        }
        if let error = errors[mountID] { return .failed(error) }
        return .stopped
    }

    func refreshExtensionStatus() async {
        await manager.refreshExtensionStatus()
    }

    func monitorHealth() async {
        while !Task.isCancelled {
            await refreshHealthSnapshots()
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
        }
    }

    func mount(_ mountID: UUID) async {
        _ = status(for: mountID)
        guard !workingMountIDs.contains(mountID),
              runtimeIDs[mountID] == nil,
              let mount = mount(withID: mountID) else { return }
        workingMountIDs.insert(mountID)
        errors[mountID] = nil
        defer { workingMountIDs.remove(mountID) }
        do {
            guard let sourceURL = URL(string: mount.sourceURL) else {
                throw GhostFileMountLibraryError.invalidURL
            }
            let key = try accessKey(for: mountID)
            let runtime = await manager.mount(
                definitionID: mountID,
                url: sourceURL,
                accessKey: key,
                volumeName: mount.name,
                requestedMountPoint: requestedMountPoint(for: mountID)
            )
            guard let runtime else {
                throw GhostFileMountLibraryError.runtimeFailure(
                    manager.errorMessage ?? "The mount did not complete."
                )
            }
            runtimeIDs[mountID] = runtime.id
            errors[mountID] = nil
            await refreshHealthSnapshots()
        } catch {
            errors[mountID] = error.localizedDescription
        }
    }

    func unmount(_ mountID: UUID) async {
        guard !workingMountIDs.contains(mountID),
              let runtimeID = runtimeIDs[mountID],
              let runtime = manager.mountedShares.first(where: { $0.id == runtimeID }) else {
            runtimeIDs[mountID] = nil
            healthSnapshots[mountID] = nil
            return
        }
        workingMountIDs.insert(mountID)
        defer { workingMountIDs.remove(mountID) }
        await manager.unmount(runtime)
        if manager.mountedShares.contains(where: { $0.id == runtimeID }) {
            errors[mountID] = manager.errorMessage ?? "Unable to unmount."
        } else {
            runtimeIDs[mountID] = nil
            healthSnapshots[mountID] = nil
            errors[mountID] = nil
        }
    }

    func reveal(_ mountID: UUID) {
        if let runtimeID = runtimeIDs[mountID],
           let runtime = manager.mountedShares.first(where: { $0.id == runtimeID }) {
            manager.reveal(runtime)
        } else if let mountPoint = requestedMountPoint(for: mountID) {
            NSWorkspace.shared.activateFileViewerSelecting([mountPoint])
        }
    }

    func delete(_ mountIDs: Set<UUID>) async {
        guard !mountIDs.isEmpty else { return }
        for mountID in mountIDs { await unmount(mountID) }
        let stillMounted = mountIDs.filter { runtimeIDs[$0] != nil }
        guard stillMounted.isEmpty else {
            generalError = "Unmount the selected volumes before deleting them."
            return
        }
        let original = mounts
        let updated = mounts.filter { !mountIDs.contains($0.id) }
        do {
            try configurationStorage.save(updated)
            mounts = updated
            for id in mountIDs {
                try? accessKeyStorage.removeAccessKey(for: id)
                healthSnapshots[id] = nil
                errors[id] = nil
            }
            generalError = nil
        } catch {
            mounts = original
            generalError = "Unable to delete the mount: \(error.localizedDescription)"
        }
    }

    private func validatedMount(
        id: UUID,
        name: String,
        sourceURL: String,
        mountPoint: URL?,
        readOnly: Bool
    ) throws -> SavedGhostFileMount {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw GhostFileMountLibraryError.emptyName }
        guard let url = URL(string: trimmedURL), url.scheme == GhostFileProtocol.urlScheme else {
            throw GhostFileMountLibraryError.invalidURL
        }
        guard GhostFileProtocol.peerPin(from: url) != nil else {
            throw GhostFileMountLibraryError.missingPeerIdentity
        }
        guard let shareID = remoteShareID(from: url),
              let sanitizedURL = sanitizedSourceURL(url) else {
            throw GhostFileMountLibraryError.invalidURL
        }
        let bookmark = try mountPoint?.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        return SavedGhostFileMount(
            id: id,
            shareID: shareID,
            name: trimmedName,
            sourceURL: sanitizedURL.absoluteString,
            mountPointBookmark: bookmark,
            readOnly: readOnly
        )
    }

    private func refreshHealthSnapshots() async {
        for missing in manager.reconcileMountedShares() {
            let mountID = missing.definitionID
            runtimeIDs[mountID] = nil
            let detail = healthSnapshots[mountID]?.detail
                ?? "The mounted volume is no longer registered by macOS."
            errors[mountID] = detail
            healthSnapshots[mountID] = nil
        }
        let mountedInstances = runtimeIDs
        let snapshotsByRuntimeID = await Task.detached(priority: .utility) {
            var result: [UUID: GhostFileMountHealthSnapshot] = [:]
            for runtimeID in mountedInstances.values {
                let url = GhostFileMountHealthStorage.readerURL(for: runtimeID)
                guard let data = try? Data(contentsOf: url),
                      let snapshot = try? JSONDecoder().decode(
                        GhostFileMountHealthSnapshot.self,
                        from: data
                      ) else { continue }
                result[runtimeID] = snapshot.degradingIfStale()
            }
            return result
        }.value

        var updated: [UUID: GhostFileMountHealthSnapshot] = [:]
        for (mountID, runtimeID) in runtimeIDs where mountedInstances[mountID] == runtimeID {
            if let snapshot = snapshotsByRuntimeID[runtimeID] {
                updated[mountID] = snapshot
            }
        }
        if healthSnapshots != updated {
            healthSnapshots = updated
        }
    }

    private func remoteShareID(from url: URL) -> UUID? {
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count == 3, parts[0] == "v1", parts[1] == "shares" else { return nil }
        return UUID(uuidString: String(parts[2]))
    }

    private func sanitizedSourceURL(_ url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.queryItems = (components.queryItems ?? []).filter {
            $0.name != "access_key" && $0.name != GhostFileProtocol.mountInstanceQueryName
        }
        if components.queryItems?.isEmpty == true { components.queryItems = nil }
        return components.url
    }
}

private enum GhostFileMountLibraryError: LocalizedError {
    case mountNotFound
    case emptyName
    case emptyAccessKey
    case missingAccessKey
    case missingPeerIdentity
    case invalidURL
    case unmountBeforeEditing
    case runtimeFailure(String)

    var errorDescription: String? {
        switch self {
        case .mountNotFound: "The saved mount no longer exists."
        case .emptyName: "Enter a volume name."
        case .emptyAccessKey: "Enter an access key."
        case .missingAccessKey: "The saved access key is missing."
        case .missingPeerIdentity: "The share URL is missing a valid TLS identity pin. Copy a new link from the sharing Mac."
        case .invalidURL: "Enter a valid ghostfile:// share URL."
        case .unmountBeforeEditing: "Unmount this volume before editing its connection settings."
        case .runtimeFailure(let detail): detail
        }
    }
}
