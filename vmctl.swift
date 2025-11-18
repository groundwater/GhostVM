import Foundation
import AppKit
import Virtualization
import Darwin
import ObjectiveC
import CoreGraphics

private var windowDelegateAssociationKey: UInt8 = 0

private func pixelsPerInch(for screen: NSScreen) -> Int {
    if let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
        let displayID = CGDirectDisplayID(screenNumber.uint32Value)
        let sizeMillimeters = CGDisplayScreenSize(displayID)
        let pixelWidth = CGDisplayPixelsWide(displayID)
        if sizeMillimeters.width > 0 {
            let widthInches = Double(sizeMillimeters.width) / 25.4
            let computed = Double(pixelWidth) / widthInches
            if computed.isFinite, computed > 0 {
                return max(Int(computed.rounded()), 72)
            }
        }
    }
    let scale = max(screen.backingScaleFactor, 1.0)
    return max(Int((110.0 * scale).rounded()), 110)
}

// MARK: - Utilities

enum VMError: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        switch self {
        case .message(let text):
            return text
        }
    }
}

// Persisted VM metadata. Everything lives in config.json inside the bundle.
struct VMStoredConfig: Codable {
    var version: Int
    var createdAt: Date
    var modifiedAt: Date
    var cpus: Int
    var memoryBytes: UInt64
    var diskBytes: UInt64
    var restoreImagePath: String
    var hardwareModelPath: String
    var machineIdentifierPath: String
    var auxiliaryStoragePath: String
    var diskPath: String
    var sharedFolderPath: String?
    var sharedFolderReadOnly: Bool
    var installed: Bool
    var lastInstallBuild: String?
    var lastInstallVersion: String?
    var lastInstallDate: Date?
    var legacyName: String?

    enum CodingKeys: String, CodingKey {
        case version
        case createdAt
        case modifiedAt
        case cpus
        case memoryBytes
        case diskBytes
        case restoreImagePath
        case hardwareModelPath
        case machineIdentifierPath
        case auxiliaryStoragePath
        case diskPath
        case sharedFolderPath
        case sharedFolderReadOnly
        case installed
        case lastInstallBuild
        case lastInstallVersion
        case lastInstallDate
        case legacyName = "name"
    }

    mutating func normalize(relativeTo layout: VMFileLayout) -> Bool {
        var changed = false
        let basePath = layout.bundleURL.standardizedFileURL.path

        func makeRelative(_ path: String) -> (String, Bool) {
            guard path.hasPrefix("/") else { return (path, false) }
            let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
            if standardized.hasPrefix(basePath + "/") {
                let relative = String(standardized.dropFirst(basePath.count + 1))
                if relative != path {
                    return (relative, true)
                }
            }
            let filename = URL(fileURLWithPath: path).lastPathComponent
            if filename != path {
                return (filename, true)
            }
            return (path, false)
        }

        func makeAbsolute(_ path: String) -> (String, Bool) {
            let expanded = (path as NSString).expandingTildeInPath
            let resolved = expanded.isEmpty ? path : expanded
            let absolute = URL(fileURLWithPath: resolved).standardizedFileURL.path
            if absolute != path {
                return (absolute, true)
            }
            return (path, false)
        }

        let relPaths = [
            ("auxiliaryStoragePath", auxiliaryStoragePath),
            ("diskPath", diskPath),
            ("hardwareModelPath", hardwareModelPath),
            ("machineIdentifierPath", machineIdentifierPath)
        ]

        for (key, value) in relPaths {
            let (relative, didChange) = makeRelative(value)
            if didChange {
                changed = true
            }
            switch key {
            case "auxiliaryStoragePath": auxiliaryStoragePath = relative
            case "diskPath": diskPath = relative
            case "hardwareModelPath": hardwareModelPath = relative
            case "machineIdentifierPath": machineIdentifierPath = relative
            default: break
            }
        }

        let (absoluteRestore, restoreChanged) = makeAbsolute(restoreImagePath)
        if restoreChanged {
            restoreImagePath = absoluteRestore
            changed = true
        }

        if let shared = sharedFolderPath {
            let (absoluteShared, sharedChanged) = makeAbsolute(shared)
            if sharedChanged {
                sharedFolderPath = absoluteShared
                changed = true
            }
        }

        if legacyName != nil {
            legacyName = nil
            changed = true
        }

        return changed
    }
}

final class VMFileLayout {
    let fileManager = FileManager.default
    let bundleURL: URL

    init(bundleURL: URL) {
        self.bundleURL = bundleURL
    }

    var configURL: URL { bundleURL.appendingPathComponent("config.json") }
    var diskURL: URL { bundleURL.appendingPathComponent("disk.img") }
    var hardwareModelURL: URL { bundleURL.appendingPathComponent("HardwareModel.bin") }
    var machineIdentifierURL: URL { bundleURL.appendingPathComponent("MachineIdentifier.bin") }
    var auxiliaryStorageURL: URL { bundleURL.appendingPathComponent("AuxiliaryStorage.bin") }
    var pidFileURL: URL { bundleURL.appendingPathComponent("vmctl.pid") }
    var snapshotsDirectoryURL: URL { bundleURL.appendingPathComponent("Snapshots") }

    func ensureBundleDirectory() throws {
        if !fileManager.fileExists(atPath: bundleURL.path) {
            try fileManager.createDirectory(at: bundleURL, withIntermediateDirectories: true, attributes: nil)
        }
    }
}

// MARK: - Restore Image Loading

func loadRestoreImage(from url: URL) throws -> VZMacOSRestoreImage {
    let semaphore = DispatchSemaphore(value: 0)
    var result: Result<VZMacOSRestoreImage, Error> = .failure(VMError.message("Unknown restore image load error"))
    VZMacOSRestoreImage.load(from: url) { loadResult in
        result = loadResult
        semaphore.signal()
    }
    semaphore.wait()
    return try result.get()
}

// MARK: - Configuration Loading & Saving

final class VMConfigStore {
    private let layout: VMFileLayout

    init(layout: VMFileLayout) {
        self.layout = layout
    }

    func load() throws -> VMStoredConfig {
        let data = try Data(contentsOf: layout.configURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var config = try decoder.decode(VMStoredConfig.self, from: data)
        if config.normalize(relativeTo: layout) {
            try save(config)
        }
        return config
    }

    func save(_ config: VMStoredConfig) throws {
        var updated = config
        updated.modifiedAt = Date()
        _ = updated.normalize(relativeTo: layout)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(updated)
        try data.write(to: layout.configURL, options: .atomic)
    }
}

// MARK: - Size Parsing Helpers

func parseBytes(from argument: String, defaultUnit: UInt64 = 1) throws -> UInt64 {
    enum SizeError: Error {
        case invalid(String)
    }
    let lower = argument.lowercased()
    if let value = UInt64(lower) {
        return value * defaultUnit
    }
    let suffixes: [(String, UInt64)] = [
        ("tb", 1 << 40),
        ("t", 1 << 40),
        ("gb", 1 << 30),
        ("g", 1 << 30),
        ("mb", 1 << 20),
        ("m", 1 << 20),
        ("kb", 1 << 10),
        ("k", 1 << 10)
    ]
    for (suffix, multiplier) in suffixes {
        if lower.hasSuffix(suffix) {
            let numericPart = lower.dropLast(suffix.count)
            guard let value = UInt64(numericPart) else {
                throw VMError.message("Could not parse size from '\(argument)'.")
            }
            return value * multiplier
        }
    }
    throw VMError.message("Unrecognized size '\(argument)'. Use values like 64G, 8192M, or 65536.")
}

func standardizedAbsolutePath(_ path: String) -> String {
    let expanded = (path as NSString).expandingTildeInPath
    let resolved = expanded.isEmpty ? path : expanded
    return URL(fileURLWithPath: resolved).standardizedFileURL.path
}

// MARK: - Restore Image Discovery

func discoverRestoreImage(explicitPath: String?) throws -> URL {
    let fm = FileManager.default
    if let explicit = explicitPath {
        let url = URL(fileURLWithPath: explicit).standardizedFileURL
        guard fm.fileExists(atPath: url.path) else {
            throw VMError.message("Restore image '\(url.path)' does not exist.")
        }
        return url
    }

    var candidates: [URL] = []
    let home = fm.homeDirectoryForCurrentUser
    let potentialDirectories: [URL] = [
        home.appendingPathComponent("Downloads"),
        URL(fileURLWithPath: "/Applications", isDirectory: true)
    ]

    if let downloadsEnumerator = fm.enumerator(at: potentialDirectories[0], includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
        for case let fileURL as URL in downloadsEnumerator {
            if fileURL.pathExtension.lowercased() == "ipsw" {
                candidates.append(fileURL)
            }
        }
    }

    if let applications = try? fm.contentsOfDirectory(at: potentialDirectories[1], includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles) {
        for app in applications where app.pathExtension == "app" && app.lastPathComponent.lowercased().contains("install macos") {
            let restore = app.appendingPathComponent("Contents/SharedSupport/SharedSupport.dmg")
            if fm.fileExists(atPath: restore.path) {
                candidates.append(restore)
            }
        }
    }

    if let chosen = candidates.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).first {
        return chosen
    }

