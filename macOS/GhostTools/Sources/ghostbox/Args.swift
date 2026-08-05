import Foundation

enum ParsedAction {
    case run(GhostboxRunOptions)
    case help
    case version
}

struct GhostboxRunOptions: Equatable {
    let image: String
    let command: [String]
    let volumes: [HostContainerVolume]
    let publishedPorts: [PublishedPort]
    let environment: [String]
    let workingDirectory: String?
    let user: String?
    let cpus: Int?
    let memoryBytes: UInt64?
    let interactive: Bool
    let tty: Bool
}

struct PublishedPort: Equatable {
    let hostAddress: String
    let hostPort: UInt16
    let containerPort: UInt16
}

enum ParseError: LocalizedError, Equatable {
    case unknownSubcommand(String)
    case unknownOption(String)
    case missingOptionValue(String)
    case missingImage
    case invalidImage(String)
    case tooManyCommands(max: Int)
    case invalidCommand(index: Int, reason: String)
    case invalidVolume(String)
    case tooManyVolumes(max: Int)
    case duplicateVolumeDestination(String)
    case invalidPublish(String)
    case duplicatePublishedPort(address: String, port: UInt16)
    case invalidEnvironment(String)
    case environmentNotSet(String)
    case tooManyEnvironmentVariables(max: Int)
    case invalidWorkingDirectory(String)
    case invalidUser(String)
    case invalidCPUs(String)
    case invalidMemory(String)

    var errorDescription: String? {
        switch self {
        case .unknownSubcommand(let sub):
            return "unknown subcommand '\(sub)'. Expected 'run'."
        case .unknownOption(let option):
            return "unknown run option '\(option)'"
        case .missingOptionValue(let option):
            return "option \(option) requires a value"
        case .missingImage:
            return "missing IMAGE argument. Usage: ghostbox run [OPTIONS] IMAGE [COMMAND...]"
        case .invalidImage(let reason):
            return "invalid IMAGE: \(reason)"
        case .tooManyCommands(let max):
            return "too many command arguments: maximum is \(max)"
        case .invalidCommand(let index, let reason):
            return "invalid command argument at index \(index): \(reason)"
        case .invalidVolume(let reason):
            return "invalid volume: \(reason)"
        case .tooManyVolumes(let max):
            return "too many volumes: maximum is \(max)"
        case .duplicateVolumeDestination(let path):
            return "duplicate container volume destination '\(path)'"
        case .invalidPublish(let reason):
            return "invalid published port: \(reason)"
        case .duplicatePublishedPort(let address, let port):
            return "duplicate published port \(address):\(port)"
        case .invalidEnvironment(let reason):
            return "invalid environment variable: \(reason)"
        case .environmentNotSet(let name):
            return "environment variable '\(name)' is not set in the guest"
        case .tooManyEnvironmentVariables(let max):
            return "too many environment variables: maximum is \(max)"
        case .invalidWorkingDirectory(let reason):
            return "invalid working directory: \(reason)"
        case .invalidUser(let reason):
            return "invalid user: \(reason)"
        case .invalidCPUs(let reason):
            return "invalid CPU limit: \(reason)"
        case .invalidMemory(let reason):
            return "invalid memory limit: \(reason)"
        }
    }
}

struct CLIOptions {
    let action: ParsedAction
}

