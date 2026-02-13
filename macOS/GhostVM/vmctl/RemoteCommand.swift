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
            let url = URL(fileURLWithPath: (outputPath as NSString).expandingTildeInPath)
            if let base64 = json["screenshot"] as? String,
               let imageData = Data(base64Encoded: base64) {
                try imageData.write(to: url)
            }

            if shouldOutputJSON {
                printJSON([
                    "status": "ok",
                    "path": url.path,
                    "elements": json["elements"] ?? []
                ])
            } else {
                print("Wrote annotated screenshot to \(url.path)")

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
            }
        } else {
            // Plain screenshot
            let path = "/vm/screenshot?format=\(format)&scale=\(scale)"
            let data = try client.getBinary(path)
            let url = URL(fileURLWithPath: (outputPath as NSString).expandingTildeInPath)
            try data.write(to: url)

            if shouldOutputJSON {
                printJSON([
                    "status": "ok",
                    "path": url.path,
                    "size": data.count
                ])
            } else {
                print("Wrote screenshot to \(url.path) (\(data.count) bytes)")
            }
        }
    }

    // MARK: - Pointer

    private static func handlePointer(client: UnixSocketClient, arguments: [String]) throws {
        guard !arguments.isEmpty else {
            throw VMError.message("Usage: vmctl remote pointer <leftclick|rightclick|middleclick|doubleclick|drag|scroll> [options]")
        }

        var args = arguments
        let action = args.removeFirst()

        switch action {
        case "leftclick", "doubleclick", "rightclick", "middleclick":
            try handlePointerClick(client: client, action: action, arguments: args)
        case "drag":
            try handlePointerDrag(client: client, arguments: args)
        case "scroll":
            try handlePointerScroll(client: client, arguments: args)
        default:
            throw VMError.message("Unknown pointer action '\(action)'. Use leftclick, rightclick, middleclick, doubleclick, drag, or scroll.")
        }
    }

    private static func handlePointerClick(client: UnixSocketClient, action: String, arguments: [String]) throws {
        var args = arguments
        var elementId: Int?
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
        var elementLabel: String?
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
            elementLabel = elem["label"] as? String ?? elem["title"] as? String ?? ""
            if !shouldOutputJSON {
                print("Clicking element [\(elemId)] at (\(Int(x!)), \(Int(y!))) \(elementLabel ?? "")")
            }
        }

        guard let clickX = x, let clickY = y else {
            throw VMError.message("Must specify coordinates (X Y) or --element N")
        }

        // Map CLI action names to guest-side PointerAction values
        let guestAction: String
        switch action {
        case "leftclick":   guestAction = "click"
        case "rightclick":  guestAction = "rightClick"
        case "middleclick": guestAction = "middleClick"
        case "doubleclick": guestAction = "doubleClick"
        default:            guestAction = action
        }

        let body: [String: Any] = [
            "action": guestAction,
            "x": clickX,
            "y": clickY
        ]

        let _ = try client.postJSON("/api/v1/pointer", body: body)

        if shouldOutputJSON {
            var result: [String: Any] = [
                "status": "ok",
                "action": action,
                "x": clickX,
                "y": clickY
            ]
            if let elemId = elementId {
                result["element"] = elemId
            }
            if let label = elementLabel {
                result["label"] = label
            }
            printJSON(result)
        } else {
            print("OK")
        }
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

        if shouldOutputJSON {
            printJSON([
                "status": "ok",
                "action": "drag",
                "x": coords[0],
                "y": coords[1],
                "endX": coords[2],
                "endY": coords[3]
            ])
        } else {
            print("OK")
        }
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

        if shouldOutputJSON {
            printJSON([
                "status": "ok",
                "action": "scroll",
                "x": scrollX,
                "y": scrollY,
                "deltaX": dx,
                "deltaY": dy
            ])
        } else {
            print("OK")
        }
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

            if shouldOutputJSON {
                printJSON([
                    "status": "ok",
                    "action": "type",
                    "text": text
                ])
            } else {
                print("OK")
            }

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

            if shouldOutputJSON {
                var result: [String: Any] = [
                    "status": "ok",
                    "action": "key",
                    "keys": keys
                ]
                if !modifiers.isEmpty {
                    result["modifiers"] = modifiers
                }
                printJSON(result)
            } else {
                print("OK")
            }

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

        if shouldOutputJSON {
            printJSON([
                "status": "ok",
                "action": "launch",
                "bundleId": bundleId
            ])
        } else {
            print("Launched \(bundleId)")
        }
    }

    private static func handleActivate(client: UnixSocketClient, arguments: [String]) throws {
        guard let bundleId = arguments.first else {
            throw VMError.message("Usage: vmctl remote activate <bundleId>")
        }
        let _ = try client.postJSON("/api/v1/apps/activate", body: ["bundleId": bundleId])

        if shouldOutputJSON {
            printJSON([
                "status": "ok",
                "action": "activate",
                "bundleId": bundleId
            ])
        } else {
            print("Activated \(bundleId)")
        }
    }

    // MARK: - Accessibility

    /// Parse target flags from args, consuming them. Returns the target query value.
    /// Supports: --front, --all, --visible, --pid N, --app bundleId
    private static func parseTarget(_ args: inout [String]) -> String {
        var target = "front"
        while !args.isEmpty {
            switch args[0] {
            case "--front":
                target = "front"
                args.removeFirst()
            case "--all":
                target = "all"
                args.removeFirst()
            case "--visible":
                target = "visible"
                args.removeFirst()
            case "--pid":
                args.removeFirst()
                if !args.isEmpty {
                    target = "pid:\(args.removeFirst())"
                }
            case "--app":
                args.removeFirst()
                if !args.isEmpty {
                    target = "app:\(args.removeFirst())"
                }
            default:
                return target
            }
        }
        return target
    }

    private static func handleAccessibility(client: UnixSocketClient, arguments: [String]) throws {
        var args = arguments

        if args.isEmpty {
            // Default: show front app tree
            let json = try client.getJSON("/api/v1/accessibility?depth=3&target=front")
            if shouldOutputJSON {
                printJSON(["status": "ok", "tree": json])
            } else {
                let app = json["app"] as? String ?? "Unknown"
                print("Accessibility Tree: \(app) (depth 3)")
                if let tree = json["tree"] as? [String: Any] {
                    print(formatA11yTree(tree, prefix: ""))
                } else {
                    print("No accessibility data available")
                }
            }
            return
        }

        // Check if first arg is a subcommand or a flag
        let action = args[0]

        switch action {
        // Tree query: a11y [--front|--all|--visible|--pid N|--app B] [--depth N]
        case "--front", "--all", "--visible", "--pid", "--app", "--depth":
            let target = parseTarget(&args)
            var depth = 3
            if args.count >= 2 && args[0] == "--depth" {
                args.removeFirst()
                depth = Int(args.removeFirst()) ?? 3
            }

            // Multi-target returns array, single target returns object
            let isMulti = (target == "all" || target == "visible")
            let path = "/api/v1/accessibility?depth=\(depth)&target=\(target)"

            if isMulti {
                // Response is an array of AXTreeResponse
                let resp = try client.request(method: "GET", path: path)
                guard resp.isSuccess else {
                    throw VMError.message(resp.errorMessage)
                }

                if shouldOutputJSON {
                    guard let json = resp.bodyJSON else {
                        let preview = resp.bodyString?.prefix(500) ?? "<empty>"
                        throw VMError.message("Invalid JSON response. Body: \(preview)")
                    }
                    printJSON(["status": "ok", "target": target, "depth": depth, "trees": json])
                } else {
                    guard let jsonArray = try? JSONSerialization.jsonObject(with: resp.body) as? [[String: Any]] else {
                        throw VMError.message("Expected array of trees")
                    }
                    print("Accessibility Trees (\(target), depth \(depth)):")
                    print("Found \(jsonArray.count) app(s)\n")
                    for (index, item) in jsonArray.enumerated() {
                        let app = item["app"] as? String ?? "Unknown"
                        let bundleId = item["bundleId"] as? String ?? ""
                        print("[\(index + 1)] \(app) (\(bundleId))")
                        if let tree = item["tree"] as? [String: Any] {
                            print(formatA11yTree(tree, prefix: ""))
                        }
                        if index < jsonArray.count - 1 {
                            print("")
                        }
                    }
                }
            } else {
                // Response is a single AXTreeResponse
                let json = try client.getJSON(path)
                if shouldOutputJSON {
                    printJSON(["status": "ok", "target": target, "depth": depth, "tree": json])
                } else {
                    let app = json["app"] as? String ?? "Unknown"
                    print("Accessibility Tree: \(app) (depth \(depth))")
                    if let tree = json["tree"] as? [String: Any] {
                        print(formatA11yTree(tree, prefix: ""))
                    } else {
                        print("No accessibility data available")
                    }
                }
            }

        // Focused element: a11y focused [--target flags]
        case "focused":
            args.removeFirst()
            let target = parseTarget(&args)
            let json = try client.getJSON("/api/v1/accessibility/focused?target=\(target)")
            if shouldOutputJSON {
                printJSON(["status": "ok", "target": target, "focused": json])
            } else {
                print("Focused Element:")
                let role = json["role"] as? String
                if role == "none" || (json["focused"] as? Bool) == false {
                    print("  No focused element")
                } else {
                    print(formatA11yElement(json))
                }
            }

        // Interactive elements: a11y elements
        case "elements":
            args.removeFirst()
            let resp = try client.request(method: "GET", path: "/api/v1/elements")
            guard resp.isSuccess, let json = resp.bodyJSON else {
                throw VMError.message(resp.errorMessage)
            }

            if shouldOutputJSON {
                printJSON([
                    "status": "ok",
                    "elements": json["elements"] ?? [],
                    "scrollState": json["scrollState"] ?? [:],
                    "hasModalDialog": json["hasModalDialog"] ?? false
                ])
            } else {
                if let elems = json["elements"] as? [[String: Any]] {
                    print("Interactive elements (\(elems.count)):")
                    for elem in elems {
                        let id = elem["id"] as? Int ?? 0
                        let role = elem["role"] as? String ?? ""
                        let label = elem["label"] as? String ?? elem["title"] as? String ?? ""
                        let value = elem["value"] as? String
                        var frameStr = ""
                        if let frame = elem["frame"] as? [String: Any],
                           let x = frame["x"] as? Int, let y = frame["y"] as? Int,
                           let w = frame["w"] as? Int, let h = frame["h"] as? Int {
                            frameStr = "(\(x), \(y), \(w)x\(h))"
                        }
                        let labelDisplay = label.isEmpty ? "" : " \"\(label)\""
                        let valueDisplay = (value != nil && !value!.isEmpty) ? " = \"\(value!)\"" : ""
                        print("  [\(id)] \(role)\(labelDisplay)\(valueDisplay)  \(frameStr)")
                    }
                }
                // Print scroll state if present
                if let scroll = json["scrollState"] as? [String: Any] {
                    let up = (scroll["canScrollUp"] as? Bool) == true
                    let down = (scroll["canScrollDown"] as? Bool) == true
                    let left = (scroll["canScrollLeft"] as? Bool) == true
                    let right = (scroll["canScrollRight"] as? Bool) == true
                    if up || down || left || right {
                        var dirs: [String] = []
                        if up { dirs.append("up") }
                        if down { dirs.append("down") }
                        if left { dirs.append("left") }
                        if right { dirs.append("right") }
                        print("  Scroll: \(dirs.joined(separator: ", "))")
                    }
                }
                if let modal = json["hasModalDialog"] as? Bool, modal {
                    print("  Modal dialog detected")
                }
            }

        // Click by label: a11y click <label> [--role R] [--target flags]
        case "click":
            args.removeFirst()
            var label: String?
            var role: String?
            var targetArgs: [String] = []

            while !args.isEmpty {
                switch args[0] {
                case "--role":
                    args.removeFirst()
                    guard !args.isEmpty else { throw VMError.message("Missing --role value") }
                    role = args.removeFirst()
                case "--front", "--all", "--visible", "--pid", "--app":
                    // Collect target flags for parseTarget
                    targetArgs.append(args.removeFirst())
                    if !args.isEmpty && !args[0].hasPrefix("-") && (targetArgs.last == "--pid" || targetArgs.last == "--app") {
                        targetArgs.append(args.removeFirst())
                    }
                default:
                    if label == nil {
                        label = args.removeFirst()
                    } else {
                        label! += " " + args.removeFirst()
                    }
                }
            }

            guard let clickLabel = label else {
                throw VMError.message("Usage: vmctl remote a11y click <label> [--role R]")
            }
            let target = targetArgs.isEmpty ? "front" : { var t = targetArgs; return parseTarget(&t) }()

            var body: [String: Any] = ["label": clickLabel, "action": "AXPress"]
            if let r = role { body["role"] = r }
            let _ = try client.postJSON("/api/v1/accessibility/action?target=\(target)", body: body)

            if shouldOutputJSON {
                var result: [String: Any] = [
                    "status": "ok",
                    "action": "click",
                    "label": clickLabel,
                    "target": target
                ]
                if let r = role { result["role"] = r }
                printJSON(result)
            } else {
                print("OK")
            }

        // Arbitrary action: a11y action <label> [--action AXPress] [--role R] [--target flags]
        case "action":
            args.removeFirst()
            var label: String?
            var role: String?
            var axAction = "AXPress"
            var targetArgs: [String] = []

            while !args.isEmpty {
                switch args[0] {
                case "--action":
                    args.removeFirst()
                    guard !args.isEmpty else { throw VMError.message("Missing --action value") }
                    axAction = args.removeFirst()
                case "--role":
                    args.removeFirst()
                    guard !args.isEmpty else { throw VMError.message("Missing --role value") }
                    role = args.removeFirst()
                case "--front", "--all", "--visible", "--pid", "--app":
                    targetArgs.append(args.removeFirst())
                    if !args.isEmpty && !args[0].hasPrefix("-") && (targetArgs.last == "--pid" || targetArgs.last == "--app") {
                        targetArgs.append(args.removeFirst())
                    }
                default:
                    if label == nil {
                        label = args.removeFirst()
                    } else {
                        label! += " " + args.removeFirst()
                    }
                }
            }

            guard let actionLabel = label else {
                throw VMError.message("Usage: vmctl remote a11y action <label> [--action AXPress] [--role R]")
            }
            let target = targetArgs.isEmpty ? "front" : { var t = targetArgs; return parseTarget(&t) }()

            var body: [String: Any] = ["label": actionLabel, "action": axAction]
            if let r = role { body["role"] = r }
            let _ = try client.postJSON("/api/v1/accessibility/action?target=\(target)", body: body)

            if shouldOutputJSON {
                var result: [String: Any] = [
                    "status": "ok",
                    "label": actionLabel,
                    "action": axAction,
                    "target": target
                ]
                if let r = role { result["role"] = r }
                printJSON(result)
            } else {
                print("OK")
            }

        // Menu: a11y menu <item1> <item2>... [--target flags]
        case "menu":
            args.removeFirst()
            var path: [String] = []
            var targetArgs: [String] = []

            while !args.isEmpty {
                switch args[0] {
                case "--front", "--all", "--visible", "--pid", "--app":
                    targetArgs.append(args.removeFirst())
                    if !args.isEmpty && !args[0].hasPrefix("-") && (targetArgs.last == "--pid" || targetArgs.last == "--app") {
                        targetArgs.append(args.removeFirst())
                    }
                default:
                    path.append(args.removeFirst())
                }
            }

            guard !path.isEmpty else {
                throw VMError.message("Usage: vmctl remote a11y menu <item1> <item2>...")
            }
            let target = targetArgs.isEmpty ? "front" : { var t = targetArgs; return parseTarget(&t) }()

            let _ = try client.postJSON("/api/v1/accessibility/menu?target=\(target)", body: [
                "path": path
            ])

            if shouldOutputJSON {
                printJSON([
                    "status": "ok",
                    "action": "menu",
                    "path": path,
                    "target": target
                ])
            } else {
                print("OK")
            }

        // Type into field: a11y type <value> [--label L] [--role R] [--target flags]
        case "type":
            args.removeFirst()
            guard !args.isEmpty else {
                throw VMError.message("Usage: vmctl remote a11y type <value> [--label L] [--role R]")
            }
            var value: String?
            var label: String?
            var role: String?
            var targetArgs: [String] = []

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
                case "--front", "--all", "--visible", "--pid", "--app":
                    targetArgs.append(args.removeFirst())
                    if !args.isEmpty && !args[0].hasPrefix("-") && (targetArgs.last == "--pid" || targetArgs.last == "--app") {
                        targetArgs.append(args.removeFirst())
                    }
                default:
                    if value == nil {
                        value = args.removeFirst()
                    } else {
                        value! += " " + args.removeFirst()
                    }
                }
            }
            guard let val = value else {
                throw VMError.message("Missing value for a11y type")
            }
            let target = targetArgs.isEmpty ? "front" : { var t = targetArgs; return parseTarget(&t) }()

            var body: [String: Any] = ["value": val]
            if let l = label { body["label"] = l }
            if let r = role { body["role"] = r }
            let _ = try client.postJSON("/api/v1/accessibility/type?target=\(target)", body: body)

            if shouldOutputJSON {
                var result: [String: Any] = [
                    "status": "ok",
                    "action": "type",
                    "value": val,
                    "target": target
                ]
                if let l = label { result["label"] = l }
                if let r = role { result["role"] = r }
                printJSON(result)
            } else {
                print("OK")
            }

        default:
            throw VMError.message("""
                Unknown a11y subcommand '\(action)'.
                Use: click, action, menu, type, focused, elements, --front, --all, --visible, --pid, --app
                """)
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
  screenshot [-o file] [--elements] [--scale N] [--format png|jpeg]
  pointer leftclick [--element N] [X Y]
  pointer rightclick [--element N] [X Y]
  pointer middleclick [--element N] [X Y]
  pointer doubleclick [--element N] [X Y]
  pointer drag X1 Y1 -- X2 Y2
  pointer scroll X Y --dy N [--dx N]
  input type <text...>
  input key [--meta] [--shift] [--ctrl] [--alt] <key>
  launch <bundleId>
  activate <bundleId>
  a11y [--front|--all|--visible|--pid N|--app B] [--depth N]
  a11y focused [--front|--app B]
  a11y elements
  a11y click <label> [--role R] [--app B]
  a11y action <label> [--action AXPress] [--role R]
  a11y menu <item1> <item2>... [--app B]
  a11y type <value> [--label L] [--role R]
  exec <command> [args...]
  clipboard get
  clipboard set <text>
  apps
  interactive                                Start interactive REPL