    throw VMError.message("""
No macOS restore image found. Download one with:
  softwareupdate --fetch-full-installer
Then re-run with --restore-image <path>.
""")
}

// MARK: - Hardware & Identifier Persistence

func writeData(_ data: Data, to url: URL) throws {
    let directory = url.deletingLastPathComponent()
    if !FileManager.default.fileExists(atPath: directory.path) {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
    }
    try data.write(to: url, options: .atomic)
}

func loadHardwareModel(from url: URL) throws -> VZMacHardwareModel {
    let data = try Data(contentsOf: url)
    guard let model = VZMacHardwareModel(dataRepresentation: data) else {
        throw VMError.message("Failed to decode hardware model at \(url.path).")
    }
    guard model.isSupported else {
        throw VMError.message("Hardware model stored at \(url.path) is not supported on this host.")
    }
    return model
}

func loadMachineIdentifier(from url: URL) throws -> VZMacMachineIdentifier {
    let data = try Data(contentsOf: url)
    guard let identifier = VZMacMachineIdentifier(dataRepresentation: data) else {
        throw VMError.message("Failed to decode machine identifier at \(url.path).")
    }
    return identifier
}

// MARK: - VM Configuration Factory

final class VMConfigurationBuilder {
    let layout: VMFileLayout
    let storedConfig: VMStoredConfig

    init(layout: VMFileLayout, storedConfig: VMStoredConfig) {
        self.layout = layout
        self.storedConfig = storedConfig
    }

    func makeConfiguration(headless: Bool, connectSerialToStandardIO: Bool, runtimeSharedFolder: RuntimeSharedFolderOverride?) throws -> VZVirtualMachineConfiguration {
        let config = VZVirtualMachineConfiguration()
        config.bootLoader = VZMacOSBootLoader()
        config.cpuCount = storedConfig.cpus
        config.memorySize = storedConfig.memoryBytes

        let platform = VZMacPlatformConfiguration()
        let hardwareModel = try loadHardwareModel(from: layout.hardwareModelURL)
        let machineIdentifier = try loadMachineIdentifier(from: layout.machineIdentifierURL)
        platform.hardwareModel = hardwareModel
        platform.machineIdentifier = machineIdentifier
        platform.auxiliaryStorage = VZMacAuxiliaryStorage(url: layout.auxiliaryStorageURL)
        config.platform = platform

        // Attach the raw disk image as the primary boot volume.
        let diskAttachment = try VZDiskImageStorageDeviceAttachment(url: layout.diskURL, readOnly: false)
        let diskDevice = VZVirtioBlockDeviceConfiguration(attachment: diskAttachment)
        diskDevice.blockDeviceIdentifier = "macos-root"
        config.storageDevices = [diskDevice]

        // Basic NAT networking so the guest can reach the internet via the host.
        let networkDevice = VZVirtioNetworkDeviceConfiguration()
        networkDevice.attachment = VZNATNetworkDeviceAttachment()
        config.networkDevices = [networkDevice]

        // Serial console is always present; in headless mode we bridge STDIN/STDOUT so the user
        // can interact with launchd logs or a shell during early boot.
        let serialConfig = VZVirtioConsoleDeviceSerialPortConfiguration()
        if connectSerialToStandardIO {
            serialConfig.attachment = VZFileHandleSerialPortAttachment(
                fileHandleForReading: FileHandle.standardInput,
                fileHandleForWriting: FileHandle.standardOutput
            )
        } else {
            serialConfig.attachment = VZFileHandleSerialPortAttachment(
                fileHandleForReading: nil,
                fileHandleForWriting: FileHandle.standardOutput
            )
        }
        config.serialPorts = [serialConfig]

        if !headless {
            // GUI mode attaches a single display plus keyboard and pointing devices so VZVirtualMachineView works.
            let graphics = VZMacGraphicsDeviceConfiguration()
            let display: VZMacGraphicsDisplayConfiguration
            if let mainScreen = NSScreen.main {
                if #available(macOS 14.0, *) {
                    display = VZMacGraphicsDisplayConfiguration(for: mainScreen, sizeInPoints: mainScreen.frame.size)
                } else {
                    let scale = max(mainScreen.backingScaleFactor, 1.0)
                    var width = max(Int((mainScreen.frame.width * scale).rounded()), 1024)
                    var height = max(Int((mainScreen.frame.height * scale).rounded()), 768)
                    if let screenNumber = mainScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                        let displayID = CGDirectDisplayID(screenNumber.uint32Value)
                        let displayWidth = CGDisplayPixelsWide(displayID)
                        let displayHeight = CGDisplayPixelsHigh(displayID)
                        if displayWidth > 0, displayHeight > 0 {
                            width = max(Int(displayWidth), 1024)
                            height = max(Int(displayHeight), 768)
                        }
                    }
                    let defaultPixelsPerInch = pixelsPerInch(for: mainScreen)
                    display = VZMacGraphicsDisplayConfiguration(widthInPixels: width, heightInPixels: height, pixelsPerInch: defaultPixelsPerInch)
                }
            } else {
                display = VZMacGraphicsDisplayConfiguration(widthInPixels: 2560, heightInPixels: 1600, pixelsPerInch: 110)
            }
            graphics.displays = [display]
            config.graphicsDevices = [graphics]
            config.keyboards = [VZUSBKeyboardConfiguration()]
            config.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
        } else {
            config.graphicsDevices = []
            config.keyboards = []
            config.pointingDevices = []
        }

        let sharedFolderSelection: (path: String, readOnly: Bool)?
        if let runtimeSharedFolder = runtimeSharedFolder {
            sharedFolderSelection = (runtimeSharedFolder.path, runtimeSharedFolder.readOnly)
        } else if let storedPath = storedConfig.sharedFolderPath {
            sharedFolderSelection = (storedPath, storedConfig.sharedFolderReadOnly)
        } else {
            sharedFolderSelection = nil
        }

        if let selection = sharedFolderSelection {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: selection.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw VMError.message("Shared folder path \(selection.path) does not exist or is not a directory.")
            }
            let url = URL(fileURLWithPath: selection.path)
            let sharedDirectory = VZSharedDirectory(url: url, readOnly: selection.readOnly)
            let singleShare = VZSingleDirectoryShare(directory: sharedDirectory)
            let shareDevice = VZVirtioFileSystemDeviceConfiguration(tag: VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag)
            shareDevice.share = singleShare
            config.directorySharingDevices = [shareDevice]
        } else {
            config.directorySharingDevices = []
        }

        do {
            try config.validate()
        } catch {
            throw VMError.message("Invalid VM configuration: \(error.localizedDescription)")
        }
        return config
    }
}

// MARK: - PID / Lock Tracking

enum VMLockOwner: Equatable {
    case cli(pid_t)
    case embedded(pid_t)

    var pid: pid_t {
        switch self {
        case .cli(let pid), .embedded(let pid):
            return pid
        }
    }

    var isEmbedded: Bool {
        if case .embedded = self { return true }
        return false
    }
}

func readVMLockOwner(from url: URL) -> VMLockOwner? {
    guard let data = try? Data(contentsOf: url),
          let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
          !text.isEmpty else {
        return nil
    }

    if text.hasPrefix("embedded:") {
        let suffix = text.dropFirst("embedded:".count)
        if let pid = pid_t(suffix) {
            return .embedded(pid)
        }
        return nil
    }

    if let pid = pid_t(text) {
        return .cli(pid)
    }
    return nil
}

func writeVMLockOwner(_ owner: VMLockOwner, to url: URL) throws {
    let prefix = owner.isEmbedded ? "embedded:" : ""
    try "\(prefix)\(owner.pid)\n".data(using: .utf8)?.write(to: url, options: .atomic)
}

