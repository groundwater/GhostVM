import Foundation

/// A container run request that passed validation.
public struct ValidatedContainerRun: Equatable, Sendable {
    public let image: String
    public let command: [String]
    public let attachStdin: Bool
    public let allocateTTY: Bool
    public let terminalColumns: UInt16
    public let terminalRows: UInt16
    public let protocolVersion: Int
    public let volumes: [ContainerRunVolume]
    public let environment: [String]
    public let workingDirectory: String?
    public let user: String?
    public let cpus: Int
    public let memoryBytes: UInt64

    public init(
        image: String,
        command: [String],
        attachStdin: Bool = false,
        allocateTTY: Bool = false,
        terminalColumns: UInt16 = 80,
        terminalRows: UInt16 = 24,
        protocolVersion: Int = ContainerBridgeConstants.protocolVersion,
        volumes: [ContainerRunVolume] = [],
        environment: [String] = [],
        workingDirectory: String? = nil,
        user: String? = nil,
        cpus: Int = ContainerRunPolicy.defaultCPUs,
        memoryBytes: UInt64 = ContainerRunPolicy.defaultMemoryBytes
    ) {
        self.image = image
        self.command = command
        self.attachStdin = attachStdin
        self.allocateTTY = allocateTTY
        self.terminalColumns = terminalColumns
        self.terminalRows = terminalRows
        self.protocolVersion = protocolVersion
        self.volumes = volumes
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.user = user
        self.cpus = cpus
        self.memoryBytes = memoryBytes
    }

    /// Arguments for the helper-scoped Containerization runtime service.
    public func containerArguments(vmHash: String, uniqueSuffix: String) -> [String] {
        let name = ContainerRunPolicy.containerName(vmHash: vmHash, uniqueSuffix: uniqueSuffix)
        var terminalArguments: [String] = []
        if attachStdin { terminalArguments.append("-i") }
        if allocateTTY {
            terminalArguments += ["-t", "--tty-size", String(terminalColumns), String(terminalRows)]
        }
        var arguments = ["run"] + terminalArguments
        for assignment in environment {
            arguments += ["--env", assignment]
        }
        if let workingDirectory { arguments += ["--workdir", workingDirectory] }
        if let user { arguments += ["--user", user] }
        arguments += ["--cpus", String(cpus), "--memory-bytes", String(memoryBytes)]
        return arguments + ["--id", name, "--image", image, "--"] + command
    }
}

public enum ContainerPolicyError: Error, LocalizedError, Equatable {
    case unsupportedVersion(found: Int)
    case unsupportedOperation(found: String)
    case emptyImage
    case imageTooLong(max: Int)
    case imageStartsWithDash
    case imageContainsNUL
    case imageContainsWhitespaceOrControl
    case tooManyCommandArguments(max: Int)
    case commandArgumentTooLong(max: Int)
    case commandArgumentContainsNUL
    case tooManyVolumes(max: Int)
    case invalidVolumeGuestPath
    case invalidVolumeDestination
    case volumePathTooLong(max: Int)
    case duplicateVolumeDestination(String)
    case ttyRequiresProtocolVersion2
    case invalidTerminalSize
    case runOptionsRequireProtocolVersion4
    case tooManyEnvironmentVariables(max: Int)
    case invalidEnvironment
    case environmentAssignmentTooLong(max: Int)
    case invalidWorkingDirectory
    case workingDirectoryTooLong(max: Int)
    case invalidUser
    case userTooLong(max: Int)
    case invalidCPUs(min: Int, max: Int)
    case invalidMemory(min: UInt64, max: UInt64)

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let found):
            return "Unsupported protocol version \(found); this host supports version \(ContainerBridgeConstants.protocolVersion)."
        case .unsupportedOperation(let found):
            return "Unsupported operation '\(found)'; the only supported operation is 'run'."
        case .emptyImage:
            return "Image must not be empty."
        case .imageTooLong(let max):
            return "Image exceeds the \(max)-byte limit."
        case .imageStartsWithDash:
            return "Image must not start with '-' (flags are not accepted)."
        case .imageContainsNUL:
            return "Image must not contain NUL bytes."
        case .imageContainsWhitespaceOrControl:
            return "Image must not contain whitespace or control characters."
        case .tooManyCommandArguments(let max):
            return "Command has too many arguments (max \(max))."
        case .commandArgumentTooLong(let max):
            return "Command argument exceeds the \(max)-byte limit."
        case .commandArgumentContainsNUL:
            return "Command arguments must not contain NUL bytes."
        case .tooManyVolumes(let max):
            return "Request has too many volumes (max \(max))."
        case .invalidVolumeGuestPath:
            return "Volume guest paths must be absolute and contain no NUL bytes."
        case .invalidVolumeDestination:
            return "Volume destinations must be absolute, must not be '/', and must contain no dot components or NUL bytes."
        case .volumePathTooLong(let max):
            return "Volume paths must not exceed \(max) bytes."
        case .duplicateVolumeDestination(let path):
            return "Duplicate volume destination '\(path)'."
        case .ttyRequiresProtocolVersion2:
            return "TTY mode requires container bridge protocol version 2."
        case .invalidTerminalSize:
            return "Terminal columns and rows must both be greater than zero."
        case .runOptionsRequireProtocolVersion4:
            return "Environment, workdir, user, CPU, and memory options require container bridge protocol version 4."
        case .tooManyEnvironmentVariables(let max):
            return "Request has too many environment variables (max \(max))."
        case .invalidEnvironment:
            return "Environment entries must use NAME=VALUE with a valid POSIX name and no NUL bytes."
        case .environmentAssignmentTooLong(let max):
            return "Environment assignment exceeds the \(max)-byte limit."
        case .invalidWorkingDirectory:
            return "Working directory must be an absolute path with no NUL bytes."
        case .workingDirectoryTooLong(let max):
            return "Working directory exceeds the \(max)-byte limit."
        case .invalidUser:
            return "User must be NAME, UID, NAME:GID, or UID:GID with no whitespace or NUL bytes."
        case .userTooLong(let max):
            return "User exceeds the \(max)-byte limit."
        case .invalidCPUs(let min, let max):
            return "CPU count must be between \(min) and \(max)."
        case .invalidMemory(let min, let max):
            return "Memory must be between \(min) and \(max) bytes."
        }
    }
}

