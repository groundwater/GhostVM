import Foundation
import GhostVMKit
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Entry point and subcommand handlers for `vmctl remote`.
enum RemoteCommand {

    // MARK: - Entry Point

    /// Output mode: true = JSON, false = human-readable
    private static var shouldOutputJSON = false

    /// Check if stdout is a TTY
    private static func isOutputTTY() -> Bool {
        return isatty(STDOUT_FILENO) != 0
    }

    /// Determine output format based on --json flag and TTY detection
    private static func determineOutputFormat(jsonFlag: Bool) {
        // Use JSON if explicitly requested OR if not a TTY
        shouldOutputJSON = jsonFlag || !isOutputTTY()
    }

    static func run(arguments: [String]) throws {
        var args = arguments
        var socketPath: String?
        var vmName: String?
        var jsonOutput = false

        // Parse --socket / --name / --json before subcommand
        while !args.isEmpty {
            if args[0] == "--socket" || args[0] == "-s" {
                args.removeFirst()
                guard !args.isEmpty else {
                    throw VMError.message("Missing value for --socket")
                }
                socketPath = args.removeFirst()
            } else if args[0] == "--name" || args[0] == "-n" {
                args.removeFirst()
                guard !args.isEmpty else {
                    throw VMError.message("Missing value for --name")
                }
                vmName = args.removeFirst()
            } else if args[0] == "--json" {
                jsonOutput = true
                args.removeFirst()
            } else {
                break
            }
        }

        // Determine output format
        determineOutputFormat(jsonFlag: jsonOutput)

        // Check for help before validating socket
        if !args.isEmpty && (args[0] == "help" || args[0] == "--help" || args[0] == "-h") {
            showRemoteHelp()
            return
        }

        // Resolve socket path
        let resolvedPath: String
        if let sp = socketPath {
            resolvedPath = (sp as NSString).expandingTildeInPath
        } else if let name = vmName {
            let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            resolvedPath = supportDir.appendingPathComponent("GhostVM/api/\(name).GhostVM.sock").path
        } else {
            throw VMError.message("Must specify --socket <path> or --name <VMName>.\nUsage: vmctl remote --name <VMName> <subcommand> [args...]")
        }

        // Validate socket exists
        guard FileManager.default.fileExists(atPath: resolvedPath) else {
            throw VMError.message("Socket not found at \(resolvedPath)\nIs the VM running?")
        }

        let client = UnixSocketClient(socketPath: resolvedPath)

        guard !args.isEmpty else {
            throw VMError.message("Missing subcommand. Use 'vmctl remote --help' for usage.")
        }

        let subcommand = args.removeFirst()
        try dispatchSubcommand(client: client, subcommand: subcommand, arguments: args)
    }

    // MARK: - Dispatch (shared with REPL)

    static func dispatchSubcommand(client: UnixSocketClient, subcommand: String, arguments: [String]) throws {
        switch subcommand {
        case "health":
            try handleHealth(client: client)
        case "exec":
            try handleExec(client: client, arguments: arguments)
        case "clipboard":
            try handleClipboard(client: client, arguments: arguments)
        case "apps":
            try handleApps(client: client)
        case "interactive", "repl":
            if shouldOutputJSON {
                throw VMError.message("Interactive mode is not compatible with --json flag. Use individual commands instead.")
            }
            InteractiveREPL.run(client: client)
        case "--help", "-h", "help":
            showRemoteHelp()
        default:
            throw VMError.message("Unknown remote subcommand '\(subcommand)'. Use 'vmctl remote --help' for usage.")
        }
    }

    // MARK: - Health

    private static func handleHealth(client: UnixSocketClient) throws {
        let json = try client.getJSON("/health")
        let status = json["status"] as? String ?? "unknown"

        if shouldOutputJSON {
            printJSON(["status": "ok", "health": status])
        } else {
            print("Status: \(status)")
        }
    }

    // MARK: - Exec

