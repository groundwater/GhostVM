import Foundation
import AppKit
import Virtualization

/// Result of building a VM configuration, including network filter state.
public struct VMConfigurationResult {
    public let configuration: VZVirtualMachineConfiguration
    /// Host-side FD of the socketpair for network filtering.
    /// Always present — the socketpair is always created so policy can be switched at runtime.
    /// The caller is responsible for closing this FD when done.
    public let networkFilterFD: Int32
    public let networkPolicy: NetworkAccessPolicy
}

/// Builds VZVirtualMachineConfiguration from stored config and layout.
public final class VMConfigurationBuilder {
    public let layout: VMFileLayout
    public let storedConfig: VMStoredConfig

    public init(layout: VMFileLayout, storedConfig: VMStoredConfig) {
        self.layout = layout
        self.storedConfig = storedConfig
    }

    public func makeConfiguration(headless: Bool, connectSerialToStandardIO: Bool, runtimeSharedFolder: RuntimeSharedFolderOverride?) throws -> VMConfigurationResult {
        let config = VZVirtualMachineConfiguration()
        let isLinux = storedConfig.guestOSType == "Linux"

        // Configure boot loader based on guest OS type
        if isLinux {
            let efiBootLoader = VZEFIBootLoader()
            efiBootLoader.variableStore = try VZEFIVariableStore(url: layout.efiVariableStoreURL)
            config.bootLoader = efiBootLoader
        } else {
            config.bootLoader = VZMacOSBootLoader()
        }

        config.cpuCount = storedConfig.cpus
        config.memorySize = storedConfig.memoryBytes

        // Configure platform based on guest OS type
        if isLinux {
            config.platform = VZGenericPlatformConfiguration()
        } else {
            let platform = VZMacPlatformConfiguration()
            let hardwareModel = try loadHardwareModel(from: layout.hardwareModelURL)
            let machineIdentifier = try loadMachineIdentifier(from: layout.machineIdentifierURL)
            platform.hardwareModel = hardwareModel
            platform.machineIdentifier = machineIdentifier
            platform.auxiliaryStorage = VZMacAuxiliaryStorage(url: layout.auxiliaryStorageURL)
            config.platform = platform
        }

        // Attach the raw disk image as the primary boot volume.
        let diskAttachment = try VZDiskImageStorageDeviceAttachment(url: layout.diskURL, readOnly: false)
        let diskDevice = VZVirtioBlockDeviceConfiguration(attachment: diskAttachment)
        diskDevice.blockDeviceIdentifier = isLinux ? "linux-root" : "macos-root"
        var storageDevices: [VZStorageDeviceConfiguration] = [diskDevice]

        // Attach installer ISO for Linux VMs if path is set and file exists
        if isLinux,
           let isoPath = storedConfig.installerISOPath,
           !isoPath.isEmpty,
           FileManager.default.fileExists(atPath: isoPath) {
            let isoURL = URL(fileURLWithPath: isoPath)
            let isoAttachment = try VZDiskImageStorageDeviceAttachment(url: isoURL, readOnly: true)
            let usbDevice = VZUSBMassStorageDeviceConfiguration(attachment: isoAttachment)
            storageDevices.append(usbDevice)
        }

        // Always attach GhostTools.dmg for macOS VMs (user can eject if not needed)
        if !isLinux, let dmgURL = Self.findGhostToolsDMG() {
            let dmgAttachment = try VZDiskImageStorageDeviceAttachment(url: dmgURL, readOnly: true)
            let usbDevice = VZUSBMassStorageDeviceConfiguration(attachment: dmgAttachment)
            storageDevices.append(usbDevice)
        }

        config.storageDevices = storageDevices

        // Network device — always use socketpair so policy can be switched at runtime
        let networkDevice = VZVirtioNetworkDeviceConfiguration()
        let networkPolicy = storedConfig.networkAccessPolicy

        // Create a socketpair: VM end gets a FileHandle attachment, host end
        // goes to NetworkFilterService for inspection/forwarding.
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_DGRAM, 0, &fds) == 0 else {
            throw VMError.message("Failed to create socketpair for network filtering: \(String(cString: strerror(errno)))")
        }
        let vmFD = fds[0]
        let hostFD = fds[1]

        let vmFileHandle = FileHandle(fileDescriptor: vmFD, closeOnDealloc: true)
        networkDevice.attachment = VZFileHandleNetworkDeviceAttachment(fileHandle: vmFileHandle)

        // Use persistent MAC address from config to ensure suspend/resume consistency.
        if let macAddressString = storedConfig.macAddress,
           let macAddress = VZMACAddress(string: macAddressString) {
            networkDevice.macAddress = macAddress
        }
        config.networkDevices = [networkDevice]