/// Pure validation for guest container run requests.
public enum ContainerRunPolicy {
    /// Maximum image reference length in UTF-8 bytes.
    public static let maxImageLength = 256
    /// Maximum number of command arguments.
    public static let maxCommandCount = 64
    /// Maximum length of one command argument in UTF-8 bytes.
    public static let maxCommandArgumentLength = 4096
    /// Apple's container CLI rejects names longer than 63 characters.
    public static let maxContainerNameLength = 63
    public static let maxVolumeCount = 32
    public static let maxVolumePathLength = 4096
    public static let maxEnvironmentCount = 256
    public static let maxEnvironmentAssignmentLength = 32 * 1024
    public static let maxWorkingDirectoryLength = 4096
    public static let maxUserLength = 256
    public static let minimumCPUs = 1
    public static let maximumCPUs = 64
    public static let defaultCPUs = 2
    public static let minimumMemoryBytes: UInt64 = 128 * 1024 * 1024
    public static let maximumMemoryBytes: UInt64 = 1024 * 1024 * 1024 * 1024
    public static let defaultMemoryBytes: UInt64 = 1024 * 1024 * 1024

    public static func validate(_ request: ContainerRunRequest) throws -> ValidatedContainerRun {
        guard (ContainerBridgeConstants.minimumProtocolVersion...ContainerBridgeConstants.protocolVersion).contains(request.version) else {
            throw ContainerPolicyError.unsupportedVersion(found: request.version)
        }
        guard request.operation == "run" else {
            throw ContainerPolicyError.unsupportedOperation(found: request.operation)
        }

        let image = request.image
        guard !image.isEmpty else { throw ContainerPolicyError.emptyImage }
        guard image.utf8.count <= maxImageLength else { throw ContainerPolicyError.imageTooLong(max: maxImageLength) }
        guard !image.hasPrefix("-") else { throw ContainerPolicyError.imageStartsWithDash }
        guard !image.contains("\0") else { throw ContainerPolicyError.imageContainsNUL }
        // No legitimate image reference contains whitespace or control
        // characters; rejecting them also keeps log-injection out of NSLog.
        guard !image.unicodeScalars.contains(where: isWhitespaceOrControl) else {
            throw ContainerPolicyError.imageContainsWhitespaceOrControl
        }

        guard request.command.count <= maxCommandCount else {
            throw ContainerPolicyError.tooManyCommandArguments(max: maxCommandCount)
        }
        for argument in request.command {
            guard argument.utf8.count <= maxCommandArgumentLength else {
                throw ContainerPolicyError.commandArgumentTooLong(max: maxCommandArgumentLength)
            }
            guard !argument.contains("\0") else { throw ContainerPolicyError.commandArgumentContainsNUL }
        }

        let volumes = request.volumes ?? []
        guard volumes.count <= maxVolumeCount else {
            throw ContainerPolicyError.tooManyVolumes(max: maxVolumeCount)
        }
        var destinations = Set<String>()
        for volume in volumes {
            guard volume.guestPath.hasPrefix("/"), !volume.guestPath.contains("\0") else {
                throw ContainerPolicyError.invalidVolumeGuestPath
            }
            let destinationParts = volume.destination.split(separator: "/", omittingEmptySubsequences: true)
            guard volume.destination.hasPrefix("/"),
                  volume.destination != "/",
                  !volume.destination.contains("\0"),
                  !destinationParts.contains(where: { $0 == "." || $0 == ".." }) else {
                throw ContainerPolicyError.invalidVolumeDestination
            }
            guard volume.guestPath.utf8.count <= maxVolumePathLength,
                  volume.destination.utf8.count <= maxVolumePathLength else {
                throw ContainerPolicyError.volumePathTooLong(max: maxVolumePathLength)
            }
            guard destinations.insert(volume.destination).inserted else {
                throw ContainerPolicyError.duplicateVolumeDestination(volume.destination)
            }
        }

        let allocateTTY = request.tty == true
        guard !allocateTTY || request.version >= 2 else {
            throw ContainerPolicyError.ttyRequiresProtocolVersion2
        }
        let columns = request.columns ?? 80
        let rows = request.rows ?? 24
        guard !allocateTTY || (columns > 0 && rows > 0) else {
            throw ContainerPolicyError.invalidTerminalSize
        }

        let hasVersion4Options = request.environment != nil || request.workingDirectory != nil || request.user != nil || request.cpus != nil || request.memoryBytes != nil
        guard !hasVersion4Options || request.version >= 4 else {
            throw ContainerPolicyError.runOptionsRequireProtocolVersion4
        }

        let environment = request.environment ?? []
        guard environment.count <= maxEnvironmentCount else {
            throw ContainerPolicyError.tooManyEnvironmentVariables(max: maxEnvironmentCount)
        }
        for assignment in environment {
            guard assignment.utf8.count <= maxEnvironmentAssignmentLength else {
                throw ContainerPolicyError.environmentAssignmentTooLong(max: maxEnvironmentAssignmentLength)
            }
            guard let separator = assignment.firstIndex(of: "="),
                  isEnvironmentName(String(assignment[..<separator])),
                  !assignment.contains("\0") else {
                throw ContainerPolicyError.invalidEnvironment
            }
        }

        if let workingDirectory = request.workingDirectory {
            guard workingDirectory.hasPrefix("/"), !workingDirectory.contains("\0") else {
                throw ContainerPolicyError.invalidWorkingDirectory
            }
            guard workingDirectory.utf8.count <= maxWorkingDirectoryLength else {
                throw ContainerPolicyError.workingDirectoryTooLong(max: maxWorkingDirectoryLength)
            }
        }

        if let user = request.user {
            guard !user.isEmpty, !user.contains("\0"),
                  !user.unicodeScalars.contains(where: isWhitespaceOrControl) else {
                throw ContainerPolicyError.invalidUser
            }
            guard user.utf8.count <= maxUserLength else {
                throw ContainerPolicyError.userTooLong(max: maxUserLength)
            }
            let fields = user.split(separator: ":", omittingEmptySubsequences: false)
            guard fields.count <= 2, fields.allSatisfy({ !$0.isEmpty }) else {
                throw ContainerPolicyError.invalidUser
            }
        }

        let cpus = request.cpus ?? defaultCPUs
        guard (minimumCPUs...maximumCPUs).contains(cpus) else {
            throw ContainerPolicyError.invalidCPUs(min: minimumCPUs, max: maximumCPUs)
        }
        let memoryBytes = request.memoryBytes ?? defaultMemoryBytes
        guard (minimumMemoryBytes...maximumMemoryBytes).contains(memoryBytes) else {
            throw ContainerPolicyError.invalidMemory(min: minimumMemoryBytes, max: maximumMemoryBytes)
        }

        return ValidatedContainerRun(
            image: image,
            command: request.command,
            attachStdin: request.stdin == true,
            allocateTTY: allocateTTY,
            terminalColumns: columns,
            terminalRows: rows,
            protocolVersion: request.version,
            volumes: volumes,
            environment: environment,
            workingDirectory: request.workingDirectory,
            user: request.user,
            cpus: cpus,
            memoryBytes: memoryBytes
        )
    }