    private static func handleExec(client: UnixSocketClient, arguments: [String]) throws {
        guard !arguments.isEmpty else {
            throw VMError.message("Usage: vmctl remote exec <command> [args...]")
        }

        var args = arguments
        let command = args.removeFirst()

        var body: [String: Any] = ["command": command]
        if !args.isEmpty {
            body["args"] = args
        }

        let json = try client.postJSON("/api/v1/exec", body: body)

        if shouldOutputJSON {
            printJSON([
                "status": "ok",
                "command": command,
                "args": args,
                "stdout": json["stdout"] as? String ?? "",
                "stderr": json["stderr"] as? String ?? "",
                "exitCode": json["exitCode"] as? Int ?? 0
            ])
        } else {
            if let stdout = json["stdout"] as? String, !stdout.isEmpty {
                print(stdout, terminator: stdout.hasSuffix("\n") ? "" : "\n")
            }
            if let stderr = json["stderr"] as? String, !stderr.isEmpty {
                FileHandle.standardError.write(Data((stderr).utf8))
                if !stderr.hasSuffix("\n") {
                    FileHandle.standardError.write(Data("\n".utf8))
                }
            }
            if let exitCode = json["exitCode"] as? Int, exitCode != 0 {
                print("Exit code: \(exitCode)")
            }
        }
    }

    // MARK: - Clipboard

    private static func handleClipboard(client: UnixSocketClient, arguments: [String]) throws {
        guard !arguments.isEmpty else {
            throw VMError.message("Usage: vmctl remote clipboard <get|set> [text]")
        }

        var args = arguments
        let action = args.removeFirst()

        switch action {
        case "get":
            let json = try client.getJSON("/api/v1/clipboard")
            let content = json["content"] as? String ?? ""

            if shouldOutputJSON {
                printJSON([
                    "status": "ok",
                    "action": "get",
                    "content": content
                ])
            } else {
                if !content.isEmpty {
                    print(content)
                }
            }

        case "set":
            guard !args.isEmpty else {
                throw VMError.message("Usage: vmctl remote clipboard set <text>")
            }
            let text = args.joined(separator: " ")
            let _ = try client.postJSON("/api/v1/clipboard", body: [
                "content": text,
                "type": "public.utf8-plain-text"
            ])

            if shouldOutputJSON {
                printJSON([
                    "status": "ok",
                    "action": "set",
                    "content": text
                ])
            } else {
                print("OK")
            }

        default:
            throw VMError.message("Unknown clipboard action '\(action)'. Use 'get' or 'set'.")
        }
    }

    // MARK: - Apps

    private static func handleApps(client: UnixSocketClient) throws {
        let json = try client.getJSON("/api/v1/apps")

        if shouldOutputJSON {
            if let apps = json["apps"] as? [[String: Any]] {
                printJSON([
                    "status": "ok",
                    "apps": apps.map { app in
                        [
                            "name": app["name"] as? String ?? "",
                            "bundleId": app["bundleId"] as? String ?? "",
                            "isActive": app["isActive"] as? Bool ?? false
                        ]
                    }
                ])
            } else {
                printJSON(["status": "ok", "apps": []])
            }
        } else {
            if let apps = json["apps"] as? [[String: Any]] {
                print("Running applications (\(apps.count)):")
                for app in apps {
                    let name = app["name"] as? String ?? "?"
                    let bundleId = app["bundleId"] as? String ?? "?"
                    let active = (app["isActive"] as? Bool) == true ? " *" : ""
                    print("  \(name) (\(bundleId))\(active)")
                }
            }
        }
    }

    // MARK: - Help

    static func showRemoteHelp() {
        let help = """
Usage: vmctl remote --name <VMName> [--json] <subcommand> [args...]
       vmctl remote --socket <path> [--json] <subcommand> [args...]

Flags:
  --socket <path>  Unix socket path (auto-detected if --name used)
  --name <VMName>  VM name (resolves socket from VM bundle)
  --json           Output responses as JSON (default: human-readable if TTY)

Subcommands:
  health                                     Check VM connection status
  exec <command> [args...]
  clipboard get
  clipboard set <text>
  apps
  interactive                                Start interactive REPL

Examples:
  vmctl remote --name MyVM health
  vmctl remote --name MyVM exec ls -la
  vmctl remote --name MyVM clipboard get
  vmctl remote --name MyVM apps
  vmctl remote --name MyVM interactive
"""
        print(help)
    }

    // MARK: - Helpers

    private static func printJSON(_ obj: Any) {
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
           let str = String(data: data, encoding: .utf8) {
            print(str)
        }
    }
}