func parseArguments(_ argv: [String]) -> Result<CLIOptions, ParseError> {
    guard let first = argv.first else {
        return .success(CLIOptions(action: .help))
    }
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
    var publishedPorts: [PublishedPort] = []
    var environment: [String] = []
    var workingDirectory: String?
    var user: String?
    var cpus: Int?
    var memoryBytes: UInt64?
    var interactive = false
    var tty = false

    optionLoop: while index < argv.count {
        let token = argv[index]
        switch token {
        case "-i", "--interactive":
            interactive = true
            index += 1
        case "-t", "--tty":
            tty = true
            index += 1
        case "-it", "-ti":
            interactive = true
            tty = true
            index += 1
        case "-v", "--volume":
            guard index + 1 < argv.count else { return .failure(.missingOptionValue(token)) }
            if let error = appendVolume(argv[index + 1], to: &volumes) { return .failure(error) }
            index += 2
        case "-p", "--publish":
            guard index + 1 < argv.count else { return .failure(.missingOptionValue(token)) }
            if let error = appendPublishedPort(argv[index + 1], to: &publishedPorts) { return .failure(error) }
            index += 2
        case "-e", "--env":
            guard index + 1 < argv.count else { return .failure(.missingOptionValue(token)) }
            if let error = appendEnvironment(argv[index + 1], to: &environment) { return .failure(error) }
            index += 2
        case "-w", "--workdir":
            guard index + 1 < argv.count else { return .failure(.missingOptionValue(token)) }
            let value = argv[index + 1]
            if let error = validateWorkingDirectory(value) { return .failure(error) }
            workingDirectory = value
            index += 2
        case "-u", "--user":
            guard index + 1 < argv.count else { return .failure(.missingOptionValue(token)) }
            let value = argv[index + 1]
            if let error = validateUser(value) { return .failure(error) }
            user = value
            index += 2
        case "-c", "--cpus":
            guard index + 1 < argv.count else { return .failure(.missingOptionValue(token)) }
            guard let value = Int(argv[index + 1]), value > 0 else {
                return .failure(.invalidCPUs("expected a positive integer"))
            }
            cpus = value
            index += 2
        case "-m", "--memory":
            guard index + 1 < argv.count else { return .failure(.missingOptionValue(token)) }
            switch parseMemory(argv[index + 1]) {
            case .success(let value): memoryBytes = value
            case .failure(let error): return .failure(error)
            }
            index += 2
        default:
            if token.hasPrefix("--volume=") {
                if let error = appendVolume(String(token.dropFirst("--volume=".count)), to: &volumes) { return .failure(error) }
                index += 1
            } else if token.hasPrefix("--publish=") {
                if let error = appendPublishedPort(String(token.dropFirst("--publish=".count)), to: &publishedPorts) { return .failure(error) }
                index += 1
            } else if token.hasPrefix("--env=") {
                if let error = appendEnvironment(String(token.dropFirst("--env=".count)), to: &environment) { return .failure(error) }
                index += 1
            } else if token.hasPrefix("--workdir=") {
                let value = String(token.dropFirst("--workdir=".count))
                if let error = validateWorkingDirectory(value) { return .failure(error) }
                workingDirectory = value
                index += 1
            } else if token.hasPrefix("--user=") {
                let value = String(token.dropFirst("--user=".count))
                if let error = validateUser(value) { return .failure(error) }
                user = value
                index += 1
            } else if token.hasPrefix("--cpus=") {
                guard let value = Int(token.dropFirst("--cpus=".count)), value > 0 else {
                    return .failure(.invalidCPUs("expected a positive integer"))
                }
                cpus = value
                index += 1
            } else if token.hasPrefix("--memory=") {
                switch parseMemory(String(token.dropFirst("--memory=".count))) {
                case .success(let value): memoryBytes = value
                case .failure(let error): return .failure(error)
                }
                index += 1
            } else if token.hasPrefix("-") {
                return .failure(.unknownOption(token))
            } else {
                break optionLoop
            }
        }
    }

    guard index < argv.count else { return .failure(.missingImage) }
    let image = argv[index]
    if let error = validateImage(image) { return .failure(error) }

    let command = Array(argv.dropFirst(index + 1))
    guard command.count <= kMaxCommandArgs else {
        return .failure(.tooManyCommands(max: kMaxCommandArgs))
    }
    for (commandIndex, argument) in command.enumerated() {
        if let reason = validateCommandArg(argument) {
            return .failure(.invalidCommand(index: commandIndex, reason: reason))
        }
    }

    return .success(CLIOptions(action: .run(GhostboxRunOptions(
        image: image,
        command: command,
        volumes: volumes,
        publishedPorts: publishedPorts,
        environment: environment,
        workingDirectory: workingDirectory,
        user: user,
        cpus: cpus,
        memoryBytes: memoryBytes,
        interactive: interactive,
        tty: tty
    ))))
}

let kMaxCommandArgs = 64
let kMaxImageBytes = 256
let kMaxCommandArgBytes = 4096
let kMaxVolumes = 32
let kMaxVolumePathBytes = 4096
let kMaxEnvironmentVariables = 256