func removeVMLock(at url: URL) {
    try? FileManager.default.removeItem(at: url)
}

// MARK: - Snapshot Management

func sanitizedSnapshotName(_ name: String) throws -> String {
    guard name.range(of: #"[\/]"#, options: .regularExpression) == nil else {
        throw VMError.message("Snapshot name cannot contain path separators.")
    }
    guard !name.isEmpty else {
        throw VMError.message("Snapshot name must not be empty.")
    }
    return name
}

func copyItem(from source: URL, to destination: URL) throws {
    if FileManager.default.fileExists(atPath: destination.path) {
        try FileManager.default.removeItem(at: destination)
    }
    try FileManager.default.copyItem(at: source, to: destination)
}

// MARK: - Commands

struct InitOptions {
    var cpus: Int = 4
    var memoryGiB: UInt64 = 8
    var diskGiB: UInt64 = 64
    var restoreImagePath: String?
    var sharedFolderPath: String?
    var sharedFolderWritable: Bool = false
}

struct RuntimeSharedFolderOverride {
    let path: String
    let readOnly: Bool
}

final class VMController {
    // Primary bundle extension for new VMs.
    static let bundleExtension = "FixieVM"
    static let bundleExtensionLowercased = bundleExtension.lowercased()
    // Legacy extension accepted for backward compatibility.
    static let legacyBundleExtension = "GhostVM"
    static let legacyBundleExtensionLowercased = legacyBundleExtension.lowercased()

    private let fileManager = FileManager.default
    private var rootDirectory: URL

    init(rootDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("VMs", isDirectory: true)) {
        self.rootDirectory = rootDirectory
    }

    var currentRootDirectory: URL {
        return rootDirectory
    }

    func updateRootDirectory(_ url: URL) {
        rootDirectory = url
    }

