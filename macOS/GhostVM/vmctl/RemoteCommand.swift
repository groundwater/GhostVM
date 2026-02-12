import Foundation
import GhostVMKit

/// Entry point and subcommand handlers for `vmctl remote`.
enum RemoteCommand {

    // MARK: - Entry Point

    static func run(arguments: [String]) throws {
        var args = arguments
        var socketPath: String?
        var vmName: String?

        // Parse --socket / --name before subcommand
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
            } else {
                break
            }
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
        case "screenshot":
            try handleScreenshot(client: client, arguments: arguments)
        case "pointer":
            try handlePointer(client: client, arguments: arguments)
        case "input":
            try handleInput(client: client, arguments: arguments)
        case "launch":
            try handleLaunch(client: client, arguments: arguments)
        case "activate":
            try handleActivate(client: client, arguments: arguments)
        case "a11y", "accessibility":
            try handleAccessibility(client: client, arguments: arguments)
        case "exec":
            try handleExec(client: client, arguments: arguments)
        case "clipboard":
            try handleClipboard(client: client, arguments: arguments)
        case "apps":
            try handleApps(client: client)
        case "interactive", "repl":
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
        print("Status: \(status)")
    }

    // MARK: - Screenshot

    private static func handleScreenshot(client: UnixSocketClient, arguments: [String]) throws {
        var args = arguments
        var outputPath = "screenshot.png"
        var elements = false
        var scale = "1.0"
        var format = "png"

        while !args.isEmpty {
            switch args[0] {
            case "-o", "--output":
                args.removeFirst()
                guard !args.isEmpty else { throw VMError.message("Missing value for -o") }
                outputPath = args.removeFirst()
            case "--elements":
                args.removeFirst()
                elements = true
            case "--scale":
                args.removeFirst()
                guard !args.isEmpty else { throw VMError.message("Missing value for --scale") }
                scale = args.removeFirst()
            case "--format":
                args.removeFirst()
                guard !args.isEmpty else { throw VMError.message("Missing value for --format") }
                format = args.removeFirst()
            default:
                throw VMError.message("Unknown screenshot option '\(args[0])'")
            }
        }

        if elements {
            // Annotated screenshot
            let json = try client.getJSON("/vm/screenshot/annotated?scale=\(scale)")

            // Write image
            if let base64 = json["screenshot"] as? String,
               let imageData = Data(base64Encoded: base64) {
                let url = URL(fileURLWithPath: (outputPath as NSString).expandingTildeInPath)
                try imageData.write(to: url)
                print("Wrote annotated screenshot to \(url.path)")
            } else {
                print("Warning: No screenshot image in response")
            }

            // Print element table
            if let elems = json["elements"] as? [[String: Any]] {
                print("\nElements (\(elems.count) visible):")
                for elem in elems {
                    let id = elem["id"] as? Int ?? 0
                    let role = elem["role"] as? String ?? ""
                    let label = elem["label"] as? String ?? elem["title"] as? String ?? ""
                    var frameStr = ""
                    if let frame = elem["frame"] as? [String: Any],
                       let x = frame["x"] as? Int, let y = frame["y"] as? Int,
                       let w = frame["w"] as? Int, let h = frame["h"] as? Int {
                        frameStr = "(\(x), \(y), \(w)x\(h))"
                    }
                    let labelDisplay = label.isEmpty ? "" : " \"\(label)\""
                    print("  [\(id)] \(role)\(labelDisplay)  \(frameStr)")
                }
            }
        } else {
            // Plain screenshot
            let path = "/vm/screenshot?format=\(format)&scale=\(scale)"
            let data = try client.getBinary(path)
            let url = URL(fileURLWithPath: (outputPath as NSString).expandingTildeInPath)
            try data.write(to: url)
            print("Wrote screenshot to \(url.path) (\(data.count) bytes)")
        }
    }

    // MARK: - Pointer

    private static func handlePointer(client: UnixSocketClient, arguments: [String]) throws {
        guard !arguments.isEmpty else {
            throw VMError.message("Usage: vmctl remote pointer <click|doubleclick|rightclick|drag|scroll> [options]")
        }

        var args = arguments
        let action = args.removeFirst()

        switch action {
        case "click", "doubleclick", "rightclick":
            try handlePointerClick(client: client, action: action, arguments: args)
        case "drag":
            try handlePointerDrag(client: client, arguments: args)
        case "scroll":
            try handlePointerScroll(client: client, arguments: args)
        default:
            throw VMError.message("Unknown pointer action '\(action)'. Use click, doubleclick, rightclick, drag, or scroll.")
        }
    }

    private static func handlePointerClick(client: UnixSocketClient, action: String, arguments: [String]) throws {
        var args = arguments
        var elementId: Int?
        var right = false
        var x: Double?
        var y: Double?

        while !args.isEmpty {
            switch args[0] {
            case "--element", "-e":
                args.removeFirst()
                guard !args.isEmpty, let id = Int(args[0]) else {
                    throw VMError.message("Invalid element ID")
                }
                elementId = id
                args.removeFirst()
            case "--right":
                args.removeFirst()
                right = true
            case "--":
                args.removeFirst()
                // Remaining args are coordinates (supports negative numbers)
                if args.count >= 2, let px = Double(args[0]), let py = Double(args[1]) {
                    x = px
                    y = py
                    args.removeFirst(2)
                }
            default:
                // Try parsing as coordinates
                if let px = Double(args[0]) {
                    x = px
                    args.removeFirst()
                    if !args.isEmpty, let py = Double(args[0]) {
                        y = py
                        args.removeFirst()
                    }
                } else {
                    throw VMError.message("Unknown pointer option '\(args[0])'")
                }
            }
        }

        // If element ID specified, fetch annotated screenshot to get coordinates
        if let elemId = elementId {
            let json = try client.getJSON("/vm/screenshot/annotated?scale=1.0")
            guard let elems = json["elements"] as? [[String: Any]] else {
                throw VMError.message("No elements in response")
            }
            guard let elem = elems.first(where: { ($0["id"] as? Int) == elemId }) else {
                throw VMError.message("Element \(elemId) not found")
            }
            guard let frame = elem["frame"] as? [String: Any],
                  let fx = frame["x"] as? Int, let fy = frame["y"] as? Int,
                  let fw = frame["w"] as? Int, let fh = frame["h"] as? Int else {
                throw VMError.message("Element \(elemId) has no frame")
            }
            // Center of element
            x = Double(fx) + Double(fw) / 2.0
            y = Double(fy) + Double(fh) / 2.0
            let label = elem["label"] as? String ?? elem["title"] as? String ?? ""
            print("Clicking element [\(elemId)] at (\(Int(x!)), \(Int(y!))) \(label)")
        }

        guard let clickX = x, let clickY = y else {
            throw VMError.message("Must specify coordinates (X Y) or --element N")
        }

        var body: [String: Any] = [
            "action": right ? "rightClick" : action,
            "x": clickX,
            "y": clickY
        ]
        if right || action == "rightclick" {
            body["button"] = "right"
            body["action"] = "click"
        }

        let _ = try client.postJSON("/api/v1/pointer", body: body)
        print("OK")
    }

    private static func handlePointerDrag(client: UnixSocketClient, arguments: [String]) throws {
        // pointer drag X1 Y1 -- X2 Y2
        var args = arguments
        var coords: [Double] = []

        // Collect all numeric args, skipping "--"
        for arg in args {
            if arg == "--" { continue }
            if let val = Double(arg) {
                coords.append(val)
            }
        }

        guard coords.count >= 4 else {
            throw VMError.message("Usage: vmctl remote pointer drag X1 Y1 -- X2 Y2")
        }

        let body: [String: Any] = [
            "action": "drag",
            "x": coords[0],
            "y": coords[1],
            "endX": coords[2],
            "endY": coords[3]
        ]
        let _ = try client.postJSON("/api/v1/pointer", body: body)
        print("OK")
    }

    private static func handlePointerScroll(client: UnixSocketClient, arguments: [String]) throws {
        var args = arguments
        var x: Double?
        var y: Double?
        var dx: Double = 0
        var dy: Double = 0

        // Parse: scroll X Y --dy N [--dx N]
        while !args.isEmpty {
            switch args[0] {
            case "--dy":
                args.removeFirst()
                guard !args.isEmpty, let val = Double(args[0]) else {
                    throw VMError.message("Invalid --dy value")
                }
                dy = val
                args.removeFirst()
            case "--dx":
                args.removeFirst()
                guard !args.isEmpty, let val = Double(args[0]) else {
                    throw VMError.message("Invalid --dx value")
                }
                dx = val
                args.removeFirst()
            default:
                if x == nil, let val = Double(args[0]) {
                    x = val
                    args.removeFirst()
                } else if y == nil, let val = Double(args[0]) {
                    y = val
                    args.removeFirst()
                } else {
                    throw VMError.message("Unknown scroll option '\(args[0])'")
                }
            }
        }

        guard let scrollX = x, let scrollY = y else {
            throw VMError.message("Usage: vmctl remote pointer scroll X Y --dy N [--dx N]")
        }

        let body: [String: Any] = [
            "action": "scroll",
            "x": scrollX,
            "y": scrollY,
            "deltaX": dx,
            "deltaY": dy
        ]
        let _ = try client.postJSON("/api/v1/pointer", body: body)
        print("OK")
    }

    // MARK: - Input

    private static func handleInput(client: UnixSocketClient, arguments: [String]) throws {
        guard !arguments.isEmpty else {
            throw VMError.message("Usage: vmctl remote input <type|key> [options]")
        }

        var args = arguments
        let action = args.removeFirst()

        switch action {
        case "type":
            guard !args.isEmpty else {
                throw VMError.message("Usage: vmctl remote input type <text...>")
            }
            let text = args.joined(separator: " ")
            let _ = try client.postJSON("/api/v1/input", body: ["text": text])
            print("OK")

        case "key":
            var modifiers: [String] = []
            var keys: [String] = []

            while !args.isEmpty {
                switch args[0] {
                case "--meta", "--cmd", "--command":
                    modifiers.append("command")
                    args.removeFirst()
                case "--shift":
                    modifiers.append("shift")
                    args.removeFirst()
                case "--ctrl", "--control":
                    modifiers.append("control")
                    args.removeFirst()
                case "--alt", "--option":
                    modifiers.append("option")
                    args.removeFirst()
                default:
                    keys.append(args.removeFirst())
                }
            }

            guard !keys.isEmpty else {
                throw VMError.message("Usage: vmctl remote input key [--meta] [--shift] [--ctrl] [--alt] <key>")
            }

            var body: [String: Any] = ["keys": keys]
            if !modifiers.isEmpty {
                body["modifiers"] = modifiers
            }
            let _ = try client.postJSON("/api/v1/input", body: body)
            print("OK")

        default:
            throw VMError.message("Unknown input action '\(action)'. Use 'type' or 'key'.")
        }
    }

    // MARK: - Launch / Activate

    private static func handleLaunch(client: UnixSocketClient, arguments: [String]) throws {
        guard let bundleId = arguments.first else {
            throw VMError.message("Usage: vmctl remote launch <bundleId>")
        }
        let _ = try client.postJSON("/api/v1/apps/launch", body: ["bundleId": bundleId])
        print("Launched \(bundleId)")
    }

    private static func handleActivate(client: UnixSocketClient, arguments: [String]) throws {
        guard let bundleId = arguments.first else {
            throw VMError.message("Usage: vmctl remote activate <bundleId>")
        }
        let _ = try client.postJSON("/api/v1/apps/activate", body: ["bundleId": bundleId])
        print("Activated \(bundleId)")
    }

    // MARK: - Accessibility

    private static func handleAccessibility(client: UnixSocketClient, arguments: [String]) throws {
        var args = arguments

        if args.isEmpty {
            // Default: show front app tree
            let json = try client.getJSON("/api/v1/accessibility?depth=3&target=front")
            printJSON(json)
            return
        }

        let action = args[0]

        switch action {
        case "--front", "--all":
            let target = action == "--all" ? "all" : "front"
            args.removeFirst()
            var depth = 3
            if args.count >= 2 && args[0] == "--depth" {
                args.removeFirst()
                depth = Int(args.removeFirst()) ?? 3
            }
            let json = try client.getJSON("/api/v1/accessibility?depth=\(depth)&target=\(target)")
            printJSON(json)

        case "click":
            args.removeFirst()
            guard !args.isEmpty else {
                throw VMError.message("Usage: vmctl remote a11y click <label>")
            }
            let label = args.joined(separator: " ")
            let _ = try client.postJSON("/api/v1/accessibility/action", body: [
                "label": label,
                "action": "AXPress"
            ])
            print("OK")

        case "menu":
            args.removeFirst()
            guard !args.isEmpty else {
                throw VMError.message("Usage: vmctl remote a11y menu <item1> <item2>...")
            }
            let _ = try client.postJSON("/api/v1/accessibility/menu", body: [
                "path": args
            ])
            print("OK")

        case "type":
            args.removeFirst()
            guard !args.isEmpty else {
                throw VMError.message("Usage: vmctl remote a11y type <value> [--label L] [--role R]")
            }
            var value: String?
            var label: String?
            var role: String?
            while !args.isEmpty {
                switch args[0] {
                case "--label":
                    args.removeFirst()
                    guard !args.isEmpty else { throw VMError.message("Missing --label value") }
                    label = args.removeFirst()
                case "--role":
                    args.removeFirst()
                    guard !args.isEmpty else { throw VMError.message("Missing --role value") }
                    role = args.removeFirst()
                default:
                    if value == nil {
                        value = args.removeFirst()
                    } else {
                        // Append to value
                        value! += " " + args.removeFirst()
                    }
                }
            }
            guard let val = value else {
                throw VMError.message("Missing value for a11y type")
            }
            var body: [String: Any] = ["value": val]
            if let l = label { body["label"] = l }
            if let r = role { body["role"] = r }
            let _ = try client.postJSON("/api/v1/accessibility/type", body: body)
            print("OK")

        case "--depth":
            // a11y --depth N
            args.removeFirst()
            let depth = Int(args.isEmpty ? "3" : args.removeFirst()) ?? 3
            let json = try client.getJSON("/api/v1/accessibility?depth=\(depth)&target=front")
            printJSON(json)

        default:
            throw VMError.message("Unknown a11y action '\(action)'. Use click, menu, type, --front, or --all.")
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
            if let content = json["content"] as? String {
                print(content)
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
            print("OK")

        default:
            throw VMError.message("Unknown clipboard action '\(action)'. Use 'get' or 'set'.")
        }
    }

    // MARK: - Apps

    private static func handleApps(client: UnixSocketClient) throws {
        let json = try client.getJSON("/api/v1/apps")
        if let apps = json["apps"] as? [[String: Any]] {
            for app in apps {
                let name = app["name"] as? String ?? "?"
                let bundleId = app["bundleId"] as? String ?? "?"
                let active = (app["isActive"] as? Bool) == true ? " *" : ""
                print("  \(name) (\(bundleId))\(active)")
            }
        } else {
            printJSON(json)
        }
    }

    // MARK: - Help

    static func showRemoteHelp() {
        let help = """
Usage: vmctl remote --name <VMName> <subcommand> [args...]
       vmctl remote --socket <path> <subcommand> [args...]

Subcommands:
  health                                     Check VM connection status
  screenshot [-o file] [--elements] [--scale N] [--format png|jpeg]
  pointer click [--element N] [--right] [X Y]
  pointer doubleclick [--element N] [X Y]
  pointer rightclick [--element N] [X Y]
  pointer drag X1 Y1 -- X2 Y2
  pointer scroll X Y --dy N [--dx N]
  input type <text...>
  input key [--meta] [--shift] [--ctrl] [--alt] <key>
  launch <bundleId>
  activate <bundleId>
  a11y [--front|--all] [--depth N]
  a11y click <label>
  a11y menu <item1> <item2>...
  a11y type <value> [--label L] [--role R]
  exec <command> [args...]
  clipboard get
  clipboard set <text>
  apps
  interactive                                Start interactive REPL

Examples:
  vmctl remote --name MyVM health
  vmctl remote --name MyVM screenshot --elements -o /tmp/screen.png
  vmctl remote --name MyVM pointer click --element 5
  vmctl remote --name MyVM pointer click 100 200
  vmctl remote --name MyVM input type "hello world"
  vmctl remote --name MyVM input key --meta l
  vmctl remote --name MyVM launch com.apple.Safari
  vmctl remote --name MyVM a11y --front --depth 3
  vmctl remote --name MyVM a11y click "OK"
  vmctl remote --name MyVM exec ls -la
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