        // Serial console is always present; in CLI/headless mode we bridge STDIN/STDOUT so the user
        // can interact with launchd logs or a shell during early boot.
        // In GUI mode (connectSerialToStandardIO = false), we don't attach any file handles.
        let serialConfig = VZVirtioConsoleDeviceSerialPortConfiguration()
        if connectSerialToStandardIO {
            serialConfig.attachment = VZFileHandleSerialPortAttachment(
                fileHandleForReading: FileHandle.standardInput,
                fileHandleForWriting: FileHandle.standardOutput
            )
        }
        // When connectSerialToStandardIO is false, leave attachment as nil (no serial output)
        config.serialPorts = [serialConfig]

        if !headless {
            // GUI mode attaches a single display plus keyboard and pointing devices so VZVirtualMachineView works.
            // Use fixed display dimensions to ensure suspend/resume compatibility.
            // The display will auto-resize after start if automaticallyReconfiguresDisplay is enabled (macOS 14+).
            if isLinux {
                let graphics = VZVirtioGraphicsDeviceConfiguration()
                // Use 1920x1200 for Linux - this renders at 1:1 and is readable on HiDPI screens
                // (Linux guests don't auto-scale like macOS, so Retina resolutions make text tiny)
                graphics.scanouts = [VZVirtioGraphicsScanoutConfiguration(widthInPixels: 1920, heightInPixels: 1200)]
                config.graphicsDevices = [graphics]
            } else {
                let graphics = VZMacGraphicsDeviceConfiguration()
                let display = VZMacGraphicsDisplayConfiguration(widthInPixels: 2560, heightInPixels: 1600, pixelsPerInch: 110)
                graphics.displays = [display]
                config.graphicsDevices = [graphics]
            }
            config.keyboards = [VZUSBKeyboardConfiguration()]
            config.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
        } else {
            config.graphicsDevices = []
            config.keyboards = []
            config.pointingDevices = []
        }

        // Build list of shared folders from config and runtime override
        var sharedFolders: [SharedFolderConfig] = []

        // Priority: runtime override > stored sharedFolders > legacy sharedFolderPath
        if let runtimeSharedFolder = runtimeSharedFolder {
            sharedFolders = [SharedFolderConfig(path: runtimeSharedFolder.path, readOnly: runtimeSharedFolder.readOnly)]
        } else if !storedConfig.sharedFolders.isEmpty {
            sharedFolders = storedConfig.sharedFolders
        } else if let storedPath = storedConfig.sharedFolderPath {
            sharedFolders = [SharedFolderConfig(path: storedPath, readOnly: storedConfig.sharedFolderReadOnly)]
        }

        var directorySharingDevices: [VZDirectorySharingDeviceConfiguration] = []

        for (index, folder) in sharedFolders.enumerated() {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw VMError.message("Shared folder path \(folder.path) does not exist or is not a directory.")
            }
            let url = URL(fileURLWithPath: folder.path)
            let sharedDirectory = VZSharedDirectory(url: url, readOnly: folder.readOnly)
            let singleShare = VZSingleDirectoryShare(directory: sharedDirectory)

            // First folder uses macOS automount tag, subsequent folders use custom tags
            let tag: String
            if index == 0 {
                tag = VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag
            } else {
                tag = "ghostvm-share-\(index)"
            }

            let shareDevice = VZVirtioFileSystemDeviceConfiguration(tag: tag)
            shareDevice.share = singleShare
            directorySharingDevices.append(shareDevice)
        }

        config.directorySharingDevices = directorySharingDevices

        // Add vsock device for host-guest communication
        // This enables direct socket communication between host and guest without going through the network stack
        let socketDevice = VZVirtioSocketDeviceConfiguration()
        config.socketDevices = [socketDevice]

        do {
            try config.validate()
        } catch {
            throw VMError.message("Invalid VM configuration: \(error.localizedDescription)")
        }
        return VMConfigurationResult(configuration: config, networkFilterFD: hostFD, networkPolicy: networkPolicy)
    }

    /// Finds GhostTools.dmg in the app bundle or build output directory.
    private static func findGhostToolsDMG() -> URL? {
        // Check app bundle Resources first
        if let bundleURL = Bundle.main.url(forResource: "GhostTools", withExtension: "dmg") {
            return bundleURL
        }
        // Check build output directory for development
        let buildDMG = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("build/xcode/GhostTools.dmg")
        if FileManager.default.fileExists(atPath: buildDMG.path) {
            return buildDMG
        }
        return nil
    }
}
