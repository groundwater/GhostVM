import Foundation

/// Parse `ghost-container run [-i] [-t] [-v GUEST:CONTAINER:ro] IMAGE [COMMAND...]`.
enum ParsedAction {
    case run(image: String, command: [String], volumes: [HostContainerVolume], interactive: Bool, tty: Bool)
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
    case missingVolume
    case invalidVolume(String)
    case tooManyVolumes(max: Int)
    case duplicateVolumeDestination(String)

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
        case .missingVolume:
            return "missing value for -v/--volume. Expected GUEST_PATH:CONTAINER_PATH:ro"
        case .invalidVolume(let reason):
            return "invalid volume: \(reason)"
        case .tooManyVolumes(let max):
            return "too many volumes: maximum is \(max)"
        case .duplicateVolumeDestination(let path):
            return "duplicate container volume destination '\(path)'"
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
/// - `run [-i] [-t] [-v GUEST:CONTAINER:ro] IMAGE [COMMAND...]` — COMMAND args after IMAGE are opaque.
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

    var index = 1
    var volumes: [HostContainerVolume] = []
    var interactive = false
    var tty = false
    optionLoop: while index < argv.count {
        let token = argv[index]
        switch token {
        case "-i", "--interactive":
            interactive = true
            index += 1
            continue
        case "-t", "--tty":
            tty = true
            index += 1
            continue
        case "-it", "-ti":
            interactive = true
            tty = true
            index += 1
            continue
        default:
            break
        }

        let specification: String
        if token == "-v" || token == "--volume" {
            index += 1
            guard index < argv.count else { return .failure(.missingVolume) }
            specification = argv[index]
        } else if token.hasPrefix("--volume=") {
            specification = String(token.dropFirst("--volume=".count))
        } else {
            break optionLoop
        }

        guard volumes.count < kMaxVolumes else {
            return .failure(.tooManyVolumes(max: kMaxVolumes))
        }
        switch parseVolume(specification) {
        case .success(let volume):
            guard !volumes.contains(where: { $0.destination == volume.destination }) else {
                return .failure(.duplicateVolumeDestination(volume.destination))
            }
            volumes.append(volume)
        case .failure(let error):
            return .failure(error)
        }
        index += 1
    }

    guard index < argv.count else {
        return .failure(.missingImage)
    }

    let image = argv[index]
    if let err = validateImage(image) {
        return .failure(err)
    }

    let command = Array(argv.dropFirst(index + 1))

    if command.count > kMaxCommandArgs {
        return .failure(.tooManyCommands(max: kMaxCommandArgs))
    }
    for (i, arg) in command.enumerated() {
        if let err = validateCommandArg(arg) {
            return .failure(.invalidCommand(index: i, reason: err))
        }
    }

    return .success(CLIOptions(action: .run(
        image: image,
        command: command,
        volumes: volumes,
        interactive: interactive,
        tty: tty
    )))
}

/// Maximum number of command arguments accepted locally (matches host cap).
let kMaxCommandArgs: Int = 64

/// Maximum UTF-8 byte length of the image name (matches host cap).
let kMaxImageBytes: Int = 256

/// Maximum UTF-8 byte length of each command argument (matches host cap).
let kMaxCommandArgBytes: Int = 4096

/// Maximum number of guest directory mounts in one run request.
let kMaxVolumes: Int = 32

private func parseVolume(_ specification: String) -> Result<HostContainerVolume, ParseError> {
    let fields = specification.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
    guard fields.count == 2 || fields.count == 3 else {
        return .failure(.invalidVolume("expected GUEST_PATH:CONTAINER_PATH[:ro]"))
    }
    let guestPath = fields[0]
    let destination = fields[1]
    guard guestPath.hasPrefix("/"), !guestPath.contains("\0") else {
        return .failure(.invalidVolume("guest path must be absolute and contain no NUL bytes"))
    }
    let destinationParts = destination.split(separator: "/", omittingEmptySubsequences: true)
    guard destination.hasPrefix("/"),
          destination != "/",
          !destination.contains("\0"),
          !destinationParts.contains(where: { $0 == "." || $0 == ".." }) else {
        return .failure(.invalidVolume("container path must be absolute, must not be '/', and must contain no dot components or NUL bytes"))
    }
    guard guestPath.utf8.count <= kMaxVolumePathBytes, destination.utf8.count <= kMaxVolumePathBytes else {
        return .failure(.invalidVolume("paths must not exceed \(kMaxVolumePathBytes) bytes"))
    }
    let mode = fields.count == 3 ? fields[2] : "rw"
    guard mode == "ro" else {
        return .failure(.invalidVolume("guest directory mounts are currently read-only; append ':ro'"))
    }
    return .success(HostContainerVolume(guestPath: guestPath, destination: destination, readOnly: true))
}

let kMaxVolumePathBytes: Int = 4096

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