    private func layoutForExistingBundle(at bundleURL: URL) throws -> VMFileLayout {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: bundleURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw VMError.message("VM bundle '\(bundleURL.path)' does not exist.")
        }
        return VMFileLayout(bundleURL: bundleURL)
    }

    private func defaultName(for bundleURL: URL) -> String {
        let candidate = bundleURL.deletingPathExtension().lastPathComponent
        if candidate.isEmpty {
            return bundleURL.lastPathComponent
        }
        return candidate
    }

    private func displayName(for bundleURL: URL) -> String {
        return defaultName(for: bundleURL)
    }

    struct VMListEntry {
        let name: String
        let bundleURL: URL
        let installed: Bool
        let runningPID: pid_t?
        let managedInProcess: Bool
        let cpuCount: Int
        let memoryBytes: UInt64
        let diskBytes: UInt64

        var isRunning: Bool {
            return managedInProcess || runningPID != nil
        }

        var statusDescription: String {
            if managedInProcess {
                if let pid = runningPID {
                    return "Running (managed by app, PID \(pid))"
                }
                return "Running (managed by app)"
            }
            if let pid = runningPID {
                return "Running (PID \(pid))"
            }
            if !installed {
                return "Not Installed"
            }
            return "Stopped"
        }

        func withManagedInProcess(_ value: Bool) -> VMListEntry {
            return VMListEntry(
                name: name,
                bundleURL: bundleURL,
                installed: installed,
                runningPID: runningPID,
                managedInProcess: value,
                cpuCount: cpuCount,
                memoryBytes: memoryBytes,
                diskBytes: diskBytes
            )
        }
    }

    func listVMs() throws -> [VMListEntry] {
        return try listVMs(in: rootDirectory)
    }

    func listVMs(in directory: URL) throws -> [VMListEntry] {
        guard fileManager.fileExists(atPath: directory.path) else {
            return []
        }

        let contents = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        var entries: [VMListEntry] = []

        for item in contents where isSupportedBundleURL(item) {
            if let entry = try? loadEntry(for: item) {
                entries.append(entry)
            }
        }

        return sortEntries(entries)
    }

    func listVMs(at bundleURLs: [URL]) -> [VMListEntry] {
        var entries: [VMListEntry] = []
        var seen: Set<String> = []
        for url in bundleURLs {
            let standardized = url.standardizedFileURL
            guard isSupportedBundleURL(standardized) else { continue }
            let path = standardized.path
            guard !seen.contains(path) else { continue }
            if let entry = try? loadEntry(for: standardized) {
                entries.append(entry)
                seen.insert(path)
            }
        }
        return sortEntries(entries)
    }

    private func sortEntries(_ entries: [VMListEntry]) -> [VMListEntry] {
        return entries.sorted {
            let comparison = $0.name.localizedCaseInsensitiveCompare($1.name)
            if comparison == .orderedSame {
                return $0.bundleURL.path < $1.bundleURL.path
            }
            return comparison == .orderedAscending
        }
    }

    func loadEntry(for bundleURL: URL) throws -> VMListEntry {
        let standardized = bundleURL.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: standardized.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw VMError.message("VM bundle '\(standardized.path)' does not exist or is not a directory.")
        }

        guard isSupportedBundleURL(standardized) else {
            throw VMError.message("'\(standardized.lastPathComponent)' is not a .\(VMController.bundleExtension) bundle.")
        }

        let layout = VMFileLayout(bundleURL: standardized)
        guard fileManager.fileExists(atPath: layout.configURL.path) else {
            throw VMError.message("Missing config.json inside '\(standardized.path)'.")
        }

        let store = VMConfigStore(layout: layout)
        let config = try store.load()

        var running: pid_t?
        var managedInProcess = false
        if let owner = readVMLockOwner(from: layout.pidFileURL) {
            if kill(owner.pid, 0) == 0 {
                running = owner.pid
                managedInProcess = owner.isEmbedded
            } else {
                removeVMLock(at: layout.pidFileURL)
            }
        }

        return VMListEntry(
            name: displayName(for: standardized),
            bundleURL: standardized,
            installed: config.installed,
            runningPID: running,
            managedInProcess: managedInProcess,
            cpuCount: config.cpus,
            memoryBytes: config.memoryBytes,
            diskBytes: config.diskBytes
        )
    }

    func bundleURL(for name: String) -> URL {
        return rootDirectory.appendingPathComponent("\(name).\(VMController.bundleExtension)", isDirectory: true)
    }

    private func isSupportedBundleURL(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == VMController.bundleExtensionLowercased || ext == VMController.legacyBundleExtensionLowercased
    }

    func storedConfig(at bundleURL: URL) throws -> VMStoredConfig {
        let layout = try layoutForExistingBundle(at: bundleURL)
        let store = VMConfigStore(layout: layout)
        return try store.load()
    }

    func storedConfig(for name: String) throws -> VMStoredConfig {
        return try storedConfig(at: bundleURL(for: name))
    }

    func updateVMSettings(bundleURL: URL, cpus: Int, memoryGiB: UInt64, sharedFolderPath: String?, sharedFolderWritable: Bool) throws {
        let layout = try layoutForExistingBundle(at: bundleURL)
        let vmName = displayName(for: bundleURL)
        guard !isVMProcessRunning(layout: layout) else {
            throw VMError.message("Stop VM '\(vmName)' before editing its settings.")
        }

        var config = try storedConfig(at: bundleURL)

        let minimumCPUs = max(Int(VZVirtualMachineConfiguration.minimumAllowedCPUCount), 1)
        guard cpus >= minimumCPUs else {
            throw VMError.message("CPU count must be at least \(minimumCPUs).")
        }

        guard memoryGiB > 0 else {
            throw VMError.message("Memory must be greater than zero.")
        }
        let memoryBytes = memoryGiB * (1 << 30)
        let minimumMemory = VZVirtualMachineConfiguration.minimumAllowedMemorySize
        guard memoryBytes >= minimumMemory else {
            let minimumGiB = max(1, Int((minimumMemory + ((1 << 30) - 1)) >> 30))
            throw VMError.message("Memory must be at least \(minimumGiB) GiB.")
        }

        var sanitizedSharedPath: String?
        if let path = sharedFolderPath?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty {
            let absolutePath = standardizedAbsolutePath(path)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: absolutePath, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw VMError.message("Shared folder path \(path) does not exist or is not a directory.")
            }
            sanitizedSharedPath = absolutePath
        }

        config.cpus = cpus
        config.memoryBytes = memoryBytes
        config.sharedFolderPath = sanitizedSharedPath
        if sanitizedSharedPath != nil {
            config.sharedFolderReadOnly = !sharedFolderWritable
        } else {
            config.sharedFolderReadOnly = true
        }

        let store = VMConfigStore(layout: layout)
        try store.save(config)
    }

    func updateVMSettings(name: String, cpus: Int, memoryGiB: UInt64, sharedFolderPath: String?, sharedFolderWritable: Bool) throws {
        try updateVMSettings(bundleURL: bundleURL(for: name), cpus: cpus, memoryGiB: memoryGiB, sharedFolderPath: sharedFolderPath, sharedFolderWritable: sharedFolderWritable)
    }

    func initVM(at providedBundleURL: URL, preferredName: String? = nil, options: InitOptions) throws {
        guard VZVirtualMachine.isSupported else {
            throw VMError.message("Virtualization is not supported on this host. Ensure you are on Apple Silicon and virtualization is enabled.")
        }

        var bundleURL = providedBundleURL.standardizedFileURL
        let ext = bundleURL.pathExtension.lowercased()
        if ext.isEmpty {
            bundleURL.appendPathExtension(VMController.bundleExtension)
        } else if ext != VMController.bundleExtensionLowercased && ext != VMController.legacyBundleExtensionLowercased {
            throw VMError.message("Bundle path must end with .\(VMController.bundleExtension) (or legacy .\(VMController.legacyBundleExtension)).")
        }

        let vmName: String
        if let preferred = preferredName?.trimmingCharacters(in: .whitespacesAndNewlines), !preferred.isEmpty {
            vmName = preferred
        } else {
            vmName = defaultName(for: bundleURL)
        }

        guard !vmName.isEmpty else {
            throw VMError.message("VM name cannot be empty.")
        }

        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: bundleURL.path, isDirectory: &isDirectory) {
            throw VMError.message("Bundle \(bundleURL.path) already exists.")
        }

        let layout = VMFileLayout(bundleURL: bundleURL)
        try layout.ensureBundleDirectory()

        let restoreImageURL = try discoverRestoreImage(explicitPath: options.restoreImagePath)
        let restoreImage = try loadRestoreImage(from: restoreImageURL)

        guard let requirements = restoreImage.mostFeaturefulSupportedConfiguration else {
            throw VMError.message("Restore image \(restoreImageURL.path) does not offer a supported configuration on this host.")
        }

        let hardwareModel = requirements.hardwareModel
        guard hardwareModel.isSupported else {
            throw VMError.message("Hardware model \(hardwareModel) from restore image is not supported on this host.")
        }

        let minCPUs = max(Int(requirements.minimumSupportedCPUCount), Int(VZVirtualMachineConfiguration.minimumAllowedCPUCount))
        let minMemory = max(requirements.minimumSupportedMemorySize, VZVirtualMachineConfiguration.minimumAllowedMemorySize)

        if options.cpus < minCPUs {
            throw VMError.message("CPU count \(options.cpus) is below minimum required \(minCPUs).")
        }

        let requestedMemoryBytes = options.memoryGiB * (1 << 30)
        if requestedMemoryBytes < minMemory {
            throw VMError.message("Memory \(options.memoryGiB) GiB is below minimum required \(minMemory >> 30) GiB.")
        }

        let requestedDiskBytes = options.diskGiB * (1 << 30)
        if requestedDiskBytes < (20 * (1 << 30)) {
            throw VMError.message("Disk size must be at least 20 GiB.")
        }

        let machineIdentifier = VZMacMachineIdentifier()

        try writeData(hardwareModel.dataRepresentation, to: layout.hardwareModelURL)
        try writeData(machineIdentifier.dataRepresentation, to: layout.machineIdentifierURL)

        do {
            _ = try VZMacAuxiliaryStorage(creatingStorageAt: layout.auxiliaryStorageURL, hardwareModel: hardwareModel, options: [.allowOverwrite])
        } catch {
            throw VMError.message("Failed to create auxiliary storage: \(error.localizedDescription)")
        }

        if !fileManager.createFile(atPath: layout.diskURL.path, contents: nil, attributes: nil) {
            throw VMError.message("Failed to create disk image at \(layout.diskURL.path).")
        }
        let handle = try FileHandle(forWritingTo: layout.diskURL)
        try handle.truncate(atOffset: requestedDiskBytes)
        try handle.close()

        var sharedFolderAbsolute: String?
        if let sharedPath = options.sharedFolderPath {
            let absoluteShared = standardizedAbsolutePath(sharedPath)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: absoluteShared, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw VMError.message("Shared folder path \(absoluteShared) does not exist or is not a directory.")
            }
            sharedFolderAbsolute = absoluteShared
        }

        if !fileManager.fileExists(atPath: layout.snapshotsDirectoryURL.path) {
            try fileManager.createDirectory(at: layout.snapshotsDirectoryURL, withIntermediateDirectories: true, attributes: nil)
        }

        let config = VMStoredConfig(
            version: 1,
            createdAt: Date(),
            modifiedAt: Date(),
            cpus: options.cpus,
            memoryBytes: requestedMemoryBytes,
            diskBytes: requestedDiskBytes,
            restoreImagePath: restoreImageURL.standardizedFileURL.path,
            hardwareModelPath: layout.hardwareModelURL.lastPathComponent,
            machineIdentifierPath: layout.machineIdentifierURL.lastPathComponent,
            auxiliaryStoragePath: layout.auxiliaryStorageURL.lastPathComponent,
            diskPath: layout.diskURL.lastPathComponent,
            sharedFolderPath: sharedFolderAbsolute,
            sharedFolderReadOnly: !options.sharedFolderWritable,
            installed: false,
            lastInstallBuild: nil,
            lastInstallVersion: nil,
            lastInstallDate: nil,
            legacyName: nil
        )

        let store = VMConfigStore(layout: layout)
        try store.save(config)

        print("Initialized macOS VM '\(vmName)' at \(bundleURL.path).")
        print("Restore image: \(restoreImageURL.path)")
        print("Hardware model saved to \(layout.hardwareModelURL.path)")
        print("Disk size: \(options.diskGiB) GiB, Memory: \(options.memoryGiB) GiB, vCPUs: \(options.cpus)")
    }

    func initVM(name: String, options: InitOptions) throws {
        try initVM(at: bundleURL(for: name), preferredName: name, options: options)
    }

    func moveVMToTrash(bundleURL: URL) throws {
        let layout = try layoutForExistingBundle(at: bundleURL)
        let vmName = displayName(for: bundleURL)
        if let owner = readVMLockOwner(from: layout.pidFileURL), kill(owner.pid, 0) == 0 {
            if owner.isEmbedded {
                throw VMError.message("VM '\(vmName)' is running inside GhostVM. Stop it before deleting.")
            }
            throw VMError.message("VM '\(vmName)' is running. Stop it before deleting.")
        }

        do {
            try fileManager.trashItem(at: bundleURL, resultingItemURL: nil)
        } catch {
            throw VMError.message("Failed to move VM to Trash: \(error.localizedDescription)")
        }
    }

    func moveVMToTrash(name: String) throws {
        try moveVMToTrash(bundleURL: bundleURL(for: name))
    }

    func installVM(bundleURL: URL) throws {
        let layout = try layoutForExistingBundle(at: bundleURL)
        let store = VMConfigStore(layout: layout)
        var config = try store.load()
        let vmName = displayName(for: bundleURL)

        guard !isVMProcessRunning(layout: layout) else {
            throw VMError.message("VM '\(vmName)' appears to be running. Stop it before installing.")
        }

        let restoreImageURL = URL(fileURLWithPath: config.restoreImagePath)
        let restoreImage = try loadRestoreImage(from: restoreImageURL)

        let builder = VMConfigurationBuilder(layout: layout, storedConfig: config)
        let vmConfiguration = try builder.makeConfiguration(headless: false, connectSerialToStandardIO: true, runtimeSharedFolder: nil)

        let vmQueue = DispatchQueue(label: "vmctl.install.\(vmName)")
        let virtualMachine = VZVirtualMachine(configuration: vmConfiguration, queue: vmQueue)

        let installer: VZMacOSInstaller = vmQueue.sync {
            VZMacOSInstaller(virtualMachine: virtualMachine, restoringFromImageAt: restoreImageURL)
        }

        let progress = installer.progress
        let observation = progress.observe(\.fractionCompleted, options: [.new]) { progress, _ in
            let description = progress.localizedDescription ?? ""
            print("Install progress: \(description)")
        }

        let group = DispatchGroup()
        group.enter()
        vmQueue.async {
            installer.install { result in
                switch result {
                case .success:
                    print("Installation completed successfully.")
                case .failure(let error):
                    print("Installation failed: \(error.localizedDescription)")
                }
                group.leave()
            }
        }
        group.wait()
        observation.invalidate()

        if installer.progress.isCancelled {
            throw VMError.message("Installation cancelled.")
        }

        if installer.progress.completedUnitCount < installer.progress.totalUnitCount {
            throw VMError.message("Installation did not complete.")
        }

        config.installed = true
        config.lastInstallBuild = restoreImage.buildVersion
        let osVersion = restoreImage.operatingSystemVersion
        config.lastInstallVersion = "\(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)"
        config.lastInstallDate = Date()
        try store.save(config)

        print("Metadata updated for \(vmName). Consider enabling Remote Login (SSH) inside the guest for headless workflows.")
        print("Reminder: Apple’s EULA requires macOS guests to run on Apple-branded hardware.")
    }

    func installVM(name: String) throws {
        try installVM(bundleURL: bundleURL(for: name))
    }

    func startVM(bundleURL: URL, headless: Bool, runtimeSharedFolder: RuntimeSharedFolderOverride?) throws -> Never {
        let layout = try layoutForExistingBundle(at: bundleURL)
        let store = VMConfigStore(layout: layout)
        let config = try store.load()
        let vmName = displayName(for: bundleURL)

        if let owner = readVMLockOwner(from: layout.pidFileURL) {
            if kill(owner.pid, 0) == 0 {
                if owner.isEmbedded {
                    throw VMError.message("VM '\(vmName)' is running inside GhostVM (PID \(owner.pid)). Stop it there before starting via CLI.")
                } else {
                    throw VMError.message("VM '\(vmName)' is already running under PID \(owner.pid).")
                }
            } else {
                removeVMLock(at: layout.pidFileURL)
            }
        }

        let builder = VMConfigurationBuilder(layout: layout, storedConfig: config)
        let vmConfiguration = try builder.makeConfiguration(headless: headless, connectSerialToStandardIO: headless, runtimeSharedFolder: runtimeSharedFolder)
        let vmQueue = DispatchQueue(label: "vmctl.run.\(vmName)")
        let virtualMachine = VZVirtualMachine(configuration: vmConfiguration, queue: vmQueue)
        let pid = getpid()
        try writeVMLockOwner(.cli(pid), to: layout.pidFileURL)

        // A single closure runs all exit paths so we never leave stale pid files behind.
        func cleanupAndExit(_ code: Int32) -> Never {
            removeVMLock(at: layout.pidFileURL)
            exit(code)
        }

        class Delegate: NSObject, VZVirtualMachineDelegate {
            let stopHandler: (Int32) -> Never

            init(stopHandler: @escaping (Int32) -> Never) {
                self.stopHandler = stopHandler
            }

            func guestDidStop(_ virtualMachine: VZVirtualMachine) {
                print("Guest shut down gracefully.")
                _ = stopHandler(0)
            }

            func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
                print("Virtual machine stopped with error: \(error.localizedDescription)")
                _ = stopHandler(1)
            }
        }

        let delegate = Delegate(stopHandler: { code in cleanupAndExit(code) })
        virtualMachine.delegate = delegate

        let startGroup = DispatchGroup()
        startGroup.enter()
        vmQueue.async {
            virtualMachine.start { result in
                switch result {
                case .success:
                    print("VM '\(vmName)' started. PID \(pid). Press Ctrl+C to shut down.")
                    startGroup.leave()
                case .failure(let error):
                    print("Failed to start VM: \(error.localizedDescription)")
                    startGroup.leave()
                    cleanupAndExit(1)
                }
            }
        }
        startGroup.wait()

        // Track whether the next signal should escalate from ACPI power button to a hard stop.
        var shouldForceStop = false

        SignalTrap.shared.register(signals: [SIGINT, SIGTERM])

        SignalTrap.shared.onSignal = { signal in
            vmQueue.async {
                if shouldForceStop {
                    print("Force stopping virtual machine...")
                    virtualMachine.stop { error in
                        if let error = error {
                            print("Force stop failed: \(error.localizedDescription)")
                            cleanupAndExit(1)
                        } else {
                            cleanupAndExit(0)
                        }
                    }
                } else {
                    print("Requesting guest shutdown (signal \(signal)). Repeat signal to force stop.")
                    do {
                        try virtualMachine.requestStop()
                    } catch {
                        print("Failed to request graceful shutdown: \(error.localizedDescription)")
                    }
                    shouldForceStop = true
                }
            }
        }

        let suppressDockIcon = ProcessInfo.processInfo.environment["VMCTL_SUPPRESS_DOCK_ICON"] == "1"

        if headless {
            dispatchMain()
        } else {
            DispatchQueue.main.async {
                let app = NSApplication.shared
                if suppressDockIcon {
                    app.setActivationPolicy(.accessory)
                } else {
                    app.setActivationPolicy(.regular)
                }
                let window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 1024, height: 640),
                    styleMask: [.titled, .closable, .miniaturizable, .resizable],
                    backing: .buffered,
                    defer: false
                )
                window.title = "vmctl – \(vmName)"
                let vmView = VZVirtualMachineView()
                vmView.virtualMachine = virtualMachine
                if #available(macOS 14.0, *) {
                    vmView.automaticallyReconfiguresDisplay = true
                }
                vmView.autoresizingMask = [.width, .height]
                window.contentView = vmView

                final class VMWindowDelegate: NSObject, NSWindowDelegate {
                    private let vmQueue: DispatchQueue
                    private let virtualMachine: VZVirtualMachine
                    private let vmView: VZVirtualMachineView

                    init(vmQueue: DispatchQueue, virtualMachine: VZVirtualMachine, vmView: VZVirtualMachineView) {
                        self.vmQueue = vmQueue
                        self.virtualMachine = virtualMachine
                        self.vmView = vmView
                    }

                    func windowShouldClose(_ sender: NSWindow) -> Bool {
                        switch virtualMachine.state {
                        case .stopped, .stopping:
                            return true
                        default:
                            vmQueue.async {
                                do {
                                    try self.virtualMachine.requestStop()
                                } catch {
                                    print("Failed to request stop via close button: \(error.localizedDescription)")
                                }
                            }
                            return false
                        }
                    }

                    func windowWillClose(_ notification: Notification) {
                        vmView.virtualMachine = nil
                        NSApplication.shared.stop(nil)
                    }
                }

                let windowDelegate = VMWindowDelegate(vmQueue: vmQueue, virtualMachine: virtualMachine, vmView: vmView)
                window.delegate = windowDelegate
                objc_setAssociatedObject(window, &windowDelegateAssociationKey, windowDelegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

                window.center()
                window.makeKeyAndOrderFront(nil)
                app.activate(ignoringOtherApps: true)
            }
            NSApplication.shared.run()
        }

        cleanupAndExit(0)
    }

    func startVM(name: String, headless: Bool, runtimeSharedFolder: RuntimeSharedFolderOverride?) throws -> Never {
        try startVM(bundleURL: bundleURL(for: name), headless: headless, runtimeSharedFolder: runtimeSharedFolder)
    }

    func stopVM(bundleURL: URL, timeout: TimeInterval = 30) throws {
        let layout = try layoutForExistingBundle(at: bundleURL)
        let vmName = displayName(for: bundleURL)
        guard let owner = readVMLockOwner(from: layout.pidFileURL) else {
            print("VM '\(vmName)' does not appear to be running.")
            return
        }
        let pid = owner.pid

        if owner.isEmbedded {
            print("VM '\(vmName)' is running inside GhostVM (PID \(pid)). Stop it from the app.")
            return
        }

        if kill(pid, 0) != 0 {
            print("Stale PID file detected. Cleaning up.")
            removeVMLock(at: layout.pidFileURL)
            return
        }

        print("Sending SIGTERM to VM '\(vmName)' (PID \(pid)) for graceful shutdown.")
        kill(pid, SIGTERM)

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if kill(pid, 0) != 0 {
                print("VM process exited.")
                removeVMLock(at: layout.pidFileURL)
                return
            }
            Thread.sleep(forTimeInterval: 1)
        }

        print("Graceful shutdown timed out for '\(vmName)'. Sending SIGKILL.")
        kill(pid, SIGKILL)
        removeVMLock(at: layout.pidFileURL)
    }

    func stopVM(name: String, timeout: TimeInterval = 30) throws {
        try stopVM(bundleURL: bundleURL(for: name), timeout: timeout)
    }

    func status(bundleURL: URL) throws {
        let layout = try layoutForExistingBundle(at: bundleURL)
        let store = VMConfigStore(layout: layout)
        guard fileManager.fileExists(atPath: layout.configURL.path) else {
            throw VMError.message("VM bundle '\(bundleURL.path)' is missing config.json.")
        }
        let config = try store.load()
        let lockOwner = readVMLockOwner(from: layout.pidFileURL)
        var isRunning = false
        var runningPID: pid_t?
        var managedInProcess = false
        if let owner = lockOwner {
            if kill(owner.pid, 0) == 0 {
                isRunning = true
                runningPID = owner.pid
                managedInProcess = owner.isEmbedded
            } else {
                removeVMLock(at: layout.pidFileURL)
            }
        }

        print("Name: \(displayName(for: bundleURL))")
        print("Bundle: \(bundleURL.path)")
        if isRunning {
            if managedInProcess {
                print("State: running (managed by app, PID \(runningPID!))")
            } else {
                print("State: running (PID \(runningPID!))")
            }
        } else {
            print("State: stopped")
        }
        print(String(format: "vCPUs: %d, Memory: %.1f GiB, Disk: %.1f GiB", config.cpus, Double(config.memoryBytes) / Double(1 << 30), Double(config.diskBytes) / Double(1 << 30)))
        print("Restore image: \(config.restoreImagePath)")
        if let shared = config.sharedFolderPath {
            print("Shared folder: \(shared) (\(config.sharedFolderReadOnly ? "read-only" : "read-write"))")
        }
        if config.installed {
            print("Installed build: \(config.lastInstallBuild ?? "unknown") (\(config.lastInstallVersion ?? "unknown")), last install: \(config.lastInstallDate?.description ?? "unknown")")
        } else {
            print("Installation status: not installed (run 'vmctl install \(bundleURL.path)')")
        }
    }

    func status(name: String) throws {
        try status(bundleURL: bundleURL(for: name))
    }

    func snapshot(bundleURL: URL, subcommand: String, snapshotName: String) throws {
        let layout = try layoutForExistingBundle(at: bundleURL)
        let vmName = displayName(for: bundleURL)
        let sanitized = try sanitizedSnapshotName(snapshotName)
        let snapshotDir = layout.snapshotsDirectoryURL.appendingPathComponent(sanitized, isDirectory: true)

        switch subcommand {
        case "create":
            guard !isVMProcessRunning(layout: layout) else {
                throw VMError.message("Stop the VM before taking a snapshot to avoid inconsistent state.")
            }
            if fileManager.fileExists(atPath: snapshotDir.path) {
                throw VMError.message("Snapshot '\(sanitized)' already exists for '\(vmName)'.")
            }
            try fileManager.createDirectory(at: snapshotDir, withIntermediateDirectories: true, attributes: nil)

            let itemsToCopy = [
                ("config.json", layout.configURL),
                ("disk.img", layout.diskURL),
                ("HardwareModel.bin", layout.hardwareModelURL),
                ("MachineIdentifier.bin", layout.machineIdentifierURL),
                ("AuxiliaryStorage.bin", layout.auxiliaryStorageURL)
            ]

            for (name, sourceURL) in itemsToCopy {
                let dest = snapshotDir.appendingPathComponent(name)
                try copyItem(from: sourceURL, to: dest)
            }

            print("Snapshot '\(sanitized)' created for '\(vmName)' at \(snapshotDir.path). (Coarse-grained copy of bundle files.)")

        case "revert":
            guard fileManager.fileExists(atPath: snapshotDir.path) else {
                throw VMError.message("Snapshot '\(sanitized)' does not exist for '\(vmName)'.")
            }
            guard !isVMProcessRunning(layout: layout) else {
                throw VMError.message("Stop '\(vmName)' before reverting a snapshot.")
            }

            let tempDir = bundleURL.appendingPathComponent(".revert-temp-\(UUID().uuidString)", isDirectory: true)
            try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true, attributes: nil)

            let items = [
                ("config.json", layout.configURL),
                ("disk.img", layout.diskURL),
                ("HardwareModel.bin", layout.hardwareModelURL),
                ("MachineIdentifier.bin", layout.machineIdentifierURL),
                ("AuxiliaryStorage.bin", layout.auxiliaryStorageURL)
            ]

            for (name, targetURL) in items {
                let backupURL = tempDir.appendingPathComponent(name)
                if fileManager.fileExists(atPath: targetURL.path) {
                    try copyItem(from: targetURL, to: backupURL)
                }
                let sourceURL = snapshotDir.appendingPathComponent(name)
                try copyItem(from: sourceURL, to: targetURL)
            }

            try fileManager.removeItem(at: tempDir)
            print("Reverted VM '\(vmName)' to snapshot '\(sanitized)'.")

        default:
            throw VMError.message("Unknown snapshot subcommand '\(subcommand)'. Use 'create' or 'revert'.")
        }
    }

    func snapshot(name: String, subcommand: String, snapshotName: String) throws {
        try snapshot(bundleURL: bundleURL(for: name), subcommand: subcommand, snapshotName: snapshotName)
    }

    private func isVMProcessRunning(layout: VMFileLayout) -> Bool {
        if let owner = readVMLockOwner(from: layout.pidFileURL) {
            if kill(owner.pid, 0) == 0 {
                return true
            }
            removeVMLock(at: layout.pidFileURL)
        }
        return false
    }
}

