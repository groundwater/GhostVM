import Foundation
import Virtualization

// Minimal runtime controller for a single VM bundle.
final class App2VMRunSession: NSObject, ObservableObject, VZVirtualMachineDelegate {
    enum State {
        case idle
        case starting
        case running
        case stopping
        case stopped
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var statusText: String = ""
    @Published private(set) var virtualMachine: VZVirtualMachine?

    let bundleURL: URL

    // Callbacks so the SwiftUI layer can reflect status into the list.
    var onStateChange: ((State) -> Void)?

    private let vmQueue: DispatchQueue
    private var stateObservation: NSKeyValueObservation?

    init(bundleURL: URL) {
        self.bundleURL = bundleURL.standardizedFileURL
        self.vmQueue = DispatchQueue(label: "ghostvm.app2.vm.\(bundleURL.lastPathComponent)")
        super.init()
    }

    func startIfNeeded() {
        switch state {
        case .running, .starting:
            return
        default:
            break
        }
        start()
    }

    func start() {
        guard VZVirtualMachine.isSupported else {
            transition(to: .failed("Virtualization is not supported on this Mac."))
            return
        }

        transition(to: .starting, message: "Starting…")

        let bundleURL = self.bundleURL
        vmQueue.async {
            do {
                let configuration = try App2VMRunSession.makeConfiguration(for: bundleURL)
                let vm = VZVirtualMachine(configuration: configuration, queue: self.vmQueue)
                vm.delegate = self

                DispatchQueue.main.async {
                    self.stateObservation = vm.observe(\.state, options: [.new]) { [weak self] virtualMachine, _ in
                        guard let self = self else { return }
                        if virtualMachine.state == .stopped {
                            self.stateObservation = nil
                            self.virtualMachine = nil
                            // Only mark as stopped if we haven't already marked a failure.
                            if case .failed = self.state {
                                return
                            }
                            self.transition(to: .stopped, message: "Stopped")
                        }
                    }
                    self.virtualMachine = vm
                }

                vm.start { result in
                    DispatchQueue.main.async {
                        switch result {
                        case .success:
                            self.transition(to: .running, message: "Running")
                        case .failure(let error):
                            self.virtualMachine = nil
                            self.transition(to: .failed(error.localizedDescription))
                        }
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.virtualMachine = nil
                    self.transition(to: .failed(error.localizedDescription))
                }
            }
        }
    }

    func stopIfNeeded() {
        switch state {
        case .running, .starting:
            stop()
        default:
            break
        }
    }

    func stop() {
        guard let vm = virtualMachine else {
            transition(to: .stopped, message: "Stopped")
            return
        }

        transition(to: .stopping, message: "Stopping…")

        vmQueue.async {
            do {
                // Request a graceful shutdown and wait for the guest OS
                // to terminate. We rely on the delegate callback to
                // observe when the VM has actually stopped.
                try vm.requestStop()
            } catch {
                DispatchQueue.main.async {
                    self.transition(to: .failed(error.localizedDescription))
                }
            }
        }
    }

    private func transition(to newState: State, message: String? = nil) {
        state = newState
        if let message = message {
            statusText = message
        } else {
            switch newState {
            case .idle:
                statusText = ""
            case .starting:
                statusText = "Starting…"
            case .running:
                statusText = "Running"
            case .stopping:
                statusText = "Stopping…"
            case .stopped:
                statusText = "Stopped"
            case .failed(let text):
                statusText = "Error: \(text)"
            }
        }
        onStateChange?(newState)
    }

    // MARK: - VZVirtualMachineDelegate

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: any Error) {
        DispatchQueue.main.async {
            self.stateObservation = nil
            self.virtualMachine = nil
            self.transition(to: .failed(error.localizedDescription))
        }
    }

    // MARK: - Configuration

    private static func makeConfiguration(for bundleURL: URL) throws -> VZVirtualMachineConfiguration {
        let layout = App2BundleLayout(bundleURL: bundleURL)
        let data = try Data(contentsOf: layout.configURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let stored = try decoder.decode(App2StoredConfig.self, from: data)

        let config = VZVirtualMachineConfiguration()
        config.bootLoader = VZMacOSBootLoader()
        config.cpuCount = stored.cpus
        config.memorySize = stored.memoryBytes

        let platform = VZMacPlatformConfiguration()
        let hardwareModelURL = layout.resolve(path: stored.hardwareModelPath)
        let machineIdentifierURL = layout.resolve(path: stored.machineIdentifierPath)
        let auxiliaryStorageURL = layout.resolve(path: stored.auxiliaryStoragePath)

        let hardwareData = try Data(contentsOf: hardwareModelURL)
        guard let hardwareModel = VZMacHardwareModel(dataRepresentation: hardwareData), hardwareModel.isSupported else {
            throw NSError(domain: "GhostVM.App2", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unsupported hardware model."])
        }

        let identifierData = try Data(contentsOf: machineIdentifierURL)
        guard let machineIdentifier = VZMacMachineIdentifier(dataRepresentation: identifierData) else {
            throw NSError(domain: "GhostVM.App2", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to decode machine identifier."])
        }

        platform.hardwareModel = hardwareModel
        platform.machineIdentifier = machineIdentifier
        platform.auxiliaryStorage = VZMacAuxiliaryStorage(url: auxiliaryStorageURL)
        config.platform = platform

        let diskURL = layout.resolve(path: stored.diskPath)
        let diskAttachment = try VZDiskImageStorageDeviceAttachment(url: diskURL, readOnly: false)
        let diskDevice = VZVirtioBlockDeviceConfiguration(attachment: diskAttachment)
        diskDevice.blockDeviceIdentifier = "macos-root"
        config.storageDevices = [diskDevice]

        let networkDevice = VZVirtioNetworkDeviceConfiguration()
        networkDevice.attachment = VZNATNetworkDeviceAttachment()
        config.networkDevices = [networkDevice]

        let graphics = VZMacGraphicsDeviceConfiguration()
        let display = VZMacGraphicsDisplayConfiguration(
            widthInPixels: 1920,
            heightInPixels: 1200,
            pixelsPerInch: 110
        )
        graphics.displays = [display]
        config.graphicsDevices = [graphics]
        config.keyboards = [VZUSBKeyboardConfiguration()]
        config.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]

        let serialConfig = VZVirtioConsoleDeviceSerialPortConfiguration()
        serialConfig.attachment = VZFileHandleSerialPortAttachment(
            fileHandleForReading: nil,
            fileHandleForWriting: FileHandle.standardOutput
        )
        config.serialPorts = [serialConfig]

        try config.validate()
        return config
    }
}
