import Foundation
import AppKit
import Virtualization

/// Builds VZVirtualMachineConfiguration from stored config and layout.
public final class VMConfigurationBuilder {
    public let layout: VMFileLayout
    public let storedConfig: VMStoredConfig

    public init(layout: VMFileLayout, storedConfig: VMStoredConfig) {
        self.layout = layout
        self.storedConfig = storedConfig
    }

    public func makeConfiguration(headless: Bool, connectSerialToStandardIO: Bool, runtimeSharedFolder: RuntimeSharedFolderOverride?) throws -> VZVirtualMachineConfiguration {
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
        // Use persistent MAC address from config to ensure suspend/resume consistency.
        if let macAddressString = storedConfig.macAddress,
           let macAddress = VZMACAddress(string: macAddressString) {
            networkDevice.macAddress = macAddress
        }
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
            // Use fixed display dimensions to ensure suspend/resume compatibility.
            // The display will auto-resize after start if automaticallyReconfiguresDisplay is enabled (macOS 14+).
            let graphics = VZMacGraphicsDeviceConfiguration()
            let display = VZMacGraphicsDisplayConfiguration(widthInPixels: 2560, heightInPixels: 1600, pixelsPerInch: 110)
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