#if VMCTL_APP
extension VMController {
    func makeEmbeddedSession(bundleURL: URL, runtimeSharedFolder: RuntimeSharedFolderOverride?) throws -> EmbeddedVMSession {
        let layout = try layoutForExistingBundle(at: bundleURL)
        let store = VMConfigStore(layout: layout)
        let config = try store.load()
        let name = displayName(for: bundleURL)

        if let owner = readVMLockOwner(from: layout.pidFileURL) {
            if kill(owner.pid, 0) == 0 {
                if owner.isEmbedded {
                    throw VMError.message("VM '\(name)' is already running inside GhostVM.")
                } else {
                    throw VMError.message("VM '\(name)' is already running under PID \(owner.pid).")
                }
            } else {
                removeVMLock(at: layout.pidFileURL)
            }
        }

        return try EmbeddedVMSession(name: name, bundleURL: bundleURL, layout: layout, storedConfig: config, runtimeSharedFolder: runtimeSharedFolder)
    }

    func makeEmbeddedSession(name: String, runtimeSharedFolder: RuntimeSharedFolderOverride?) throws -> EmbeddedVMSession {
        return try makeEmbeddedSession(bundleURL: bundleURL(for: name), runtimeSharedFolder: runtimeSharedFolder)
    }
}

final class EmbeddedVMSession: NSObject, NSWindowDelegate, VZVirtualMachineDelegate {
    enum State {
        case initialized
        case starting
        case running
        case stopping
        case stopped
    }

