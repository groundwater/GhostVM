---
name: Virtualization
description: Create and manage macOS VMs with Virtualization.framework. Use when working with VZVirtualMachine, VM lifecycle, IPSW installation, or VM configuration. (project)
---

# Virtualization.framework (macOS)

## VM Lifecycle

```swift
import Virtualization

// Create configuration
let config = VZVirtualMachineConfiguration()
config.cpuCount = 4
config.memorySize = 8 * 1024 * 1024 * 1024  // 8 GB

// Platform configuration (macOS guest)
let platform = VZMacPlatformConfiguration()
platform.hardwareModel = try VZMacHardwareModel(dataRepresentation: hardwareModelData)
platform.machineIdentifier = try VZMacMachineIdentifier(dataRepresentation: machineIdData)
platform.auxiliaryStorage = try VZMacAuxiliaryStorage(contentsOf: auxStorageURL)
config.platform = platform

// Boot loader
config.bootLoader = VZMacOSBootLoader()

// Validate and create
try config.validate()
let vm = VZVirtualMachine(configuration: config)
```

## Starting/Stopping VMs

```swift
// Start (must be on main thread)
try await vm.start()

// Stop gracefully
try await vm.stop()

// Force stop
try await vm.stop(shouldStopDespiteErrors: true)

// Pause/Resume
try await vm.pause()
try await vm.resume()
```

## VM State Observation

```swift
// KVO observation
vm.observe(\.state, options: [.new]) { vm, _ in
    switch vm.state {
    case .stopped: print("Stopped")
    case .running: print("Running")
    case .paused: print("Paused")
    case .error: print("Error")
    case .starting: print("Starting")
    case .stopping: print("Stopping")
    case .saving: print("Saving")
    case .restoring: print("Restoring")
    @unknown default: break
    }
}
```

## Installing macOS from IPSW

```swift
// Fetch latest supported IPSW
let restoreImage = try await VZMacOSRestoreImage.latestSupported

// Or load from file
let restoreImage = try await VZMacOSRestoreImage.image(from: ipswURL)

// Check compatibility
guard let config = restoreImage.mostFeaturefulSupportedConfiguration else {
    throw VMError.unsupportedHardware
}

// Create installer
let installer = VZMacOSInstaller(virtualMachine: vm, restoringFrom: ipswURL)

// Install with progress
try await installer.install { progress in
    print("Progress: \(progress.fractionCompleted * 100)%")
}
```

## Common Devices

```swift
// Disk
let diskAttachment = try VZDiskImageStorageDeviceAttachment(url: diskURL, readOnly: false)
config.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: diskAttachment)]

// Network (NAT)
let network = VZVirtioNetworkDeviceConfiguration()
network.attachment = VZNATNetworkDeviceAttachment()
config.networkDevices = [network]

// Display
let graphics = VZMacGraphicsDeviceConfiguration()
graphics.displays = [VZMacGraphicsDisplayConfiguration(
    widthInPixels: 1920,
    heightInPixels: 1200,
    pixelsPerInch: 144
)]
config.graphicsDevices = [graphics]

// Keyboard/Mouse
config.keyboards = [VZUSBKeyboardConfiguration()]
config.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
```

## Entitlements Required

```xml
<key>com.apple.security.virtualization</key>
<true/>
```

## SwiftUI Integration

```swift
// Wrap VZVirtualMachineView
struct VMDisplayHost: NSViewRepresentable {
    let vm: VZVirtualMachine

    func makeNSView(context: Context) -> VZVirtualMachineView {
        let view = VZVirtualMachineView()
        view.virtualMachine = vm
        view.capturesSystemKeys = true
        return view
    }

    func updateNSView(_ view: VZVirtualMachineView, context: Context) {
        view.virtualMachine = vm
    }
}
```

## Don't

- Start/stop VMs from background threads (use MainActor)
- Forget to validate configuration before creating VM
- Ignore VZError cases (check for .invalidVirtualMachineState)
- Assume IPSW compatibility (always check mostFeaturefulSupportedConfiguration)
- Create sparse disk images without proper allocation (use `truncate -s` or FileManager)
