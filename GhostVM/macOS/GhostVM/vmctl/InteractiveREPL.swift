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
Interactive commands:
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
