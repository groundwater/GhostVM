import Foundation
import GhostVMKit

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
        case "list", "ls":
            do {
                try handleList()
            } catch {
                fail(error)
            }
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
        case "resume":
            do {
                try handleResume(arguments: Array(arguments.dropFirst()))
            } catch {
                fail(error)
            }
        case "discard-suspend":
            do {
                try handleDiscardSuspend(arguments: Array(arguments.dropFirst()))
            } catch {
                fail(error)
            }
        case "remote":
            do {
                try RemoteCommand.run(arguments: Array(arguments.dropFirst()))
            } catch {
                fail(error)
            }
        case "socket":
            do {
                try handleSocket(arguments: Array(arguments.dropFirst()))
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

    private func handleList() throws {
        let entries = try controller.listVMs()
        if entries.isEmpty {
            print("No VMs found in \(controller.currentRootDirectory.path)")
            return
        }

        let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let apiDir = supportDir.appendingPathComponent("GhostVM/api")

        for entry in entries {
            let path = entry.bundleURL.path
            let status: String
            if entry.isRunning {
                let socketPath = apiDir.appendingPathComponent("\(entry.name).GhostVM.sock").path
                if FileManager.default.fileExists(atPath: socketPath) {
                    status = socketPath
                } else {
                    status = "RUNNING"
                }
            } else if entry.isSuspended {
                status = "SUSPENDED"
            } else {
                status = "STOPPED"
            }
            print("\(path)  \(status)")
        }
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
        if headless {
            try controller.startVM(bundleURL: bundleURL, headless: true, runtimeSharedFolder: runtimeSharedFolder)
        } else {
            try launchViaHelper(bundleURL: bundleURL)
        }
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
        guard arguments.count >= 2 else {
            throw VMError.message("Usage: vmctl snapshot <bundle-path> <list|create|revert|delete> [snapshot-name]")
        }
        let bundleURL = try resolveBundleURL(argument: arguments[0], mustExist: true)
        let subcommand = arguments[1]

        switch subcommand {
        case "list":
            try controller.snapshotList(bundleURL: bundleURL)
        case "create", "revert", "delete":
            guard arguments.count >= 3 else {
                throw VMError.message("Usage: vmctl snapshot <bundle-path> \(subcommand) <snapshot-name>")
            }
            let snapshotName = arguments[2]
            try controller.snapshot(bundleURL: bundleURL, subcommand: subcommand, snapshotName: snapshotName)
        default:
            throw VMError.message("Unknown snapshot subcommand '\(subcommand)'. Use 'list', 'create', 'revert', or 'delete'.")
        }
    }

    private func handleResume(arguments: [String]) throws {
        guard let bundleArg = arguments.first else {
            throw VMError.message("Usage: vmctl resume <bundle-path> [--headless] [--shared-folder PATH] [--writable|--read-only]")
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
        if headless {
            try controller.resumeVM(bundleURL: bundleURL, headless: true, runtimeSharedFolder: runtimeSharedFolder)
        } else {
            try launchViaHelper(bundleURL: bundleURL)
        }
    }

    private func handleDiscardSuspend(arguments: [String]) throws {
        guard let bundleArg = arguments.first else {
            throw VMError.message("Usage: vmctl discard-suspend <bundle-path>")
        }
        let bundleURL = try resolveBundleURL(argument: bundleArg, mustExist: true)
        try controller.discardSuspend(bundleURL: bundleURL)
    }

    private func handleSocket(arguments: [String]) throws {
        guard let bundleArg = arguments.first else {
            throw VMError.message("Usage: vmctl socket <bundle-path>")
        }
        let bundleURL = try resolveBundleURL(argument: bundleArg, mustExist: true)

        // Find the VM in the list to check if it's running
        let entries = try controller.listVMs()
        guard let entry = entries.first(where: { $0.bundleURL == bundleURL }) else {
            throw VMError.message("VM not found")
        }

        guard entry.isRunning else {
            throw VMError.message("VM is not running")
        }

        // Construct socket path
        let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let apiDir = supportDir.appendingPathComponent("GhostVM/api")
        let socketPath = apiDir.appendingPathComponent("\(entry.name).GhostVM.sock").path

        // Verify socket exists
        guard FileManager.default.fileExists(atPath: socketPath) else {
            throw VMError.message("VM is running but socket not found at \(socketPath)")
        }

        // Output just the socket path (for command substitution)
        print(socketPath)
    }

    // MARK: - Helper App Launch

    /// Find GhostVMHelper.app relative to the vmctl executable.
    /// Searches: 1) Parent app bundle (when vmctl is embedded in GhostVM.app)
    ///           2) Same directory as vmctl (standalone build)
    private func findHelperApp() -> URL? {
        let vmctlURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()

        // When embedded in GhostVM.app/Contents/MacOS/vmctl:
        // Helper is at GhostVM.app/Contents/PlugIns/Helpers/GhostVMHelper.app
        let appContents = vmctlURL
            .deletingLastPathComponent()  // MacOS/
            .deletingLastPathComponent()  // Contents/
        let embeddedHelper = appContents
            .appendingPathComponent("PlugIns")
            .appendingPathComponent("Helpers")
            .appendingPathComponent("GhostVMHelper.app")
        if FileManager.default.fileExists(atPath: embeddedHelper.path) {
            return embeddedHelper
        }

        // Standalone: same directory as vmctl
        let standaloneHelper = vmctlURL
            .deletingLastPathComponent()
            .appendingPathComponent("GhostVMHelper.app")
        if FileManager.default.fileExists(atPath: standaloneHelper.path) {
            return standaloneHelper
        }

        return nil
    }

    /// Launch a VM via GhostVMHelper (GUI mode with window + Dock icon).
    /// Copies the helper into the VM bundle, launches it, and waits for exit.
    private func launchViaHelper(bundleURL: URL) throws {
        guard let sourceHelper = findHelperApp() else {
            throw VMError.message("GhostVMHelper.app not found. Use --headless or run vmctl from within GhostVM.app.")
        }

        let helperManager = VMHelperBundleManager()
        let helperURL = try helperManager.copyHelperApp(vmBundleURL: bundleURL, sourceHelperAppURL: sourceHelper)

        let vmName = controller.displayName(for: bundleURL)
        let bundlePath = bundleURL.standardizedFileURL.path

        print("Starting VM '\(vmName)'...")

        // Launch helper via open(1) — works from CLI without NSApplication
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [
            "-n",           // new instance
            "-a", helperURL.path,
            "-W",           // wait for app to exit
            "--args", "--vm-bundle", bundlePath
        ]

        // Forward SIGINT to the helper process
        let signalSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        signal(SIGINT, SIG_IGN)
        signalSource.setEventHandler {
            // Send terminate notification to helper
            let hash = bundlePath.stableHash
            DistributedNotificationCenter.default().postNotificationName(
                NSNotification.Name("com.ghostvm.helper.terminate.\(hash)"),
                object: nil,
                userInfo: nil,
                deliverImmediately: true
            )
        }
        signalSource.resume()

        try process.run()
        process.waitUntilExit()

        signalSource.cancel()
        signal(SIGINT, SIG_DFL)

        if process.terminationStatus != 0 {
            throw VMError.message("Helper exited with status \(process.terminationStatus)")
        }
    }

    private func showHelp(exitCode: Int32) -> Never {
        let help = """
Usage: vmctl <command> [options]

Commands:
  list                                   List VMs and their state
  socket <bundle-path>                   Get socket path for running VM
  init <bundle-path> [--cpus N] [--memory GiB] [--disk GiB] [--restore-image PATH] [--shared-folder PATH] [--writable]
  install <bundle-path>
  start <bundle-path> [--headless] [--shared-folder PATH] [--writable|--read-only]
  stop <bundle-path>
  status <bundle-path>
  resume <bundle-path> [--headless] [--shared-folder PATH] [--writable|--read-only]
  discard-suspend <bundle-path>
  snapshot <bundle-path> list
  snapshot <bundle-path> <create|revert|delete> <snapshot-name>
  remote --name <VMName> [--json] <subcommand> [args...]
  remote --socket <path> [--json] <subcommand> [args...]

Remote flags:
  --json                                 Output JSON (default: human-readable if TTY)

Remote subcommands (use 'vmctl remote --help' for full details):
  health                                      Check VM connection
  exec <command> [args...]                    Run command in guest
  clipboard get | set <text>                  Guest clipboard
  apps                                        List running apps
  interactive                                 Start interactive REPL

Examples:
  vmctl init ~/VMs/sandbox.GhostVM --cpus 6 --memory 16 --disk 128
  vmctl install ~/VMs/sandbox.GhostVM
  vmctl start ~/VMs/sandbox.GhostVM                    # GUI
  vmctl start ~/VMs/sandbox.GhostVM --headless         # headless (SSH after setup)
  vmctl start ~/VMs/sandbox.GhostVM --shared-folder ~/Projects --writable
  vmctl stop ~/VMs/sandbox.GhostVM
  vmctl status ~/VMs/sandbox.GhostVM
  vmctl resume ~/VMs/sandbox.GhostVM                   # Resume from suspended state
  vmctl discard-suspend ~/VMs/sandbox.GhostVM          # Discard suspended state
  vmctl snapshot ~/VMs/sandbox.GhostVM list
  vmctl snapshot ~/VMs/sandbox.GhostVM create clean
  vmctl snapshot ~/VMs/sandbox.GhostVM revert clean
  vmctl snapshot ~/VMs/sandbox.GhostVM delete clean
  vmctl socket ~/VMs/sandbox.GhostVM                   # Get socket path for running VM
  vmctl remote --socket $(vmctl socket Aria) interactive  # Use with command substitution
  vmctl remote --name MyVM health
  vmctl remote --name MyVM exec ls -la
  vmctl remote --name MyVM clipboard get
  vmctl remote --name MyVM apps
  vmctl remote --name MyVM interactive

Notes:
  - After installation, enable Remote Login (SSH) inside the guest for convenient headless access.
  - Apple's EULA requires macOS guests to run on Apple-branded hardware.
  - Use Virtual Machine > Suspend menu (Cmd+S) to suspend a running VM.
"""
        print(help)
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