private func appendVolume(_ specification: String, to volumes: inout [HostContainerVolume]) -> ParseError? {
    guard volumes.count < kMaxVolumes else { return .tooManyVolumes(max: kMaxVolumes) }
    switch parseVolume(specification) {
    case .failure(let error):
        return error
    case .success(let volume):
        guard !volumes.contains(where: { $0.destination == volume.destination }) else {
            return .duplicateVolumeDestination(volume.destination)
        }
        volumes.append(volume)
        return nil
    }
}

private func parseVolume(_ specification: String) -> Result<HostContainerVolume, ParseError> {
    let fields = specification.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
    guard fields.count == 2 || fields.count == 3 else {
        return .failure(.invalidVolume("expected GUEST_PATH:CONTAINER_PATH[:ro|rw]"))
    }
    let guestPath = fields[0]
    let destination = fields[1]
    guard guestPath.hasPrefix("/"), !guestPath.contains("\0") else {
        return .failure(.invalidVolume("guest path must be absolute and contain no NUL bytes"))
    }
    let destinationParts = destination.split(separator: "/", omittingEmptySubsequences: true)
    guard destination.hasPrefix("/"), destination != "/", !destination.contains("\0"),
          !destinationParts.contains(where: { $0 == "." || $0 == ".." }) else {
        return .failure(.invalidVolume("container path must be absolute, must not be '/', and must contain no dot components or NUL bytes"))
    }
    guard guestPath.utf8.count <= kMaxVolumePathBytes, destination.utf8.count <= kMaxVolumePathBytes else {
        return .failure(.invalidVolume("paths must not exceed \(kMaxVolumePathBytes) bytes"))
    }
    let mode = fields.count == 3 ? fields[2] : "rw"
    guard mode == "ro" || mode == "rw" else {
        return .failure(.invalidVolume("volume mode must be 'ro' or 'rw'"))
    }
    return .success(HostContainerVolume(guestPath: guestPath, destination: destination, readOnly: mode == "ro"))
}

private func appendPublishedPort(_ specification: String, to ports: inout [PublishedPort]) -> ParseError? {
    switch parsePublishedPort(specification) {
    case .failure(let error):
        return error
    case .success(let port):
        guard !ports.contains(where: { $0.hostAddress == port.hostAddress && $0.hostPort == port.hostPort }) else {
            return .duplicatePublishedPort(address: port.hostAddress, port: port.hostPort)
        }
        ports.append(port)
        return nil
    }
}

func parsePublishedPort(_ specification: String) -> Result<PublishedPort, ParseError> {
    let protocolParts = specification.split(separator: "/", omittingEmptySubsequences: false)
    guard protocolParts.count <= 2 else { return .failure(.invalidPublish("invalid protocol suffix")) }
    if protocolParts.count == 2, protocolParts[1].lowercased() != "tcp" {
        return .failure(.invalidPublish("only TCP is supported"))
    }
    let fields = protocolParts[0].split(separator: ":", omittingEmptySubsequences: false).map(String.init)
    guard fields.count == 2 || fields.count == 3 else {
        return .failure(.invalidPublish("expected [HOST_IP:]HOST_PORT:CONTAINER_PORT[/tcp]"))
    }
    let hostAddress = fields.count == 3 ? fields[0] : "127.0.0.1"
    let hostPortText = fields.count == 3 ? fields[1] : fields[0]
    let containerPortText = fields.count == 3 ? fields[2] : fields[1]
    guard isIPv4Address(hostAddress) else { return .failure(.invalidPublish("host address must be an IPv4 address")) }
    guard let hostPort = UInt16(hostPortText), hostPort > 0 else {
        return .failure(.invalidPublish("host port must be between 1 and 65535"))
    }
    guard let containerPort = UInt16(containerPortText), containerPort > 0 else {
        return .failure(.invalidPublish("container port must be between 1 and 65535"))
    }
    return .success(PublishedPort(hostAddress: hostAddress, hostPort: hostPort, containerPort: containerPort))
}

