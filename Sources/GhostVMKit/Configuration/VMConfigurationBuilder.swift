import Foundation
import AppKit
import Virtualization
import CoreGraphics

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