Target flags (for a11y commands):
  --front       Frontmost app (default)
  --all         All running apps
  --visible     All visible apps
  --pid N       Specific process ID
  --app B       Specific bundle ID (e.g., com.apple.Safari)

Examples:
  vmctl remote --name MyVM health
  vmctl remote --name MyVM screenshot --elements -o /tmp/screen.png
  vmctl remote --name MyVM pointer leftclick --element 5
  vmctl remote --name MyVM pointer doubleclick --element 5
  vmctl remote --name MyVM pointer leftclick 100 200
  vmctl remote --name MyVM input type "hello world"
  vmctl remote --name MyVM input key --meta l
  vmctl remote --name MyVM launch com.apple.Safari
  vmctl remote --name MyVM a11y --front --depth 3
  vmctl remote --name MyVM a11y --app com.apple.Safari --depth 5
  vmctl remote --name MyVM a11y focused
  vmctl remote --name MyVM a11y elements
  vmctl remote --name MyVM a11y click "OK"
  vmctl remote --name MyVM a11y click "Save" --role AXButton
  vmctl remote --name MyVM a11y action "Volume" --action AXIncrement
  vmctl remote --name MyVM a11y menu File "New Window"
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

    /// Format accessibility tree as human-readable text with indentation
    private static func formatA11yTree(_ node: Any, indent: String = "", isLast: Bool = true, prefix: String = "") -> String {
        guard let dict = node as? [String: Any] else { return "" }

        var output = ""
        let connector = isLast ? "└─" : "├─"
        let childPrefix = isLast ? "   " : "│  "

        // Extract key attributes
        let role = dict["role"] as? String ?? "?"
        let label = dict["label"] as? String ?? dict["title"] as? String
        let value = dict["value"] as? String
        let enabled = dict["enabled"] as? Bool
        let focused = dict["focused"] as? Bool

        // Build node line
        var nodeLine = "\(prefix)\(connector) \(role)"
        if let l = label, !l.isEmpty {
            nodeLine += " \"\(l)\""
        }
        if let v = value, !v.isEmpty {
            nodeLine += " = \"\(v)\""
        }
        if let e = enabled, !e {
            nodeLine += " (disabled)"
        }
        if let f = focused, f {
            nodeLine += " (focused)"
        }

        output += nodeLine + "\n"

        // Process children
        if let children = dict["children"] as? [[String: Any]] {
            for (index, child) in children.enumerated() {
                let isLastChild = (index == children.count - 1)
                output += formatA11yTree(child, indent: indent, isLast: isLastChild, prefix: prefix + childPrefix)
            }
        }

        return output
    }

    /// Format a single accessibility element (non-tree) as human-readable text
    private static func formatA11yElement(_ elem: [String: Any]) -> String {
        var lines: [String] = []

        if let role = elem["role"] as? String {
            lines.append("  Role: \(role)")
        }
        if let label = elem["label"] as? String ?? elem["title"] as? String, !label.isEmpty {
            lines.append("  Label: \"\(label)\"")
        }
        if let value = elem["value"] as? String, !value.isEmpty {
            lines.append("  Value: \"\(value)\"")
        }
        if let enabled = elem["enabled"] as? Bool {
            lines.append("  Enabled: \(enabled ? "Yes" : "No")")
        }
        if let focused = elem["focused"] as? Bool, focused {
            lines.append("  Focused: Yes")
        }
        if let frame = elem["frame"] as? [String: Any],
           let x = frame["x"] as? Int, let y = frame["y"] as? Int,
           let w = frame["w"] as? Int, let h = frame["h"] as? Int {
            lines.append("  Frame: (\(x), \(y), \(w)×\(h))")
        }

        return lines.joined(separator: "\n")
    }
}