private func appendEnvironment(_ specification: String, to environment: inout [String]) -> ParseError? {
    guard environment.count < kMaxEnvironmentVariables else {
        return .tooManyEnvironmentVariables(max: kMaxEnvironmentVariables)
    }
    let name: String
    let value: String
    if let separator = specification.firstIndex(of: "=") {
        name = String(specification[..<separator])
        value = String(specification[specification.index(after: separator)...])
    } else {
        name = specification
        guard let inherited = ProcessInfo.processInfo.environment[name] else {
            return .environmentNotSet(name)
        }
        value = inherited
    }
    guard isEnvironmentName(name) else {
        return .invalidEnvironment("name must match [A-Za-z_][A-Za-z0-9_]*")
    }
    guard !value.contains("\0") else { return .invalidEnvironment("value contains a NUL byte") }
    guard name.utf8.count + value.utf8.count + 1 <= 32 * 1024 else {
        return .invalidEnvironment("assignment exceeds 32768 bytes")
    }
    environment.append("\(name)=\(value)")
    return nil
}

private func validateWorkingDirectory(_ path: String) -> ParseError? {
    guard path.hasPrefix("/") else { return .invalidWorkingDirectory("path must be absolute") }
    guard !path.contains("\0") else { return .invalidWorkingDirectory("path contains a NUL byte") }
    guard path.utf8.count <= 4096 else { return .invalidWorkingDirectory("path exceeds 4096 bytes") }
    return nil
}

private func validateUser(_ user: String) -> ParseError? {
    guard !user.isEmpty else { return .invalidUser("value must not be empty") }
    guard !user.contains("\0"), user.utf8.count <= 256 else {
        return .invalidUser("value must contain no NUL bytes and be at most 256 bytes")
    }
    guard !user.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }) else {
        return .invalidUser("value must not contain whitespace or control characters")
    }
    let fields = user.split(separator: ":", omittingEmptySubsequences: false)
    guard fields.count <= 2, fields.allSatisfy({ !$0.isEmpty }) else {
        return .invalidUser("expected NAME, UID, NAME:GID, or UID:GID")
    }
    return nil
}

func parseMemory(_ text: String) -> Result<UInt64, ParseError> {
    let lower = text.lowercased()
    let digits = lower.prefix(while: { $0.isNumber })
    guard !digits.isEmpty, let value = UInt64(digits), value > 0 else {
        return .failure(.invalidMemory("expected a positive size such as 512m or 2g"))
    }
    let suffix = lower.dropFirst(digits.count)
    let multiplier: UInt64
    switch suffix {
    case "", "b": multiplier = 1
    case "k", "kb", "kib": multiplier = 1024
    case "m", "mb", "mib": multiplier = 1024 * 1024
    case "g", "gb", "gib": multiplier = 1024 * 1024 * 1024
    case "t", "tb", "tib": multiplier = 1024 * 1024 * 1024 * 1024
    default: return .failure(.invalidMemory("unsupported size suffix"))
    }
    let result = value.multipliedReportingOverflow(by: multiplier)
    guard !result.overflow else { return .failure(.invalidMemory("size is too large")) }
    return .success(result.partialValue)
}

func validateImage(_ image: String) -> ParseError? {
    if image.isEmpty { return .invalidImage("image name is empty") }
    if image.contains("\0") { return .invalidImage("image name contains NUL byte") }
    if image.hasPrefix("-") { return .invalidImage("image name must not start with '-'") }
    if image.utf8.count > kMaxImageBytes { return .invalidImage("image name exceeds \(kMaxImageBytes) bytes") }
    if image.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }) {
        return .invalidImage("image name must not contain whitespace or control characters")
    }
    return nil
}

func validateCommandArg(_ argument: String) -> String? {
    if argument.contains("\0") { return "contains NUL byte" }
    if argument.utf8.count > kMaxCommandArgBytes { return "exceeds \(kMaxCommandArgBytes) bytes" }
    return nil
}

private func isEnvironmentName(_ name: String) -> Bool {
    guard let first = name.utf8.first, first == 95 || (65...90).contains(first) || (97...122).contains(first) else { return false }
    return name.utf8.dropFirst().allSatisfy { $0 == 95 || (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }
}

private func isIPv4Address(_ address: String) -> Bool {
    let octets = address.split(separator: ".", omittingEmptySubsequences: false)
    return octets.count == 4 && octets.allSatisfy { octet in
        !octet.isEmpty && octet.allSatisfy(\.isNumber) && UInt8(octet) != nil
    }
}