    enum SpecialKey {
        case escape
        case `return`
        case tab
        case space
    }

    let name: String
    let bundlePath: String
    let window: NSWindow
    var stateDidChange: ((State) -> Void)?
    var statusChanged: ((String) -> Void)?
    var terminationHandler: ((Result<Void, Error>) -> Void)?

    var isRunning: Bool { state == .running }
    var isStopping: Bool { state == .stopping }

    private let layout: VMFileLayout
    private let virtualMachine: VZVirtualMachine
    private let vmQueue: DispatchQueue
    private let vmView: VZVirtualMachineView
    private var state: State = .initialized {
        didSet {
            if state != oldValue {
                stateDidChange?(state)
            }
        }
    }
    private var ownsLock = false
    private var didTerminate = false
    private var stopContinuations: [(Result<Void, Error>) -> Void] = []

    init(name: String, bundleURL: URL, layout: VMFileLayout, storedConfig: VMStoredConfig, runtimeSharedFolder: RuntimeSharedFolderOverride?) throws {
        self.name = name
        self.bundlePath = bundleURL.path
        self.layout = layout
        let builder = VMConfigurationBuilder(layout: layout, storedConfig: storedConfig)
        let configuration = try builder.makeConfiguration(headless: false, connectSerialToStandardIO: false, runtimeSharedFolder: runtimeSharedFolder)
        self.vmQueue = DispatchQueue(label: "vmctl.embedded.\(name)")
        self.virtualMachine = VZVirtualMachine(configuration: configuration, queue: vmQueue)
        let ui = EmbeddedVMSession.makeWindowAndView(name: name)
        self.window = ui.window
        self.vmView = ui.view
        super.init()

        self.virtualMachine.delegate = self
        configureUIBindings()
    }

