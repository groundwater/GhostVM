import Foundation
import Virtualization
import Darwin

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

        // Generate persistent MAC addresses for each network interface
        var interfaces = options.networkInterfaces
        for i in interfaces.indices where interfaces[i].macAddress.isEmpty {
            interfaces[i].macAddress = VZMACAddress.randomLocallyAdministered().string
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
            sharedFolders: validatedSharedFolders,
            installed: false,
            lastInstallBuild: nil,
            lastInstallVersion: nil,
            lastInstallDate: nil,
            legacyName: nil,
            networkInterfaces: interfaces
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

    // MARK: - Rename VM

    public func renameVM(bundleURL: URL, newName: String) throws -> URL {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            throw VMError.message("VM name cannot be empty.")
        }
        guard trimmed != "." && trimmed != ".." else {
            throw VMError.message("Invalid VM name.")
        }
        let forbidden = CharacterSet(charactersIn: "/:\\")
        guard trimmed.rangeOfCharacter(from: forbidden) == nil else {
            throw VMError.message("VM name cannot contain /, :, or \\ characters.")
        }

        let layout = try layoutForExistingBundle(at: bundleURL)
        let oldName = displayName(for: bundleURL)

        guard !isVMProcessRunning(layout: layout) else {
            throw VMError.message("VM '\(oldName)' is running. Stop it before renaming.")
        }

        let parentDir = bundleURL.deletingLastPathComponent()
        let bundleExtension = bundleURL.pathExtension
        let newBundleName = "\(trimmed).\(bundleExtension)"
        let newBundleURL = parentDir.appendingPathComponent(newBundleName)

        guard !fileManager.fileExists(atPath: newBundleURL.path) else {
            throw VMError.message("A VM named '\(trimmed)' already exists at that location.")
        }

        try fileManager.moveItem(at: bundleURL, to: newBundleURL)

        // Rename the helper app inside the bundle so Dock/Cmd+Tab shows the new name
        let newLayout = VMFileLayout(bundleURL: newBundleURL)
        let oldHelperURL = newLayout.helperAppURL(vmName: oldName)
        let newHelperURL = newLayout.helperAppURL(vmName: trimmed)
        if oldHelperURL.path != newHelperURL.path,
           fileManager.fileExists(atPath: oldHelperURL.path) {
            try fileManager.moveItem(at: oldHelperURL, to: newHelperURL)
        }

        return newBundleURL
    }

    // MARK: - Clone VM

    /// Clone a VM bundle using APFS copy-on-write via `clonefile()`.
    /// Returns the URL of the newly created bundle.
    public func cloneVM(bundleURL: URL, newName: String) throws -> URL {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            throw VMError.message("VM name cannot be empty.")
        }
        guard trimmed != "." && trimmed != ".." else {
            throw VMError.message("Invalid VM name.")
        }
        let forbidden = CharacterSet(charactersIn: "/:\\")
        guard trimmed.rangeOfCharacter(from: forbidden) == nil else {
            throw VMError.message("VM name cannot contain /, :, or \\ characters.")
        }

        let sourceLayout = try layoutForExistingBundle(at: bundleURL)
        let sourceName = displayName(for: bundleURL)

        // Source must be installed
        let sourceStore = VMConfigStore(layout: sourceLayout)
        let sourceConfig = try sourceStore.load()
        guard sourceConfig.installed else {
            throw VMError.message("VM '\(sourceName)' is not installed. Only installed VMs can be cloned.")
        }

        // Source must not be running
        guard !isVMProcessRunning(layout: sourceLayout) else {
            throw VMError.message("VM '\(sourceName)' is running. Stop it before cloning.")
        }

        // Create new bundle in the same parent directory
        let parentDir = bundleURL.deletingLastPathComponent()
        let bundleExtension = bundleURL.pathExtension
        let newBundleName = "\(trimmed).\(bundleExtension)"
        let newBundleURL = parentDir.appendingPathComponent(newBundleName)

        guard !fileManager.fileExists(atPath: newBundleURL.path) else {
            throw VMError.message("A VM named '\(trimmed)' already exists at that location.")
        }

        let newLayout = VMFileLayout(bundleURL: newBundleURL)

        do {
            try newLayout.ensureBundleDirectory()

            // Clone files using APFS COW via Darwin clonefile()
            let filesToClone: [(source: URL, dest: URL)] = [
                (sourceLayout.diskURL, newLayout.diskURL),
                (sourceLayout.hardwareModelURL, newLayout.hardwareModelURL),
                (sourceLayout.auxiliaryStorageURL, newLayout.auxiliaryStorageURL),
            ]

            for (source, dest) in filesToClone {
                let result = Darwin.clonefile(source.path, dest.path, 0)
                if result == -1 {
                    let err = String(cString: strerror(errno))
                    throw VMError.message("Clone failed for \(source.lastPathComponent): \(err). This volume may not support copy-on-write. Move your VMs to an APFS volume.")
                }
            }

            // Generate fresh identifiers
            let machineIdentifier = VZMacMachineIdentifier()
            try writeData(machineIdentifier.dataRepresentation, to: newLayout.machineIdentifierURL)

            // Generate fresh MAC addresses and UUIDs for cloned interfaces
            var clonedInterfaces = sourceConfig.networkInterfaces
            for i in clonedInterfaces.indices {
                clonedInterfaces[i].id = UUID()
                clonedInterfaces[i].macAddress = VZMACAddress.randomLocallyAdministered().string
            }

            // Create empty Snapshots directory
            try fileManager.createDirectory(at: newLayout.snapshotsDirectoryURL, withIntermediateDirectories: true, attributes: nil)

            // Write new config.json — same hardware settings, cleared per-instance state
            let newConfig = VMStoredConfig(
                version: sourceConfig.version,
                createdAt: Date(),
                modifiedAt: Date(),
                cpus: sourceConfig.cpus,
                memoryBytes: sourceConfig.memoryBytes,
                diskBytes: sourceConfig.diskBytes,
                restoreImagePath: sourceConfig.restoreImagePath,
                hardwareModelPath: newLayout.hardwareModelURL.lastPathComponent,
                machineIdentifierPath: newLayout.machineIdentifierURL.lastPathComponent,
                auxiliaryStoragePath: newLayout.auxiliaryStorageURL.lastPathComponent,
                diskPath: newLayout.diskURL.lastPathComponent,
                sharedFolderPath: nil,
                sharedFolderReadOnly: true,
                sharedFolders: [],
                installed: true,
                lastInstallBuild: sourceConfig.lastInstallBuild,
                lastInstallVersion: sourceConfig.lastInstallVersion,
                lastInstallDate: sourceConfig.lastInstallDate,
                legacyName: nil,
                isSuspended: false,
                portForwards: [],
                networkInterfaces: clonedInterfaces,
                iconMode: nil
            )

            let newStore = VMConfigStore(layout: newLayout)
            try newStore.save(newConfig)

        } catch {
            // Clean up partial clone on failure
            try? fileManager.removeItem(at: newBundleURL)
            throw error
        }

        return newBundleURL
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

    // MARK: - Stop VM

    public func stopVM(bundleURL: URL, timeout: TimeInterval = 30) throws {
        let layout = try layoutForExistingBundle(at: bundleURL)
        let vmName = displayName(for: bundleURL)
        guard let owner = readVMLockOwner(from: layout.pidFileURL) else {
            print("VM '\(vmName)' does not appear to be running.")
            return
        }
        let pid = owner.pid

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

        let itemsToCopy: [(String, URL)] = [
            ("config.json", layout.configURL),
            ("disk.img", layout.diskURL),
            ("HardwareModel.bin", layout.hardwareModelURL),
            ("MachineIdentifier.bin", layout.machineIdentifierURL),
            ("AuxiliaryStorage.bin", layout.auxiliaryStorageURL)
        ]

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

            for (name, targetURL) in itemsToCopy {
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

    // MARK: - CLI Start/Resume (blocking)

    /// Start a VM from the CLI. Blocks until the VM terminates.
    public func startVM(bundleURL: URL, headless: Bool, runtimeSharedFolder: RuntimeSharedFolderOverride?) throws {
        let session = try makeWindowlessSession(bundleURL: bundleURL, runtimeSharedFolder: runtimeSharedFolder)
        let vmName = displayName(for: bundleURL)

        if session.wasSuspended {
            print("VM '\(vmName)' has a saved suspend state. Use 'vmctl resume' to restore it, or 'vmctl discard-suspend' to discard it.")
            throw VMError.message("VM '\(vmName)' is suspended.")
        }

        let group = DispatchGroup()
        group.enter()
        var vmError: Error?

        session.terminationHandler = { result in
            if case .failure(let error) = result {
                vmError = error
            }
            group.leave()
        }

        // Install signal handler for graceful shutdown
        let signalSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        signal(SIGINT, SIG_IGN)
        signalSource.setEventHandler {
            print("\nStopping VM '\(vmName)'...")
            session.requestStop()
        }
        signalSource.resume()

        print("Starting VM '\(vmName)'...")
        session.start { result in
            switch result {
            case .success:
                print("VM '\(vmName)' is running. Press Ctrl-C to stop.")
            case .failure(let error):
                vmError = error
                group.leave()
            }
        }

        group.wait()
        signalSource.cancel()

        if let error = vmError {
            throw error
        }
        print("VM '\(vmName)' stopped.")
    }

    /// Resume a suspended VM from the CLI. Blocks until the VM terminates.
    public func resumeVM(bundleURL: URL, headless: Bool, runtimeSharedFolder: RuntimeSharedFolderOverride?) throws {
        let session = try makeWindowlessSession(bundleURL: bundleURL, runtimeSharedFolder: runtimeSharedFolder)
        let vmName = displayName(for: bundleURL)

        guard session.wasSuspended else {
            print("VM '\(vmName)' is not suspended. Using 'start' instead.")
            // Fall through to start
            let group = DispatchGroup()
            group.enter()
            var vmError: Error?

            session.terminationHandler = { result in
                if case .failure(let error) = result {
                    vmError = error
                }
                group.leave()
            }

            let signalSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
            signal(SIGINT, SIG_IGN)
            signalSource.setEventHandler {
                print("\nStopping VM '\(vmName)'...")
                session.requestStop()
            }
            signalSource.resume()

            print("Starting VM '\(vmName)'...")
            session.start { result in
                switch result {
                case .success:
                    print("VM '\(vmName)' is running. Press Ctrl-C to stop.")
                case .failure(let error):
                    vmError = error
                    group.leave()
                }
            }

            group.wait()
            signalSource.cancel()

            if let error = vmError {
                throw error
            }
            print("VM '\(vmName)' stopped.")
            return
        }

        let group = DispatchGroup()
        group.enter()
        var vmError: Error?

        session.terminationHandler = { result in
            if case .failure(let error) = result {
                vmError = error
            }
            group.leave()
        }

        let signalSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        signal(SIGINT, SIG_IGN)
        signalSource.setEventHandler {
            print("\nStopping VM '\(vmName)'...")
            session.requestStop()
        }
        signalSource.resume()

        print("Resuming VM '\(vmName)'...")
        session.resume { result in
            switch result {
            case .success:
                print("VM '\(vmName)' resumed. Press Ctrl-C to stop.")
            case .failure(let error):
                vmError = error
                group.leave()
            }
        }

        group.wait()
        signalSource.cancel()

        if let error = vmError {
            throw error
        }
        print("VM '\(vmName)' stopped.")
    }

    // MARK: - Embedded Session Support

    public func makeEmbeddedSession(bundleURL: URL, runtimeSharedFolder: RuntimeSharedFolderOverride?) throws -> EmbeddedVMSession {
        let layout = try layoutForExistingBundle(at: bundleURL)
        let store = VMConfigStore(layout: layout)
        var config = try store.load()
        let name = displayName(for: bundleURL)

        // Generate persistent MAC addresses for any interfaces that lack one (migration for older VMs)
        var needsSave = false
        for i in config.networkInterfaces.indices where config.networkInterfaces[i].macAddress.isEmpty {
            config.networkInterfaces[i].macAddress = VZMACAddress.randomLocallyAdministered().string
            needsSave = true
        }
        if needsSave {
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

        // Generate persistent MAC addresses for any interfaces that lack one (migration for older VMs)
        var needsSave = false
        for i in config.networkInterfaces.indices where config.networkInterfaces[i].macAddress.isEmpty {
            config.networkInterfaces[i].macAddress = VZMACAddress.randomLocallyAdministered().string
            needsSave = true
        }
        if needsSave {
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
