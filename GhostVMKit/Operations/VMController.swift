import Foundation
import AppKit
import Virtualization
import Darwin
import ObjectiveC

private var windowDelegateAssociationKey: UInt8 = 0

/// Primary controller for VM operations.
public final class VMController {
    /// Primary bundle extension for new VMs.
    public static let bundleExtension = "GhostVM"
    public static let bundleExtensionLowercased = bundleExtension.lowercased()
    /// Legacy extension accepted for backward compatibility.
    public static let legacyBundleExtension = "GhostVM"
    public static let legacyBundleExtensionLowercased = legacyBundleExtension.lowercased()

    private let fileManager = FileManager.default
    private var rootDirectory: URL

    public init(rootDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("VMs", isDirectory: true)) {
        self.rootDirectory = rootDirectory
    }

    public var currentRootDirectory: URL {
        return rootDirectory
    }

    public func updateRootDirectory(_ url: URL) {
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

    public func displayName(for bundleURL: URL) -> String {
        return defaultName(for: bundleURL)
    }

    // MARK: - List VMs

    public func listVMs() throws -> [VMListEntry] {
        return try listVMs(in: rootDirectory)
    }

    public func listVMs(in directory: URL) throws -> [VMListEntry] {
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

    public func listVMs(at bundleURLs: [URL]) -> [VMListEntry] {
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

    public func loadEntry(for bundleURL: URL) throws -> VMListEntry {
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
            diskBytes: config.diskBytes,
            lastInstallVersion: config.lastInstallVersion,
            guestOSType: config.guestOSType,
            installerISOPath: config.installerISOPath,
            isSuspended: config.isSuspended
        )
    }

    public func bundleURL(for name: String) -> URL {
        return rootDirectory.appendingPathComponent("\(name).\(VMController.bundleExtension)", isDirectory: true)
    }

    public func isSupportedBundleURL(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == VMController.bundleExtensionLowercased || ext == VMController.legacyBundleExtensionLowercased
    }

    public func storedConfig(at bundleURL: URL) throws -> VMStoredConfig {
        let layout = try layoutForExistingBundle(at: bundleURL)
        let store = VMConfigStore(layout: layout)
        return try store.load()
    }

    public func storedConfig(for name: String) throws -> VMStoredConfig {
        return try storedConfig(at: bundleURL(for: name))
    }

    // MARK: - Update Settings

    public func updateVMSettings(bundleURL: URL, cpus: Int, memoryGiB: UInt64, sharedFolderPath: String?, sharedFolderWritable: Bool) throws {
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

    public func updateVMSettings(name: String, cpus: Int, memoryGiB: UInt64, sharedFolderPath: String?, sharedFolderWritable: Bool) throws {
        try updateVMSettings(bundleURL: bundleURL(for: name), cpus: cpus, memoryGiB: memoryGiB, sharedFolderPath: sharedFolderPath, sharedFolderWritable: sharedFolderWritable)
    }

    /// Update VM settings with multiple shared folders support.
    public func updateVMSettings(bundleURL: URL, cpus: Int, memoryGiB: UInt64, sharedFolders: [SharedFolderConfig]) throws {
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

        // Validate and normalize shared folders
        var validatedFolders: [SharedFolderConfig] = []
        for folder in sharedFolders {
            let path = folder.path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else { continue }
            let absolutePath = standardizedAbsolutePath(path)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: absolutePath, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw VMError.message("Shared folder path \(path) does not exist or is not a directory.")
            }
            validatedFolders.append(SharedFolderConfig(id: folder.id, path: absolutePath, readOnly: folder.readOnly))
        }

        config.cpus = cpus
        config.memoryBytes = memoryBytes
        config.sharedFolders = validatedFolders
        // Clear legacy single folder fields when using multiple folders
        config.sharedFolderPath = nil
        config.sharedFolderReadOnly = true

        let store = VMConfigStore(layout: layout)
        try store.save(config)
    }

    /// Update VM settings with multiple shared folders and port forwards support.
    public func updateVMSettings(bundleURL: URL, cpus: Int, memoryGiB: UInt64, sharedFolders: [SharedFolderConfig], portForwards: [PortForwardConfig]) throws {
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

        // Validate and normalize shared folders
        var validatedFolders: [SharedFolderConfig] = []
        for folder in sharedFolders {
            let path = folder.path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else { continue }
            let absolutePath = standardizedAbsolutePath(path)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: absolutePath, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw VMError.message("Shared folder path \(path) does not exist or is not a directory.")
            }
            validatedFolders.append(SharedFolderConfig(id: folder.id, path: absolutePath, readOnly: folder.readOnly))
        }

        // Validate port forwards
        var validatedPortForwards: [PortForwardConfig] = []
        var usedHostPorts: Set<UInt16> = []
        for forward in portForwards {
            guard forward.hostPort > 0 && forward.guestPort > 0 else { continue }
            guard !usedHostPorts.contains(forward.hostPort) else {
                throw VMError.message("Duplicate host port \(forward.hostPort) in port forwards.")
            }
            usedHostPorts.insert(forward.hostPort)
            validatedPortForwards.append(forward)
        }

        config.cpus = cpus
        config.memoryBytes = memoryBytes
        config.sharedFolders = validatedFolders
        config.portForwards = validatedPortForwards
        // Clear legacy single folder fields when using multiple folders
        config.sharedFolderPath = nil
        config.sharedFolderReadOnly = true

        let store = VMConfigStore(layout: layout)
        try store.save(config)
    }

    // MARK: - Init VM

    public func initVM(at providedBundleURL: URL, preferredName: String? = nil, options: InitOptions) throws {
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

        // Handle legacy single shared folder
        var sharedFolderAbsolute: String?
        if let sharedPath = options.sharedFolderPath {
            let absoluteShared = standardizedAbsolutePath(sharedPath)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: absoluteShared, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw VMError.message("Shared folder path \(absoluteShared) does not exist or is not a directory.")
            }
            sharedFolderAbsolute = absoluteShared
        }

        // Process multiple shared folders
        var validatedSharedFolders: [SharedFolderConfig] = []
        for folder in options.sharedFolders {
            let absolutePath = standardizedAbsolutePath(folder.path)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: absolutePath, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw VMError.message("Shared folder path \(folder.path) does not exist or is not a directory.")
            }
            validatedSharedFolders.append(SharedFolderConfig(id: folder.id, path: absolutePath, readOnly: folder.readOnly))
        }

