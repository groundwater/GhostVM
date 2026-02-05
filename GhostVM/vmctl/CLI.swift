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
        case "create-linux":
            do {
                try handleCreateLinux(arguments: Array(arguments.dropFirst()))
            } catch {
                fail(error)
            }
        case "detach-iso":
            do {
                try handleDetachISO(arguments: Array(arguments.dropFirst()))
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
        try controller.resumeVM(bundleURL: bundleURL, headless: headless, runtimeSharedFolder: runtimeSharedFolder)
    }

    private func handleDiscardSuspend(arguments: [String]) throws {
        guard let bundleArg = arguments.first else {
            throw VMError.message("Usage: vmctl discard-suspend <bundle-path>")
        }
        let bundleURL = try resolveBundleURL(argument: bundleArg, mustExist: true)
        try controller.discardSuspend(bundleURL: bundleURL)
    }

    private func handleCreateLinux(arguments: [String]) throws {
        guard let bundleArg = arguments.first else {
            throw VMError.message("Usage: vmctl create-linux <bundle-path> [--iso PATH] [--cpus N] [--memory GiB] [--disk GiB]")
        }
        let bundleURL = try resolveBundleURL(argument: bundleArg, mustExist: false)
        var opts = LinuxInitOptions()
        var index = 1
        while index < arguments.count {
            let arg = arguments[index]
            switch arg {
            case "--iso":
                index += 1
                guard index < arguments.count else {
                    throw VMError.message("Missing value for --iso.")
                }
                opts.isoPath = arguments[index]
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
            default:
                throw VMError.message("Unknown option '\(arg)'.")
            }
            index += 1
        }
        try controller.initLinuxVM(at: bundleURL, preferredName: nil, options: opts)
    }

    private func handleDetachISO(arguments: [String]) throws {
        guard let bundleArg = arguments.first else {
            throw VMError.message("Usage: vmctl detach-iso <bundle-path>")
        }
        let bundleURL = try resolveBundleURL(argument: bundleArg, mustExist: true)
        try controller.detachISO(bundleURL: bundleURL)
    }

    private func showHelp(exitCode: Int32) -> Never {
        print("""
Usage: vmctl <command> [options]

macOS VM Commands:
  init <bundle-path> [--cpus N] [--memory GiB] [--disk GiB] [--restore-image PATH] [--shared-folder PATH] [--writable]
  install <bundle-path>

Linux VM Commands:
  create-linux <bundle-path> [--iso PATH] [--cpus N] [--memory GiB] [--disk GiB]
  detach-iso <bundle-path>

Common Commands:
  start <bundle-path> [--headless] [--shared-folder PATH] [--writable|--read-only]
  stop <bundle-path>
  status <bundle-path>
  resume <bundle-path> [--headless] [--shared-folder PATH] [--writable|--read-only]
  discard-suspend <bundle-path>
  snapshot <bundle-path> list
  snapshot <bundle-path> <create|revert|delete> <snapshot-name>

macOS Examples:
  vmctl init ~/VMs/sandbox.GhostVM --cpus 6 --memory 16 --disk 128
  vmctl install ~/VMs/sandbox.GhostVM
  vmctl start ~/VMs/sandbox.GhostVM                    # GUI
  vmctl start ~/VMs/sandbox.GhostVM --headless         # headless (SSH after setup)

Linux Examples:
  vmctl create-linux ~/VMs/ubuntu.GhostVM --iso ~/Downloads/ubuntu-24.04-live-server-arm64.iso --disk 50 --memory 4 --cpus 4
  vmctl start ~/VMs/ubuntu.GhostVM                     # Boot into ISO installer
  vmctl detach-iso ~/VMs/ubuntu.GhostVM                # Remove ISO after installation

Common Examples:
  vmctl start ~/VMs/sandbox.GhostVM --shared-folder ~/Projects --writable
  vmctl stop ~/VMs/sandbox.GhostVM
  vmctl status ~/VMs/sandbox.GhostVM
  vmctl resume ~/VMs/sandbox.GhostVM                   # Resume from suspended state
  vmctl discard-suspend ~/VMs/sandbox.GhostVM          # Discard suspended state
  vmctl snapshot ~/VMs/sandbox.GhostVM list
  vmctl snapshot ~/VMs/sandbox.GhostVM create clean
  vmctl snapshot ~/VMs/sandbox.GhostVM revert clean
  vmctl snapshot ~/VMs/sandbox.GhostVM delete clean

Notes:
  - Linux VMs require ARM64 ISOs (aarch64). x86_64 ISOs will not work.
  - After installation, enable Remote Login (SSH) inside the guest for convenient headless access.
  - Apple's EULA requires macOS guests to run on Apple-branded hardware.
  - Use Virtual Machine > Suspend menu (Cmd+S) to suspend a running VM.
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
