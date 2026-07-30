import Foundation

/// Parse `ghost-container run IMAGE [COMMAND...]` into a validated action.
enum ParsedAction {
    case run(image: String, command: [String])
    case help
    case version
}

/// Errors produced during argument parsing.
enum ParseError: LocalizedError {
    case noArguments
    case unknownSubcommand(String)
    case missingImage
    case invalidImage(String)
    case tooManyCommands(max: Int)
    case invalidCommand(index: Int, reason: String)

    var errorDescription: String? {
        switch self {
        case .noArguments:
            return "no arguments provided"
        case .unknownSubcommand(let sub):
            return "unknown subcommand '\(sub)'. Expected 'run'."
        case .missingImage:
            return "missing IMAGE argument. Usage: ghost-container run IMAGE [COMMAND...]"
        case .invalidImage(let reason):
            return "invalid IMAGE: \(reason)"
        case .tooManyCommands(let max):
            return "too many command arguments: maximum is \(max)"
        case .invalidCommand(let index, let reason):
            return "invalid command argument at index \(index): \(reason)"
        }
    }
}

struct CLIOptions {
    let action: ParsedAction
}

/// Parse raw argv (excluding argv[0]).
///
/// Rules:
/// - No arguments → help.
/// - First token must be a subcommand (`run`, `--help`, `-h`, `help`, `--version`, `-v`).
///   No flags/options before the subcommand are accepted.
/// - `run IMAGE [COMMAND...]` — COMMAND args after IMAGE are opaque (may begin with `-`).
func parseArguments(_ argv: [String]) -> Result<CLIOptions, ParseError> {
    if argv.isEmpty {
        return .success(CLIOptions(action: .help))
    }

    let first = argv[0]

    switch first {
    case "--help", "-h", "help":
        return .success(CLIOptions(action: .help))
    case "--version", "-v":
        return .success(CLIOptions(action: .version))
    case "run":
        break
    default:
        return .failure(.unknownSubcommand(first))
    }

    // Everything after `run`
    let rest = Array(argv.dropFirst())

    guard !rest.isEmpty else {
        return .failure(.missingImage)
    }

    let image = rest[0]
    if let err = validateImage(image) {
        return .failure(err)
    }

    let command = Array(rest.dropFirst())

    if command.count > kMaxCommandArgs {
        return .failure(.tooManyCommands(max: kMaxCommandArgs))
    }
    for (i, arg) in command.enumerated() {
        if let err = validateCommandArg(arg) {
            return .failure(.invalidCommand(index: i, reason: err))
        }
    }

    return .success(CLIOptions(action: .run(image: image, command: command)))
}

/// Maximum number of command arguments accepted locally (matches host cap).
let kMaxCommandArgs: Int = 64

/// Maximum UTF-8 byte length of the image name (matches host cap).
let kMaxImageBytes: Int = 256

/// Maximum UTF-8 byte length of each command argument (matches host cap).
let kMaxCommandArgBytes: Int = 4096

/// Validate an image name: nonempty, no NUL, no leading dash, sensible UTF-8 byte
/// length, no whitespace.
func validateImage(_ image: String) -> ParseError? {
    if image.isEmpty {
        return .invalidImage("image name is empty")
    }
    if image.contains("\0") {
        return .invalidImage("image name contains NUL byte")
    }
    if image.hasPrefix("-") {
        return .invalidImage("image name must not start with '-'")
    }
    // Length is measured in UTF-8 bytes to match the host.
    if image.utf8.count > kMaxImageBytes {
        return .invalidImage("image name exceeds \(kMaxImageBytes) bytes")
    }
    if image.contains(" ") || image.contains("\t") || image.contains("\n") || image.contains("\r") {
        return .invalidImage("image name must not contain whitespace")
    }
    return nil
}

/// Validate a single command argument: no NUL, bounded UTF-8 byte length.
/// Args may begin with `-` (opaque), so only NUL and length are checked.
func validateCommandArg(_ arg: String) -> String? {
    if arg.contains("\0") {
        return "contains NUL byte"
    }
    if arg.utf8.count > kMaxCommandArgBytes {
        return "exceeds \(kMaxCommandArgBytes) bytes"
    }
    return nil
}