    func start(completion: @escaping (Result<Void, Error>) -> Void) {
        guard state == .initialized || state == .stopped else {
            completion(.failure(VMError.message("VM '\(name)' is already starting or running.")))
            return
        }

        state = .starting
        do {
            try writeVMLockOwner(.embedded(ProcessInfo.processInfo.processIdentifier), to: layout.pidFileURL)
            ownsLock = true
        } catch {
            state = .stopped
            completion(.failure(error))
            return
        }

        vmQueue.async {
            self.virtualMachine.start { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success:
                        self.state = .running
                        self.window.center()
                        self.window.makeKeyAndOrderFront(nil)
                        NSApplication.shared.activate(ignoringOtherApps: true)
                        self.statusChanged?("VM \(self.name) started.")
                        completion(.success(()))
                    case .failure(let error):
                        self.state = .stopped
                        if self.ownsLock {
                            removeVMLock(at: self.layout.pidFileURL)
                            self.ownsLock = false
                        }
                        self.statusChanged?("Failed to start \(self.name): \(error.localizedDescription)")
                        completion(.failure(error))
                    }
                }
            }
        }
    }

    func requestStop(force: Bool = false, completion: ((Result<Void, Error>) -> Void)? = nil) {
        if state == .stopped {
            completion?(.success(()))
            return
        }

        if let completion = completion {
            stopContinuations.append(completion)
        }

        let alreadyStopping = state == .stopping
        if !alreadyStopping {
            state = .stopping
            statusChanged?("Stopping \(name)…")
        }

        if force {
            issueForceStop()
        } else if !alreadyStopping {
            issueGracefulStop()
        }
    }

    func bringToFront() {
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func flashDisplay() {
        DispatchQueue.main.async {
            guard let contentView = self.window.contentView else { return }
            let overlay = NSView(frame: contentView.bounds)
            overlay.wantsLayer = true
            overlay.layer?.backgroundColor = NSColor.white.cgColor
            overlay.alphaValue = 0
            overlay.autoresizingMask = [.width, .height]
            contentView.addSubview(overlay)

            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                overlay.animator().alphaValue = 1
            } completionHandler: {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.18
                    overlay.animator().alphaValue = 0
                } completionHandler: {
                    overlay.removeFromSuperview()
                }
            }
        }
    }

    @available(macOS 13.0, *)
    func captureScreenshot(completion: @escaping (Result<CGImage, Error>) -> Void) {
        DispatchQueue.main.async {
            guard let contentView = self.window.contentView else {
                completion(.failure(VMError.message("No content view available for screenshot.")))
                return
            }
            let bounds = contentView.bounds
            guard let bitmap = contentView.bitmapImageRepForCachingDisplay(in: bounds) else {
                completion(.failure(VMError.message("Unable to prepare bitmap for screenshot.")))
                return
            }
            contentView.cacheDisplay(in: bounds, to: bitmap)
            if let cgImage = bitmap.cgImage {
                completion(.success(cgImage))
            } else {
                completion(.failure(VMError.message("Failed to capture screenshot image.")))
            }
        }
    }

    func sendSpecialKey(_ key: SpecialKey) {
        DispatchQueue.main.async {
            guard let window = self.window as NSWindow? else { return }
            window.makeFirstResponder(self.vmView)

            self.sendSimpleKey(key, in: window)
        }
    }

    private func sendSimpleKey(_ key: SpecialKey, in window: NSWindow) {
        let timestamp = ProcessInfo.processInfo.systemUptime
        let modifierFlags: NSEvent.ModifierFlags = []
        let characters: String
        let charactersIgnoringModifiers: String
        let keyCode: UInt16

        switch key {
        case .escape:
            characters = String(UnicodeScalar(0x1b)!)
            charactersIgnoringModifiers = characters
            keyCode = 53
        case .return:
            characters = "\r"
            charactersIgnoringModifiers = characters
            keyCode = 36
        case .tab:
            characters = "\t"
            charactersIgnoringModifiers = characters
            keyCode = 48
        case .space:
            characters = " "
            charactersIgnoringModifiers = characters
            keyCode = 49
        }

        guard let keyDown = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifierFlags,
            timestamp: timestamp,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: charactersIgnoringModifiers,
            isARepeat: false,
            keyCode: keyCode
        ), let keyUp = NSEvent.keyEvent(
            with: .keyUp,
            location: .zero,
            modifierFlags: modifierFlags,
            timestamp: timestamp,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: charactersIgnoringModifiers,
            isARepeat: false,
            keyCode: keyCode
        ) else {
            return
        }

        vmView.keyDown(with: keyDown)
        vmView.keyUp(with: keyUp)
    }

    // MARK: - NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        switch state {
        case .stopped:
            return true
        default:
            requestStop()
            return false
        }
    }

    func windowWillClose(_ notification: Notification) {
        vmView.virtualMachine = nil
    }

    // MARK: - VZVirtualMachineDelegate

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        DispatchQueue.main.async {
            self.handleTermination(result: .success(()))
        }
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        DispatchQueue.main.async {
            self.handleTermination(result: .failure(error))
        }
    }

    // MARK: - Helpers

    private static func makeWindowAndView(name: String) -> (window: NSWindow, view: VZVirtualMachineView) {
        let builder = { () -> (NSWindow, VZVirtualMachineView) in
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1024, height: 640),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Virtual Machine – \(name)"

            let vmView = VZVirtualMachineView()
            if #available(macOS 14.0, *) {
                vmView.automaticallyReconfiguresDisplay = true
            }
            vmView.autoresizingMask = [.width, .height]
            window.contentView = vmView
            return (window, vmView)
        }

        if Thread.isMainThread {
            return builder()
        }

        var result: (NSWindow, VZVirtualMachineView)!
        DispatchQueue.main.sync {
            result = builder()
        }
        return result
    }

    private func configureUIBindings() {
        let work = {
            self.window.delegate = self
            self.window.isReleasedWhenClosed = false
            self.vmView.virtualMachine = self.virtualMachine
        }

        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.sync(execute: work)
        }
    }

    private func issueGracefulStop() {
        vmQueue.async {
            do {
                try self.virtualMachine.requestStop()
            } catch {
                DispatchQueue.main.async {
                    self.statusChanged?("Failed to request stop: \(error.localizedDescription)")
                    self.issueForceStop()
                }
            }
        }
    }

    private func issueForceStop() {
        vmQueue.async {
            self.virtualMachine.stop { error in
                DispatchQueue.main.async {
                    if let error = error {
                        self.handleTermination(result: .failure(error))
                    } else {
                        self.handleTermination(result: .success(()))
                    }
                }
            }
        }
    }

    private func handleTermination(result: Result<Void, Error>) {
        guard !didTerminate else { return }
        didTerminate = true

        if ownsLock {
            removeVMLock(at: layout.pidFileURL)
            ownsLock = false
        }

        state = .stopped
        vmView.virtualMachine = nil
        if window.isVisible {
            window.orderOut(nil)
        }

        terminationHandler?(result)
        if !stopContinuations.isEmpty {
            stopContinuations.forEach { $0(result) }
            stopContinuations.removeAll()
        }
    }

    deinit {
        if ownsLock {
            removeVMLock(at: layout.pidFileURL)
        }
    }
}
#endif

// MARK: - Signal Trap Helper

final class SignalTrap {
    // Wrap Darwin signal handling with GCD so we can hook Ctrl+C cleanly from Swift.
    static let shared = SignalTrap()
    var onSignal: ((Int32) -> Void)?
    private var sources: [DispatchSourceSignal] = []
    private let accessQueue = DispatchQueue(label: "vmctl.signaltrap")

    func register(signals: [Int32]) {
        accessQueue.sync {
            for source in sources {
                source.cancel()
            }
            sources.removeAll()

            for sig in signals {
                Darwin.signal(sig, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
                source.setEventHandler { [weak self] in
                    self?.onSignal?(sig)
                }
                source.resume()
                sources.append(source)
            }
        }
    }
}

// MARK: - CLI Parsing

struct CLI {
    let controller = VMController()

