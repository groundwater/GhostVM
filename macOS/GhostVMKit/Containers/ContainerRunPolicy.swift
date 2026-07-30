import Foundation

/// A container run request that passed validation.
public struct ValidatedContainerRun: Equatable, Sendable {
    public let image: String
    public let command: [String]

    public init(image: String, command: [String]) {
        self.image = image
        self.command = command
    }

    /// Arguments for `/usr/local/bin/container` (invoked directly, never via a shell).
    ///
    /// `container run` parses post-image arguments with captureForPassthrough, so
    /// command elements are passed to the container verbatim (leading '-' is safe).
    public func containerArguments(vmHash: String, uniqueSuffix: String) -> [String] {
        let name = ContainerRunPolicy.containerName(vmHash: vmHash, uniqueSuffix: uniqueSuffix)
        return ["run", "--rm", "--name", name, "--cpus", "2", "--memory", "1G", image] + command
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

    public static func validate(_ request: ContainerRunRequest) throws -> ValidatedContainerRun {
        guard request.version == ContainerBridgeConstants.protocolVersion else {
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

        return ValidatedContainerRun(image: image, command: request.command)
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
}
