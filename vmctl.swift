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
    var name: String
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
        return try decoder.decode(VMStoredConfig.self, from: data)
    }

    func save(_ config: VMStoredConfig) throws {
        var updated = config
        updated.modifiedAt = Date()
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

// MARK: - PID Tracking

func readPID(from url: URL) -> pid_t? {
    guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
        return nil
    }
    return pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
}

func writePID(_ pid: pid_t, to url: URL) throws {
    try "\(pid)\n".data(using: .utf8)?.write(to: url, options: .atomic)
}

func removePID(at url: URL) {
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
    private let fileManager = FileManager.default
    private let rootDirectory: URL

    init(rootDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("VMs", isDirectory: true)) {
        self.rootDirectory = rootDirectory
    }

    struct VMListEntry {
        let name: String
        let bundleURL: URL
        let installed: Bool
        let runningPID: pid_t?
        let cpuCount: Int
        let memoryBytes: UInt64
        let diskBytes: UInt64

        var isRunning: Bool {
            return runningPID != nil
        }

        var statusDescription: String {
            if let pid = runningPID {
                return "Running (PID \(pid))"
            }
            if !installed {
                return "Not Installed"
            }
            return "Stopped"
        }
    }

    func listVMs() throws -> [VMListEntry] {
        guard fileManager.fileExists(atPath: rootDirectory.path) else {
            return []
        }

        let contents = try fileManager.contentsOfDirectory(at: rootDirectory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        var entries: [VMListEntry] = []

        for item in contents where item.pathExtension == "vm" {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: item.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                continue
            }

            let layout = VMFileLayout(bundleURL: item)
            guard fileManager.fileExists(atPath: layout.configURL.path) else {
                continue
            }

            let store = VMConfigStore(layout: layout)
            guard let config = try? store.load() else {
                continue
            }

            var running: pid_t?
            if let pid = readPID(from: layout.pidFileURL), kill(pid, 0) == 0 {
                running = pid
            } else {
                running = nil
            }

            let entry = VMListEntry(
                name: config.name,
                bundleURL: item,
                installed: config.installed,
                runningPID: running,
                cpuCount: config.cpus,
                memoryBytes: config.memoryBytes,
                diskBytes: config.diskBytes
            )
            entries.append(entry)
        }

        return entries.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func bundleURL(for name: String) -> URL {
        return rootDirectory.appendingPathComponent("\(name).vm", isDirectory: true)
    }

    func storedConfig(for name: String) throws -> VMStoredConfig {
        let bundleURL = bundleURL(for: name)
        guard fileManager.fileExists(atPath: bundleURL.path) else {
            throw VMError.message("VM '\(name)' does not exist.")
        }
        let layout = VMFileLayout(bundleURL: bundleURL)
        let store = VMConfigStore(layout: layout)
        return try store.load()
    }

    func updateVMSettings(name: String, cpus: Int, memoryGiB: UInt64, sharedFolderPath: String?, sharedFolderWritable: Bool) throws {
        let bundleURL = bundleURL(for: name)
        guard fileManager.fileExists(atPath: bundleURL.path) else {
            throw VMError.message("VM '\(name)' does not exist.")
        }

        let layout = VMFileLayout(bundleURL: bundleURL)
        guard !isVMProcessRunning(layout: layout) else {
            throw VMError.message("Stop VM '\(name)' before editing its settings.")
        }

        var config = try storedConfig(for: name)

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
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw VMError.message("Shared folder path \(path) does not exist or is not a directory.")
            }
            sanitizedSharedPath = path
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

    func initVM(name: String, options: InitOptions) throws {
        guard VZVirtualMachine.isSupported else {
            throw VMError.message("Virtualization is not supported on this host. Ensure you are on Apple Silicon and virtualization is enabled.")
        }

        let bundleURL = bundleURL(for: name)
        let layout = VMFileLayout(bundleURL: bundleURL)
        if fileManager.fileExists(atPath: bundleURL.path) {
            throw VMError.message("Bundle \(bundleURL.path) already exists.")
        }
        try layout.ensureBundleDirectory()

        // Either use the provided restore image or autodiscover it from known locations.
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
            // Creating auxiliary storage is potentially expensive; keep a strong reference until end of scope.
            _ = try VZMacAuxiliaryStorage(creatingStorageAt: layout.auxiliaryStorageURL, hardwareModel: hardwareModel, options: [.allowOverwrite])
        } catch {
            throw VMError.message("Failed to create auxiliary storage: \(error.localizedDescription)")
        }

        // Sparse raw disk backed by the host filesystem; macOS installer expects a blank device.
        if !fileManager.createFile(atPath: layout.diskURL.path, contents: nil, attributes: nil) {
            throw VMError.message("Failed to create disk image at \(layout.diskURL.path).")
        }
        let handle = try FileHandle(forWritingTo: layout.diskURL)
        try handle.truncate(atOffset: requestedDiskBytes)
        try handle.close()

        if let sharedPath = options.sharedFolderPath {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: sharedPath, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw VMError.message("Shared folder path \(sharedPath) does not exist or is not a directory.")
            }
        }

        if !fileManager.fileExists(atPath: layout.snapshotsDirectoryURL.path) {
            try fileManager.createDirectory(at: layout.snapshotsDirectoryURL, withIntermediateDirectories: true, attributes: nil)
        }

        let config = VMStoredConfig(
            version: 1,
            name: name,
            createdAt: Date(),
            modifiedAt: Date(),
            cpus: options.cpus,
            memoryBytes: requestedMemoryBytes,
            diskBytes: requestedDiskBytes,
            restoreImagePath: restoreImageURL.path,
            hardwareModelPath: layout.hardwareModelURL.path,
            machineIdentifierPath: layout.machineIdentifierURL.path,
            auxiliaryStoragePath: layout.auxiliaryStorageURL.path,
            diskPath: layout.diskURL.path,
            sharedFolderPath: options.sharedFolderPath,
            sharedFolderReadOnly: !options.sharedFolderWritable,
            installed: false,
            lastInstallBuild: nil,
            lastInstallVersion: nil,
            lastInstallDate: nil
        )

        let store = VMConfigStore(layout: layout)
        try store.save(config)

        print("Initialized macOS VM '\(name)' at \(bundleURL.path).")
        print("Restore image: \(restoreImageURL.path)")
        print("Hardware model saved to \(layout.hardwareModelURL.path)")
        print("Disk size: \(options.diskGiB) GiB, Memory: \(options.memoryGiB) GiB, vCPUs: \(options.cpus)")
    }

    func moveVMToTrash(name: String) throws {
        let bundleURL = bundleURL(for: name)
        guard fileManager.fileExists(atPath: bundleURL.path) else {
            throw VMError.message("VM '\(name)' does not exist.")
        }

        let layout = VMFileLayout(bundleURL: bundleURL)
        if let pid = readPID(from: layout.pidFileURL), kill(pid, 0) == 0 {
            throw VMError.message("VM '\(name)' is running. Stop it before deleting.")
        }

        do {
            try fileManager.trashItem(at: bundleURL, resultingItemURL: nil)
        } catch {
            throw VMError.message("Failed to move VM to Trash: \(error.localizedDescription)")
        }
    }

    func installVM(name: String) throws {
        let bundleURL = bundleURL(for: name)
        let layout = VMFileLayout(bundleURL: bundleURL)
        let store = VMConfigStore(layout: layout)
        var config = try store.load()

        guard !isVMProcessRunning(layout: layout) else {
            throw VMError.message("VM '\(name)' appears to be running. Stop it before installing.")
        }

        let restoreImageURL = URL(fileURLWithPath: config.restoreImagePath)
        let restoreImage = try loadRestoreImage(from: restoreImageURL)

        let builder = VMConfigurationBuilder(layout: layout, storedConfig: config)
        let vmConfiguration = try builder.makeConfiguration(headless: false, connectSerialToStandardIO: true, runtimeSharedFolder: nil)

        let vmQueue = DispatchQueue(label: "vmctl.install.\(name)")
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

        print("Metadata updated. Consider enabling Remote Login (SSH) inside the guest for headless workflows.")
        print("Reminder: Apple’s EULA requires macOS guests to run on Apple-branded hardware.")
    }

    func startVM(name: String, headless: Bool, runtimeSharedFolder: RuntimeSharedFolderOverride?) throws -> Never {
        let bundleURL = bundleURL(for: name)
        let layout = VMFileLayout(bundleURL: bundleURL)
        let store = VMConfigStore(layout: layout)
        let config = try store.load()

        if let pid = readPID(from: layout.pidFileURL), kill(pid, 0) == 0 {
            throw VMError.message("VM '\(name)' is already running under PID \(pid).")
        }

        let builder = VMConfigurationBuilder(layout: layout, storedConfig: config)
        let vmConfiguration = try builder.makeConfiguration(headless: headless, connectSerialToStandardIO: headless, runtimeSharedFolder: runtimeSharedFolder)
        let vmQueue = DispatchQueue(label: "vmctl.run.\(name)")
        let virtualMachine = VZVirtualMachine(configuration: vmConfiguration, queue: vmQueue)
        let pid = getpid()
        try writePID(pid, to: layout.pidFileURL)

        // A single closure runs all exit paths so we never leave stale pid files behind.
        func cleanupAndExit(_ code: Int32) -> Never {
            removePID(at: layout.pidFileURL)
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
                    print("VM started. PID \(pid). Press Ctrl+C to shut down.")
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

        if headless {
            dispatchMain()
        } else {
            DispatchQueue.main.async {
                let app = NSApplication.shared
                app.setActivationPolicy(.regular)
                let window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 1024, height: 640),
                    styleMask: [.titled, .closable, .miniaturizable, .resizable],
                    backing: .buffered,
                    defer: false
                )
                window.title = "vmctl – \(name)"
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

    func stopVM(name: String, timeout: TimeInterval = 30) throws {
        let bundleURL = bundleURL(for: name)
        let layout = VMFileLayout(bundleURL: bundleURL)
        guard let pid = readPID(from: layout.pidFileURL) else {
            print("VM '\(name)' does not appear to be running.")
            return
        }
        if kill(pid, 0) != 0 {
            print("Stale PID file detected. Cleaning up.")
            removePID(at: layout.pidFileURL)
            return
        }

        print("Sending SIGTERM to VM process \(pid) for graceful shutdown.")
        kill(pid, SIGTERM)

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if kill(pid, 0) != 0 {
                print("VM process exited.")
                removePID(at: layout.pidFileURL)
                return
            }
            Thread.sleep(forTimeInterval: 1)
        }

        print("Graceful shutdown timed out. Sending SIGKILL.")
        kill(pid, SIGKILL)
        removePID(at: layout.pidFileURL)
    }

    func status(name: String) throws {
        let bundleURL = bundleURL(for: name)
        let layout = VMFileLayout(bundleURL: bundleURL)
        let store = VMConfigStore(layout: layout)
        guard fileManager.fileExists(atPath: layout.configURL.path) else {
            throw VMError.message("VM '\(name)' does not exist.")
        }
        let config = try store.load()
        let runningPID = readPID(from: layout.pidFileURL)
        let isRunning: Bool
        if let pid = runningPID, kill(pid, 0) == 0 {
            isRunning = true
        } else {
            isRunning = false
        }

        print("Name: \(config.name)")
        print("Bundle: \(bundleURL.path)")
        print("State: \(isRunning ? "running (PID \(runningPID!))" : "stopped")")
        print(String(format: "vCPUs: %d, Memory: %.1f GiB, Disk: %.1f GiB", config.cpus, Double(config.memoryBytes) / Double(1 << 30), Double(config.diskBytes) / Double(1 << 30)))
        print("Restore image: \(config.restoreImagePath)")
        if let shared = config.sharedFolderPath {
            print("Shared folder: \(shared) (\(config.sharedFolderReadOnly ? "read-only" : "read-write"))")
        }
        if config.installed {
            print("Installed build: \(config.lastInstallBuild ?? "unknown") (\(config.lastInstallVersion ?? "unknown")), last install: \(config.lastInstallDate?.description ?? "unknown")")
        } else {
            print("Installation status: not installed (run 'vmctl install \(name)')")
        }
    }

    func snapshot(name: String, subcommand: String, snapshotName: String) throws {
        let bundleURL = bundleURL(for: name)
        let layout = VMFileLayout(bundleURL: bundleURL)
        let sanitized = try sanitizedSnapshotName(snapshotName)
        let snapshotDir = layout.snapshotsDirectoryURL.appendingPathComponent(sanitized, isDirectory: true)

        switch subcommand {
        case "create":
            guard !isVMProcessRunning(layout: layout) else {
                throw VMError.message("Stop the VM before taking a snapshot to avoid inconsistent state.")
            }
            if fileManager.fileExists(atPath: snapshotDir.path) {
                throw VMError.message("Snapshot '\(sanitized)' already exists.")
            }
            try fileManager.createDirectory(at: snapshotDir, withIntermediateDirectories: true, attributes: nil)

            // Snapshots are implemented by duplicating the bundle assets. This is coarse-grained but easy to reason about.
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

            print("Snapshot '\(sanitized)' created at \(snapshotDir.path). (Coarse-grained copy of bundle files.)")

        case "revert":
            guard fileManager.fileExists(atPath: snapshotDir.path) else {
                throw VMError.message("Snapshot '\(sanitized)' does not exist.")
            }
            guard !isVMProcessRunning(layout: layout) else {
                throw VMError.message("Stop the VM before reverting a snapshot.")
            }

            let tempDir = bundleURL.appendingPathComponent(".revert-temp-\(UUID().uuidString)", isDirectory: true)
            try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true, attributes: nil)

            // First back up the current state so we can recover if the copy fails mid-way.
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
            print("Reverted VM '\(name)' to snapshot '\(sanitized)'.")

        default:
            throw VMError.message("Unknown snapshot subcommand '\(subcommand)'. Use 'create' or 'revert'.")
        }
    }

    private func isVMProcessRunning(layout: VMFileLayout) -> Bool {
        if let pid = readPID(from: layout.pidFileURL), kill(pid, 0) == 0 {
            return true
        }
        return false
    }
}

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

    private func handleInit(arguments: [String]) throws {
        guard let name = arguments.first else {
            throw VMError.message("Usage: vmctl init <name> [options]")
        }
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
        try controller.initVM(name: name, options: opts)
    }

    private func handleInstall(arguments: [String]) throws {
        guard let name = arguments.first else {
            throw VMError.message("Usage: vmctl install <name>")
        }
        try controller.installVM(name: name)
    }

    private func handleStart(arguments: [String]) throws {
        guard let name = arguments.first else {
            throw VMError.message("Usage: vmctl start <name> [--headless] [--shared-folder PATH] [--writable|--read-only]")
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

        try controller.startVM(name: name, headless: headless, runtimeSharedFolder: runtimeSharedFolder)
    }

    private func handleStop(arguments: [String]) throws {
        guard let name = arguments.first else {
            throw VMError.message("Usage: vmctl stop <name>")
        }
        try controller.stopVM(name: name)
    }

    private func handleStatus(arguments: [String]) throws {
        guard let name = arguments.first else {
            throw VMError.message("Usage: vmctl status <name>")
        }
        try controller.status(name: name)
    }

    private func handleSnapshot(arguments: [String]) throws {
        guard arguments.count >= 3 else {
            throw VMError.message("Usage: vmctl snapshot <name> <create|revert> <snapshot>")
        }
        let name = arguments[0]
        let subcommand = arguments[1]
        let snapshotName = arguments[2]
        try controller.snapshot(name: name, subcommand: subcommand, snapshotName: snapshotName)
    }

    private func showHelp(exitCode: Int32) -> Never {
        print("""
Usage: vmctl <command> [options]

Commands:
  init <name> [--cpus N] [--memory GiB] [--disk GiB] [--restore-image PATH] [--shared-folder PATH] [--writable]
  install <name>
  start <name> [--headless] [--shared-folder PATH] [--writable|--read-only]
  stop <name>
  status <name>
  snapshot <name> <create|revert> <snapshot>

Examples:
  vmctl init sandbox --cpus 6 --memory 16 --disk 128
  vmctl install sandbox
  vmctl start sandbox                                   # GUI
  vmctl start sandbox --headless                        # headless (SSH after setup)
  vmctl start sandbox --shared-folder ~/Projects --writable
  vmctl stop sandbox
  vmctl status sandbox
  vmctl snapshot sandbox create clean
  vmctl snapshot sandbox revert clean

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