    func run() {
        var arguments = CommandLine.arguments
        arguments.removeFirst()

        if arguments.isEmpty {
            showHelp(exitCode: 0)
        }

        switch arguments[0] {
        case "--help", "-h":
            showHelp(exitCode: 0)
        case "init":
            do {
                try handleInit(arguments: Array(arguments.dropFirst()))
            } catch {
                fail(error)
            }
        case "install":
            do {
                try handleInstall(arguments: Array(arguments.dropFirst()))
            } catch {
                fail(error)
            }
        case "start":
            do {
                try handleStart(arguments: Array(arguments.dropFirst()))
            } catch {
                fail(error)
            }
        case "stop":
            do {
                try handleStop(arguments: Array(arguments.dropFirst()))
            } catch {
                fail(error)
            }
        case "status":
            do {
                try handleStatus(arguments: Array(arguments.dropFirst()))
            } catch {
                fail(error)
            }
        case "snapshot":
            do {
                try handleSnapshot(arguments: Array(arguments.dropFirst()))
            } catch {
                fail(error)
            }
        default:
            print("Unknown command '\(arguments[0])'.")
            showHelp(exitCode: 1)
        }
    }

    private func resolveBundleURL(argument: String, mustExist: Bool) throws -> URL {
        let expanded = (argument as NSString).expandingTildeInPath
        var url = URL(fileURLWithPath: expanded).standardizedFileURL
        let ext = url.pathExtension.lowercased()
        if ext.isEmpty {
            url.appendPathExtension(VMController.bundleExtension)
        } else if ext != VMController.bundleExtensionLowercased && ext != VMController.legacyBundleExtensionLowercased {
            throw VMError.message("Bundle path must end with .\(VMController.bundleExtension) (or legacy .\(VMController.legacyBundleExtension)).")
        }

        if mustExist {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw VMError.message("VM bundle '\(url.path)' does not exist.")
            }
        }

        return url
    }

    private func handleInit(arguments: [String]) throws {
        guard let bundleArg = arguments.first else {
            throw VMError.message("Usage: vmctl init <bundle-path> [options]")
        }
        let bundleURL = try resolveBundleURL(argument: bundleArg, mustExist: false)
        var opts = InitOptions()
        var index = 1
        while index < arguments.count {
            let arg = arguments[index]
            switch arg {
            case "--cpus":
                index += 1
                guard index < arguments.count, let value = Int(arguments[index]), value > 0 else {
                    throw VMError.message("Invalid value for --cpus.")
                }
                opts.cpus = value
            case "--memory":
                index += 1
                guard index < arguments.count else {
                    throw VMError.message("Missing value for --memory.")
                }
                opts.memoryGiB = try parseBytes(from: arguments[index], defaultUnit: 1 << 30) >> 30
            case "--disk":
                index += 1
                guard index < arguments.count else {
                    throw VMError.message("Missing value for --disk.")
                }
                opts.diskGiB = try parseBytes(from: arguments[index], defaultUnit: 1 << 30) >> 30
            case "--restore-image":
                index += 1
                guard index < arguments.count else {
                    throw VMError.message("Missing value for --restore-image.")
                }
                opts.restoreImagePath = arguments[index]
            case "--shared-folder":
                index += 1
                guard index < arguments.count else {
                    throw VMError.message("Missing value for --shared-folder.")
                }
                opts.sharedFolderPath = arguments[index]
            case "--writable":
                opts.sharedFolderWritable = true
            default:
                throw VMError.message("Unknown option '\(arg)'.")
            }
            index += 1
        }
        try controller.initVM(at: bundleURL, preferredName: nil, options: opts)
    }

    private func handleInstall(arguments: [String]) throws {
        guard let bundleArg = arguments.first else {
            throw VMError.message("Usage: vmctl install <bundle-path>")
        }
        let bundleURL = try resolveBundleURL(argument: bundleArg, mustExist: true)
        try controller.installVM(bundleURL: bundleURL)
    }

    private func handleStart(arguments: [String]) throws {
        guard let bundleArg = arguments.first else {
            throw VMError.message("Usage: vmctl start <bundle-path> [--headless] [--shared-folder PATH] [--writable|--read-only]")
        }
        var headless = false
        var sharedFolderPath: String?
        var writableOverride: Bool?
        var index = 1
        while index < arguments.count {
            let option = arguments[index]
            switch option {
            case "--headless":
                headless = true
            case "--shared-folder":
                index += 1
                guard index < arguments.count else {
                    throw VMError.message("Missing value for --shared-folder.")
                }
                sharedFolderPath = arguments[index]
            case "--writable":
                writableOverride = true
            case "--read-only":
                writableOverride = false
            default:
                throw VMError.message("Unknown option '\(option)'.")
            }
            index += 1
        }

        if sharedFolderPath == nil, writableOverride != nil {
            throw VMError.message("Use --shared-folder together with --writable/--read-only.")
        }

        var runtimeSharedFolder: RuntimeSharedFolderOverride?
        if let path = sharedFolderPath {
            let readOnly = !(writableOverride ?? false)
            runtimeSharedFolder = RuntimeSharedFolderOverride(path: path, readOnly: readOnly)
        }

        let bundleURL = try resolveBundleURL(argument: bundleArg, mustExist: true)
        try controller.startVM(bundleURL: bundleURL, headless: headless, runtimeSharedFolder: runtimeSharedFolder)
    }

    private func handleStop(arguments: [String]) throws {
        guard let bundleArg = arguments.first else {
            throw VMError.message("Usage: vmctl stop <bundle-path>")
        }
        let bundleURL = try resolveBundleURL(argument: bundleArg, mustExist: true)
        try controller.stopVM(bundleURL: bundleURL)
    }

    private func handleStatus(arguments: [String]) throws {
        guard let bundleArg = arguments.first else {
            throw VMError.message("Usage: vmctl status <bundle-path>")
        }
        let bundleURL = try resolveBundleURL(argument: bundleArg, mustExist: true)
        try controller.status(bundleURL: bundleURL)
    }

    private func handleSnapshot(arguments: [String]) throws {
        guard arguments.count >= 3 else {
            throw VMError.message("Usage: vmctl snapshot <bundle-path> <create|revert> <snapshot>")
        }
        let bundleURL = try resolveBundleURL(argument: arguments[0], mustExist: true)
        let subcommand = arguments[1]
        let snapshotName = arguments[2]
        try controller.snapshot(bundleURL: bundleURL, subcommand: subcommand, snapshotName: snapshotName)
    }

    private func showHelp(exitCode: Int32) -> Never {
        print("""
Usage: vmctl <command> [options]

Commands:
  init <bundle-path> [--cpus N] [--memory GiB] [--disk GiB] [--restore-image PATH] [--shared-folder PATH] [--writable]
  install <bundle-path>
  start <bundle-path> [--headless] [--shared-folder PATH] [--writable|--read-only]
  stop <bundle-path>
  status <bundle-path>
  snapshot <bundle-path> <create|revert> <snapshot>

Examples:
  vmctl init ~/VMs/sandbox.FixieVM --cpus 6 --memory 16 --disk 128
  vmctl install ~/VMs/sandbox.FixieVM
  vmctl start ~/VMs/sandbox.FixieVM                    # GUI
  vmctl start ~/VMs/sandbox.FixieVM --headless         # headless (SSH after setup)
  vmctl start ~/VMs/sandbox.FixieVM --shared-folder ~/Projects --writable
  vmctl stop ~/VMs/sandbox.FixieVM
  vmctl status ~/VMs/sandbox.FixieVM
  vmctl snapshot ~/VMs/sandbox.FixieVM create clean
  vmctl snapshot ~/VMs/sandbox.FixieVM revert clean

Note: After installation, enable Remote Login (SSH) inside the guest for convenient headless access.
      Apple’s EULA requires macOS guests to run on Apple-branded hardware.
""")
        exit(exitCode)
    }

    private func fail(_ error: Error) -> Never {
        if let vmError = error as? VMError {
            print("Error: \(vmError.description)")
        } else {
            print("Error: \(error.localizedDescription)")
        }
        exit(1)
    }
}

// MARK: - Entry Point

#if !VMCTL_APP
@main
struct VMCTLMain {
    static func main() {
        #if !arch(arm64)
        print("vmctl requires Apple Silicon (arm64) to run macOS guests via Virtualization.framework.")
        exit(1)
        #endif

        if #available(macOS 13.0, *) {
            CLI().run()
        } else {
            print("vmctl requires macOS 13.0 or newer.")
            exit(1)
        }
    }
}
#endif
