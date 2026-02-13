import Foundation
import CEditLine
import GhostVMKit

/// Interactive REPL for `vmctl remote interactive`.
/// Uses libedit (CEditLine) for readline/history support.
enum InteractiveREPL {

    static func run(client: UnixSocketClient) {
        print("GhostVM interactive shell. Type 'help' for commands, 'quit' to exit.")

        while true {
            guard let line = readline("ghost> ") else {
                // EOF (Ctrl-D)
                print("")
                break
            }

            let input = String(cString: line)
            free(line)

            let trimmed = input.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            // Add to history
            add_history(trimmed)

            // Tokenize
            let tokens = tokenize(trimmed)
            guard !tokens.isEmpty else { continue }

            let command = tokens[0].lowercased()
            let args = Array(tokens.dropFirst())

            // Handle quit/exit
            if command == "quit" || command == "exit" || command == "q" {
                break
            }

            do {
                try dispatch(client: client, command: command, arguments: args)
            } catch {
                if let vmError = error as? VMError {
                    print("Error: \(vmError.description)")
                } else {
                    print("Error: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Dispatch

    private static func dispatch(client: UnixSocketClient, command: String, arguments: [String]) throws {
        switch command {
        // Shorthand mappings
        case "click", "leftclick":
            // click N → pointer leftclick --element N
            // click X Y → pointer leftclick X Y
            if let first = arguments.first, let id = Int(first), arguments.count == 1 {
                try RemoteCommand.dispatchSubcommand(client: client, subcommand: "pointer", arguments: ["leftclick", "--element", first])
            } else {
                try RemoteCommand.dispatchSubcommand(client: client, subcommand: "pointer", arguments: ["leftclick"] + arguments)
            }

        case "dclick", "doubleclick":
            if let first = arguments.first, let _ = Int(first), arguments.count == 1 {
                try RemoteCommand.dispatchSubcommand(client: client, subcommand: "pointer", arguments: ["doubleclick", "--element", first])
            } else {
                try RemoteCommand.dispatchSubcommand(client: client, subcommand: "pointer", arguments: ["doubleclick"] + arguments)
            }

        case "rclick", "rightclick":
            if let first = arguments.first, let _ = Int(first), arguments.count == 1 {
                try RemoteCommand.dispatchSubcommand(client: client, subcommand: "pointer", arguments: ["rightclick", "--element", first])
            } else {
                try RemoteCommand.dispatchSubcommand(client: client, subcommand: "pointer", arguments: ["rightclick"] + arguments)
            }

        case "mclick", "middleclick":
            if let first = arguments.first, let _ = Int(first), arguments.count == 1 {
                try RemoteCommand.dispatchSubcommand(client: client, subcommand: "pointer", arguments: ["middleclick", "--element", first])
            } else {
                try RemoteCommand.dispatchSubcommand(client: client, subcommand: "pointer", arguments: ["middleclick"] + arguments)
            }

        case "type":
            try RemoteCommand.dispatchSubcommand(client: client, subcommand: "input", arguments: ["type"] + arguments)

        case "key":
            try RemoteCommand.dispatchSubcommand(client: client, subcommand: "input", arguments: ["key"] + arguments)

        case "drag":
            try RemoteCommand.dispatchSubcommand(client: client, subcommand: "pointer", arguments: ["drag"] + arguments)

        case "scroll":
            try RemoteCommand.dispatchSubcommand(client: client, subcommand: "pointer", arguments: ["scroll"] + arguments)

        case "help":
            showREPLHelp()

        // Pass through to RemoteCommand
        default:
            try RemoteCommand.dispatchSubcommand(client: client, subcommand: command, arguments: arguments)
        }
    }

    // MARK: - Tokenizer

    /// Split input into tokens, respecting quoted strings.
    private static func tokenize(_ input: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuote: Character?

        for ch in input {
            if let q = inQuote {
                if ch == q {
                    inQuote = nil
                } else {
                    current.append(ch)
                }
            } else if ch == "\"" || ch == "'" {
                inQuote = ch
            } else if ch == " " || ch == "\t" {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }

    // MARK: - Help

    private static func showREPLHelp() {
        let help = """
Interactive commands (shortcuts):
  screenshot [--elements] [-o file]    Capture screenshot
  click N                              Left-click element by ID
  click X Y                            Left-click at coordinates
  dclick N                             Double-click element
  rclick N                             Right-click element
  mclick N                             Middle-click element
  type <text>                          Type text
  key [--meta] [--shift] <key>         Press key combo
  drag X1 Y1 -- X2 Y2                 Drag between points
  scroll X Y --dy N                    Scroll at position
  launch <bundleId>                    Launch app
  activate <bundleId>                  Activate app
  a11y [--front|--all|--app B] [--depth N]   Accessibility tree
  a11y focused                         Show focused element
  a11y elements                        List interactive elements
  a11y click <label> [--role R]        Click by a11y label
  a11y action <label> --action AXFoo   Perform any AX action
  a11y menu <item1> <item2>            Trigger menu item
  a11y type <value> [--label L]        Set field value
  exec <command> [args...]             Run command in guest
  clipboard get|set                    Guest clipboard
  apps                                 List running apps
  health                               Check connection
  help                                 Show this help
  quit                                 Exit REPL

Note: Interactive mode is not compatible with --json flag.
      For JSON output, use individual commands directly.
"""
        print(help)
    }
}