    /// Maps a string to a container-name-safe component ([a-z0-9_.-], never empty,
    /// starts with an alphanumeric, max 32 chars).
    public static func sanitizedNameComponent(_ raw: String) -> String {
        var mapped = String()
        mapped.reserveCapacity(raw.count)
        for scalar in raw.lowercased().unicodeScalars {
            switch scalar {
            case "a"..."z", "0"..."9", ".", "_", "-":
                mapped.append(Character(scalar))
            default:
                mapped.append("-")
            }
        }
        let trimmed = mapped.drop(while: { !$0.isLetter && !$0.isNumber })
        let result = trimmed.isEmpty ? "x" : String(trimmed)
        return String(result.prefix(32))
    }

    /// Generated container name, hard-capped at Apple's 63-character limit.
    static func containerName(vmHash: String, uniqueSuffix: String) -> String {
        let raw = "gv-\(sanitizedNameComponent(vmHash))-\(sanitizedNameComponent(uniqueSuffix))"
        var name = String(raw.prefix(maxContainerNameLength))
        // Truncation may leave a trailing separator, which name validators reject.
        while let last = name.last, !last.isLetter, !last.isNumber {
            name.removeLast()
        }
        return name
    }

    private static func isWhitespaceOrControl(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.whitespacesAndNewlines.contains(scalar) || CharacterSet.controlCharacters.contains(scalar)
    }

    private static func isEnvironmentName(_ name: String) -> Bool {
        guard let first = name.utf8.first,
              first == 95 || (65...90).contains(first) || (97...122).contains(first) else {
            return false
        }
        return name.utf8.dropFirst().allSatisfy {
            $0 == 95 || (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
        }
    }
}