        if !fileManager.fileExists(atPath: layout.snapshotsDirectoryURL.path) {
            try fileManager.createDirectory(at: layout.snapshotsDirectoryURL, withIntermediateDirectories: true, attributes: nil)
        }

        // Generate a persistent MAC address for this VM
        let macAddress = VZMACAddress.randomLocallyAdministered()

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
            sharedFolders: validatedSharedFolders,
            installed: false,
            lastInstallBuild: nil,
            lastInstallVersion: nil,
            lastInstallDate: nil,
            legacyName: nil,
            macAddress: macAddress.string
        )

        let store = VMConfigStore(layout: layout)
        try store.save(config)

        print("Initialized macOS VM '\(vmName)' at \(bundleURL.path).")
        print("Restore image: \(restoreImageURL.path)")
        print("Hardware model saved to \(layout.hardwareModelURL.path)")
        print("Disk size: \(options.diskGiB) GiB, Memory: \(options.memoryGiB) GiB, vCPUs: \(options.cpus)")
    }

    public func initVM(name: String, options: InitOptions) throws {
        try initVM(at: bundleURL(for: name), preferredName: name, options: options)
    }

    // MARK: - Init Linux VM

    public func initLinuxVM(at providedBundleURL: URL, preferredName: String? = nil, options: LinuxInitOptions) throws {
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

        // Validate ISO path if provided
        var isoAbsolutePath: String?
        if let isoPath = options.isoPath {
            let absoluteISO = standardizedAbsolutePath(isoPath)
            guard fileManager.fileExists(atPath: absoluteISO) else {
                throw VMError.message("ISO file does not exist: \(absoluteISO)")
            }
            // Warn if ISO filename suggests x86_64 architecture
            let isoFilename = URL(fileURLWithPath: absoluteISO).lastPathComponent.lowercased()
            if isoFilename.contains("x86") || isoFilename.contains("amd64") || isoFilename.contains("i386") || isoFilename.contains("i686") {
                print("Warning: ISO filename '\(isoFilename)' suggests x86_64 architecture. This VM requires ARM64 ISOs.")
            }
            isoAbsolutePath = absoluteISO
        }

        let minCPUs = max(Int(VZVirtualMachineConfiguration.minimumAllowedCPUCount), 1)
        let minMemory = VZVirtualMachineConfiguration.minimumAllowedMemorySize

        if options.cpus < minCPUs {
            throw VMError.message("CPU count \(options.cpus) is below minimum required \(minCPUs).")
        }

        let requestedMemoryBytes = options.memoryGiB * (1 << 30)
        if requestedMemoryBytes < minMemory {
            throw VMError.message("Memory \(options.memoryGiB) GiB is below minimum required \(minMemory >> 30) GiB.")
        }

        let requestedDiskBytes = options.diskGiB * (1 << 30)
        if requestedDiskBytes < (10 * (1 << 30)) {
            throw VMError.message("Disk size must be at least 10 GiB.")
        }

        // Create EFI variable store (NVRAM.bin)
        do {
            _ = try VZEFIVariableStore(creatingVariableStoreAt: layout.efiVariableStoreURL, options: [])
        } catch {
            throw VMError.message("Failed to create EFI variable store: \(error.localizedDescription)")
        }

        // Create disk image
        if !fileManager.createFile(atPath: layout.diskURL.path, contents: nil, attributes: nil) {
            throw VMError.message("Failed to create disk image at \(layout.diskURL.path).")
        }
        let handle = try FileHandle(forWritingTo: layout.diskURL)
        try handle.truncate(atOffset: requestedDiskBytes)
        try handle.close()

        // Process shared folders
        var validatedSharedFolders: [SharedFolderConfig] = []
        for folder in options.sharedFolders {
            let absolutePath = standardizedAbsolutePath(folder.path)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: absolutePath, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw VMError.message("Shared folder path \(folder.path) does not exist or is not a directory.")
            }
            validatedSharedFolders.append(SharedFolderConfig(id: folder.id, path: absolutePath, readOnly: folder.readOnly))
        }

        if !fileManager.fileExists(atPath: layout.snapshotsDirectoryURL.path) {
            try fileManager.createDirectory(at: layout.snapshotsDirectoryURL, withIntermediateDirectories: true, attributes: nil)
        }

        // Generate a persistent MAC address for this VM
        let macAddress = VZMACAddress.randomLocallyAdministered()

        let config = VMStoredConfig(
            version: 1,
            createdAt: Date(),
            modifiedAt: Date(),
            cpus: options.cpus,
            memoryBytes: requestedMemoryBytes,
            diskBytes: requestedDiskBytes,
            restoreImagePath: "",  // Not used for Linux VMs
            hardwareModelPath: "",  // Not used for Linux VMs
            machineIdentifierPath: "",  // Not used for Linux VMs
            auxiliaryStoragePath: "",  // Not used for Linux VMs
            diskPath: layout.diskURL.lastPathComponent,
            sharedFolderPath: nil,
            sharedFolderReadOnly: true,
            sharedFolders: validatedSharedFolders,
            installed: true,  // Linux VMs are considered "installed" immediately (user installs via ISO)
            lastInstallBuild: nil,
            lastInstallVersion: nil,
            lastInstallDate: nil,
            legacyName: nil,
            macAddress: macAddress.string,
            guestOSType: "Linux",
            efiVariableStorePath: layout.efiVariableStoreURL.lastPathComponent,
            installerISOPath: isoAbsolutePath
        )

        let store = VMConfigStore(layout: layout)
        try store.save(config)

        print("Initialized Linux VM '\(vmName)' at \(bundleURL.path).")
        if let isoPath = isoAbsolutePath {
            print("Installer ISO: \(isoPath)")
        } else {
            print("No installer ISO attached. Use 'vmctl attach-iso' to add one.")
        }
        print("Disk size: \(options.diskGiB) GiB, Memory: \(options.memoryGiB) GiB, vCPUs: \(options.cpus)")
    }

    public func initLinuxVM(name: String, options: LinuxInitOptions) throws {
        try initLinuxVM(at: bundleURL(for: name), preferredName: name, options: options)
    }

    // MARK: - Detach ISO

    public func detachISO(bundleURL: URL) throws {
        let layout = try layoutForExistingBundle(at: bundleURL)
        let store = VMConfigStore(layout: layout)
        var config = try store.load()
        let vmName = displayName(for: bundleURL)

        guard config.guestOSType == "Linux" else {
            throw VMError.message("VM '\(vmName)' is not a Linux VM.")
        }

        guard config.installerISOPath != nil else {
            print("No installer ISO attached to '\(vmName)'.")
            return
        }

        guard !isVMProcessRunning(layout: layout) else {
            throw VMError.message("Stop VM '\(vmName)' before detaching the installer ISO.")
        }

        config.installerISOPath = nil
        config.modifiedAt = Date()
        try store.save(config)

        print("Installer ISO detached from '\(vmName)'.")
    }

    public func detachISO(name: String) throws {
        try detachISO(bundleURL: bundleURL(for: name))
    }

    // MARK: - Delete VM

    public func moveVMToTrash(bundleURL: URL) throws {
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

    public func moveVMToTrash(name: String) throws {
        try moveVMToTrash(bundleURL: bundleURL(for: name))
    }

    // MARK: - Install VM

    public func installVM(bundleURL: URL) throws {
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
        print("Reminder: Apple's EULA requires macOS guests to run on Apple-branded hardware.")
    }

    public func installVM(name: String) throws {
        try installVM(bundleURL: bundleURL(for: name))
    }

    /// GUI-friendly install method that reports progress via a callback
    public func installVMWithProgress(bundleURL: URL, progressHandler: @escaping (Double, String?) -> Void) throws {
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
        let vmConfiguration = try builder.makeConfiguration(headless: false, connectSerialToStandardIO: false, runtimeSharedFolder: nil)

        let vmQueue = DispatchQueue(label: "ghostvm.install.\(vmName)")
        let virtualMachine = VZVirtualMachine(configuration: vmConfiguration, queue: vmQueue)

        let installer: VZMacOSInstaller = vmQueue.sync {
            VZMacOSInstaller(virtualMachine: virtualMachine, restoringFromImageAt: restoreImageURL)
        }

        let progress = installer.progress
        let observation = progress.observe(\.fractionCompleted, options: [.new]) { prog, _ in
            progressHandler(prog.fractionCompleted, prog.localizedDescription)
        }

        let group = DispatchGroup()
        var installError: Error?
        group.enter()
        vmQueue.async {
            installer.install { result in
                switch result {
                case .success:
                    break
                case .failure(let error):
                    installError = error
                }
                group.leave()
            }
        }
        group.wait()
        observation.invalidate()

        if let error = installError {
            throw error
        }

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
    }

    // MARK: - Start VM (CLI mode - returns Never)

    public func startVM(bundleURL: URL, headless: Bool, runtimeSharedFolder: RuntimeSharedFolderOverride?) throws -> Never {
        let layout = try layoutForExistingBundle(at: bundleURL)
        let store = VMConfigStore(layout: layout)
        var config = try store.load()
        let vmName = displayName(for: bundleURL)

        // Generate a persistent MAC address if one doesn't exist (migration for older VMs)
        if config.macAddress == nil {
            config.macAddress = VZMACAddress.randomLocallyAdministered().string
            config.modifiedAt = Date()
            try store.save(config)
        }

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

        // Suspend handler: pause VM, save state, update config, then exit
        func suspendAndExit() {
            print("Suspending virtual machine...")
            vmQueue.async {
                virtualMachine.pause { pauseResult in
                    switch pauseResult {
                    case .success:
                        virtualMachine.saveMachineStateTo(url: layout.suspendStateURL) { saveError in
                            DispatchQueue.main.async {
                                if let error = saveError {
                                    print("Failed to save VM state: \(error.localizedDescription)")
                                    // Resume the VM since we failed to save
                                    vmQueue.async {
                                        virtualMachine.resume { _ in }
                                    }
                                    return
                                }
                                // Update config to mark as suspended
                                var updatedConfig = config
                                updatedConfig.isSuspended = true
                                updatedConfig.modifiedAt = Date()
                                try? store.save(updatedConfig)
                                print("VM '\(vmName)' suspended. Use 'vmctl resume \(bundleURL.path)' to continue.")
                                cleanupAndExit(0)
                            }
                        }
                    case .failure(let error):
                        DispatchQueue.main.async {
                            print("Failed to pause VM: \(error.localizedDescription)")
                        }
                    }
                }
            }
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

        SignalTrap.shared.register(signals: [SIGINT, SIGTERM, SIGHUP])

        SignalTrap.shared.onSignal = { signal in
            if signal == SIGHUP {
                // SIGHUP triggers suspend
                suspendAndExit()
                return
            }
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
                    var suspendHandler: (() -> Void)?

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

                    @objc func suspendVM(_ sender: Any?) {
                        suspendHandler?()
                    }
                }

                let windowDelegate = VMWindowDelegate(vmQueue: vmQueue, virtualMachine: virtualMachine, vmView: vmView)
                windowDelegate.suspendHandler = suspendAndExit
                window.delegate = windowDelegate
                objc_setAssociatedObject(window, &windowDelegateAssociationKey, windowDelegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

                // Create menu bar with Virtual Machine menu
                let mainMenu = NSMenu()

                // Application menu (required for standard macOS behavior)
                let appMenuItem = NSMenuItem()
                let appMenu = NSMenu()
                appMenu.addItem(withTitle: "Quit vmctl", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
                appMenuItem.submenu = appMenu
                mainMenu.addItem(appMenuItem)

                // Virtual Machine menu
                let vmMenuItem = NSMenuItem()
                let vmMenu = NSMenu(title: "Virtual Machine")
                let suspendItem = NSMenuItem(title: "Suspend", action: #selector(VMWindowDelegate.suspendVM(_:)), keyEquivalent: "s")
                suspendItem.target = windowDelegate
                vmMenu.addItem(suspendItem)
                vmMenu.addItem(NSMenuItem.separator())
                let shutdownItem = NSMenuItem(title: "Shut Down", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "")
                vmMenu.addItem(shutdownItem)
                vmMenuItem.submenu = vmMenu
                mainMenu.addItem(vmMenuItem)

                app.mainMenu = mainMenu

                window.center()
                window.makeKeyAndOrderFront(nil)
                app.activate(ignoringOtherApps: true)
            }
            NSApplication.shared.run()
        }

        cleanupAndExit(0)
    }

    public func startVM(name: String, headless: Bool, runtimeSharedFolder: RuntimeSharedFolderOverride?) throws -> Never {
        try startVM(bundleURL: bundleURL(for: name), headless: headless, runtimeSharedFolder: runtimeSharedFolder)
    }

    // MARK: - Stop VM

    public func stopVM(bundleURL: URL, timeout: TimeInterval = 30) throws {
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

    public func stopVM(name: String, timeout: TimeInterval = 30) throws {
        try stopVM(bundleURL: bundleURL(for: name), timeout: timeout)
    }

    // MARK: - Status

    public func status(bundleURL: URL) throws {
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
        } else if config.isSuspended {
            print("State: suspended (use 'vmctl resume' to continue)")
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

    public func status(name: String) throws {
        try status(bundleURL: bundleURL(for: name))
    }

    // MARK: - Snapshots

    public func snapshotList(bundleURL: URL) throws {
        let layout = try layoutForExistingBundle(at: bundleURL)
        let snapshotsDir = layout.snapshotsDirectoryURL

        guard fileManager.fileExists(atPath: snapshotsDir.path) else {
            print("No snapshots.")
            return
        }

        let contents = try fileManager.contentsOfDirectory(
            at: snapshotsDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        let snapshots = contents.filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }.map { $0.lastPathComponent }.sorted()

        if snapshots.isEmpty {
            print("No snapshots.")
        } else {
            for name in snapshots {
                print(name)
            }
        }
    }

    public func snapshotListNames(bundleURL: URL) throws -> [String] {
        let layout = try layoutForExistingBundle(at: bundleURL)
        let snapshotsDir = layout.snapshotsDirectoryURL

        guard fileManager.fileExists(atPath: snapshotsDir.path) else {
            return []
        }

        let contents = try fileManager.contentsOfDirectory(
            at: snapshotsDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        return contents.filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }.map { $0.lastPathComponent }.sorted()
    }

    public func snapshot(bundleURL: URL, subcommand: String, snapshotName: String) throws {
        let layout = try layoutForExistingBundle(at: bundleURL)
        let store = VMConfigStore(layout: layout)
        let config = try store.load()
        let vmName = displayName(for: bundleURL)
        let sanitized = try sanitizedSnapshotName(snapshotName)
        let snapshotDir = layout.snapshotsDirectoryURL.appendingPathComponent(sanitized, isDirectory: true)
        let isLinux = config.guestOSType == "Linux"

        // Determine which items to copy based on guest OS type
        let itemsToCopy: [(String, URL)]
        if isLinux {
            itemsToCopy = [
                ("config.json", layout.configURL),
                ("disk.img", layout.diskURL),
                ("NVRAM.bin", layout.efiVariableStoreURL)
            ]
        } else {
            itemsToCopy = [
                ("config.json", layout.configURL),
                ("disk.img", layout.diskURL),
                ("HardwareModel.bin", layout.hardwareModelURL),
                ("MachineIdentifier.bin", layout.machineIdentifierURL),
                ("AuxiliaryStorage.bin", layout.auxiliaryStorageURL)
            ]
        }

        switch subcommand {
        case "create":
            guard !isVMProcessRunning(layout: layout) else {
                throw VMError.message("Stop the VM before taking a snapshot to avoid inconsistent state.")
            }
            if fileManager.fileExists(atPath: snapshotDir.path) {
                throw VMError.message("Snapshot '\(sanitized)' already exists for '\(vmName)'.")
            }
            try fileManager.createDirectory(at: snapshotDir, withIntermediateDirectories: true, attributes: nil)

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

            // Determine items to revert based on what exists in snapshot (handles mixed scenarios)
            let revertItems: [(String, URL)]
            if isLinux {
                revertItems = [
                    ("config.json", layout.configURL),
                    ("disk.img", layout.diskURL),
                    ("NVRAM.bin", layout.efiVariableStoreURL)
                ]
            } else {
                revertItems = [
                    ("config.json", layout.configURL),
                    ("disk.img", layout.diskURL),
                    ("HardwareModel.bin", layout.hardwareModelURL),
                    ("MachineIdentifier.bin", layout.machineIdentifierURL),
                    ("AuxiliaryStorage.bin", layout.auxiliaryStorageURL)
                ]
            }

            for (name, targetURL) in revertItems {
                let backupURL = tempDir.appendingPathComponent(name)
                if fileManager.fileExists(atPath: targetURL.path) {
                    try copyItem(from: targetURL, to: backupURL)
                }
                let sourceURL = snapshotDir.appendingPathComponent(name)
                if fileManager.fileExists(atPath: sourceURL.path) {
                    try copyItem(from: sourceURL, to: targetURL)
                }
            }

            // Clear any suspend state since it's incompatible with the reverted disk
            if fileManager.fileExists(atPath: layout.suspendStateURL.path) {
                try fileManager.removeItem(at: layout.suspendStateURL)
            }

            // Update config to ensure isSuspended is false
            var updatedConfig = try store.load()
            if updatedConfig.isSuspended {
                updatedConfig.isSuspended = false
                updatedConfig.modifiedAt = Date()
                try store.save(updatedConfig)
            }

            try fileManager.removeItem(at: tempDir)
            print("Reverted VM '\(vmName)' to snapshot '\(sanitized)'.")

        case "delete":
            guard fileManager.fileExists(atPath: snapshotDir.path) else {
                throw VMError.message("Snapshot '\(sanitized)' does not exist for '\(vmName)'.")
            }
            try fileManager.removeItem(at: snapshotDir)
            print("Deleted snapshot '\(sanitized)' from '\(vmName)'.")

        default:
            throw VMError.message("Unknown snapshot subcommand '\(subcommand)'. Use 'create', 'revert', or 'delete'.")
        }
    }

    public func snapshot(name: String, subcommand: String, snapshotName: String) throws {
        try snapshot(bundleURL: bundleURL(for: name), subcommand: subcommand, snapshotName: snapshotName)
    }

    // MARK: - Suspend/Resume

    /// Resumes a VM from a suspended state. Similar to startVM but restores from saved state instead of cold boot.
    public func resumeVM(bundleURL: URL, headless: Bool, runtimeSharedFolder: RuntimeSharedFolderOverride?) throws -> Never {
        let layout = try layoutForExistingBundle(at: bundleURL)
        let store = VMConfigStore(layout: layout)
        var config = try store.load()
        let vmName = displayName(for: bundleURL)

        guard config.isSuspended else {
            throw VMError.message("VM '\(vmName)' is not suspended. Use 'start' instead.")
        }

        guard fileManager.fileExists(atPath: layout.suspendStateURL.path) else {
            throw VMError.message("Suspend state file missing for '\(vmName)'. Use 'discard-suspend' to reset state.")
        }

        if let owner = readVMLockOwner(from: layout.pidFileURL) {
            if kill(owner.pid, 0) == 0 {
                if owner.isEmbedded {
                    throw VMError.message("VM '\(vmName)' is running inside GhostVM (PID \(owner.pid)). Stop it there before resuming via CLI.")
                } else {
                    throw VMError.message("VM '\(vmName)' is already running under PID \(owner.pid).")
                }
            } else {
                removeVMLock(at: layout.pidFileURL)
            }
        }

        let builder = VMConfigurationBuilder(layout: layout, storedConfig: config)
        let vmConfiguration = try builder.makeConfiguration(headless: headless, connectSerialToStandardIO: headless, runtimeSharedFolder: runtimeSharedFolder)
        let vmQueue = DispatchQueue(label: "vmctl.resume.\(vmName)")
        let virtualMachine = VZVirtualMachine(configuration: vmConfiguration, queue: vmQueue)
        let pid = getpid()
        try writeVMLockOwner(.cli(pid), to: layout.pidFileURL)

        func cleanupAndExit(_ code: Int32, clearSuspendState: Bool = false) -> Never {
            removeVMLock(at: layout.pidFileURL)
            if clearSuspendState {
                try? fileManager.removeItem(at: layout.suspendStateURL)
                config.isSuspended = false
                config.modifiedAt = Date()
                try? store.save(config)
            }
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

        let delegate = Delegate(stopHandler: { code in cleanupAndExit(code, clearSuspendState: true) })
        virtualMachine.delegate = delegate

        // Restore state from suspend file
        let restoreGroup = DispatchGroup()
        restoreGroup.enter()
        var restoreError: Error?
        vmQueue.async {
            virtualMachine.restoreMachineStateFrom(url: layout.suspendStateURL) { error in
                restoreError = error
                restoreGroup.leave()
            }
        }
        restoreGroup.wait()

        if let error = restoreError {
            print("Failed to restore VM state: \(error.localizedDescription)")
            cleanupAndExit(1)
        }

        // Resume execution
        let resumeGroup = DispatchGroup()
        resumeGroup.enter()
        vmQueue.async {
            virtualMachine.resume { result in
                switch result {
                case .success:
                    print("VM '\(vmName)' resumed from suspended state. PID \(pid). Press Ctrl+C to shut down.")
                    // Clear suspend state since we successfully resumed
                    try? self.fileManager.removeItem(at: layout.suspendStateURL)
                    config.isSuspended = false
                    config.modifiedAt = Date()
                    try? store.save(config)
                    resumeGroup.leave()
                case .failure(let error):
                    print("Failed to resume VM: \(error.localizedDescription)")
                    resumeGroup.leave()
                    cleanupAndExit(1)
                }
            }
        }
        resumeGroup.wait()

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
                            cleanupAndExit(1, clearSuspendState: true)
                        } else {
                            cleanupAndExit(0, clearSuspendState: true)
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

        cleanupAndExit(0, clearSuspendState: true)
    }

    public func resumeVM(name: String, headless: Bool, runtimeSharedFolder: RuntimeSharedFolderOverride?) throws -> Never {
        try resumeVM(bundleURL: bundleURL(for: name), headless: headless, runtimeSharedFolder: runtimeSharedFolder)
    }

    /// Discards the suspended state of a VM, allowing it to be started fresh.
    public func discardSuspend(bundleURL: URL) throws {
        let layout = try layoutForExistingBundle(at: bundleURL)
        let store = VMConfigStore(layout: layout)
        var config = try store.load()
        let vmName = displayName(for: bundleURL)

        guard config.isSuspended else {
            print("VM '\(vmName)' is not suspended.")
            return
        }

        if fileManager.fileExists(atPath: layout.suspendStateURL.path) {
            try fileManager.removeItem(at: layout.suspendStateURL)
        }

        config.isSuspended = false
        config.modifiedAt = Date()
        try store.save(config)

        print("Discarded suspended state for '\(vmName)'. Use 'start' to boot fresh.")
    }

    public func discardSuspend(name: String) throws {
        try discardSuspend(bundleURL: bundleURL(for: name))
    }

    // MARK: - Embedded Session Support

    public func makeEmbeddedSession(bundleURL: URL, runtimeSharedFolder: RuntimeSharedFolderOverride?) throws -> EmbeddedVMSession {
        let layout = try layoutForExistingBundle(at: bundleURL)
        let store = VMConfigStore(layout: layout)
        var config = try store.load()
        let name = displayName(for: bundleURL)

        // Generate a persistent MAC address if one doesn't exist (migration for older VMs)
        if config.macAddress == nil {
            config.macAddress = VZMACAddress.randomLocallyAdministered().string
            config.modifiedAt = Date()
            try store.save(config)
        }

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

    public func makeEmbeddedSession(name: String, runtimeSharedFolder: RuntimeSharedFolderOverride?) throws -> EmbeddedVMSession {
        return try makeEmbeddedSession(bundleURL: bundleURL(for: name), runtimeSharedFolder: runtimeSharedFolder)
    }

    // MARK: - Windowless Session Support (for SwiftUI apps that manage their own window)

    public func makeWindowlessSession(bundleURL: URL, runtimeSharedFolder: RuntimeSharedFolderOverride?) throws -> WindowlessVMSession {
        let layout = try layoutForExistingBundle(at: bundleURL)
        let store = VMConfigStore(layout: layout)
        var config = try store.load()
        let name = displayName(for: bundleURL)

        // Generate a persistent MAC address if one doesn't exist (migration for older VMs)
        if config.macAddress == nil {
            config.macAddress = VZMACAddress.randomLocallyAdministered().string
            config.modifiedAt = Date()
            try store.save(config)
        }

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

        return try WindowlessVMSession(name: name, bundleURL: bundleURL, layout: layout, storedConfig: config, runtimeSharedFolder: runtimeSharedFolder)
    }

    // MARK: - Private Helpers

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

// MARK: - Signal Trap Helper

public final class SignalTrap {
    /// Wrap Darwin signal handling with GCD so we can hook Ctrl+C cleanly from Swift.
    public static let shared = SignalTrap()
    public var onSignal: ((Int32) -> Void)?
    private var sources: [DispatchSourceSignal] = []
    private let accessQueue = DispatchQueue(label: "vmctl.signaltrap")

    public func register(signals: [Int32]) {
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
