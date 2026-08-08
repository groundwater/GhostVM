import Foundation

enum ParsedAction {
    case direct(GhostboxDirectInvocation)
    case attach(GhostboxDirectInvocation, GhostboxIOStream)
    case forward(container: String, ports: [PublishedPort])
    case help([String])
    case version
}

enum ParseError: LocalizedError, Equatable {
    case invalidDirect(String)

    var errorDescription: String? {
        switch self {
        case .invalidDirect(let reason):
            return reason
        }
    }
}

struct CLIOptions {
    let action: ParsedAction
}

struct GhostboxQualifiedCommand: Equatable, Sendable {
    let namespace: String
    let resource: String
    let operation: String

    var canonical: String { "\(namespace):\(resource):\(operation)" }

    init?(_ token: String) {
        let components = token.split(separator: ":", omittingEmptySubsequences: false)
        guard components.count == 3 else { return nil }
        switch components[0] {
        case "cn", "containerization": namespace = "cn"
        case "cr", "container": namespace = "cr"
        default: return nil
        }
        let resource = String(components[1])
        let operation = String(components[2])
        guard isValidCommandSegment(resource), isValidCommandSegment(operation) else { return nil }
        self.resource = resource
        self.operation = operation
    }
}

private func isValidCommandSegment(_ value: String) -> Bool {
    guard let first = value.utf8.first, (97...122).contains(first) else { return false }
    return value.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
}

func parseArguments(_ arguments: [String]) -> Result<CLIOptions, ParseError> {
    guard let command = arguments.first else {
        return .success(CLIOptions(action: .help([])))
    }
    switch command {
    case "--help", "-h":
        guard arguments.count == 1 else {
            return .failure(.invalidDirect("\(command) accepts no arguments"))
        }
        return .success(CLIOptions(action: .help([])))
    case "help":
        return .success(CLIOptions(action: .help(Array(arguments.dropFirst()))))
    case "--version", "-v":
        return .success(CLIOptions(action: .version))
    default:
        if ["cn:help", "containerization:help"].contains(command) {
            guard arguments.count == 1 else {
                return .failure(.invalidDirect("\(command) accepts no arguments"))
            }
            return .success(CLIOptions(action: .help(["cn"])))
        }
        if ["cr:help", "container:help"].contains(command) {
            guard arguments.count == 1 else {
                return .failure(.invalidDirect("\(command) accepts no arguments"))
            }
            return .success(CLIOptions(action: .help(["cr"])))
        }
        guard let qualified = GhostboxQualifiedCommand(command) else {
            return .failure(.invalidDirect(
                "unknown qualified command '\(command)'; expected NAMESPACE:RESOURCE:OPERATION"
            ))
        }
        if qualified.operation == "help" {
            guard arguments.count == 1 else {
                return .failure(.invalidDirect("\(command) accepts no arguments"))
            }
            return .success(CLIOptions(action: .help([qualified.namespace, qualified.resource])))
        }
        if let helpIndex = arguments.firstIndex(where: { $0 == "--help" || $0 == "-h" }),
           !arguments[..<helpIndex].contains("--") {
            guard helpIndex == arguments.index(before: arguments.endIndex) else {
                return .failure(.invalidDirect("--help must be the final argument"))
            }
            return .success(CLIOptions(action: .help([qualified.canonical])))
        }
        let legacyArguments = legacyExtensionArguments(qualified, arguments: Array(arguments.dropFirst()))
        if legacyArguments == ["kernel", "default"] {
            return .success(CLIOptions(action: .direct(.init(method: .kernelDefault, parameters: [:]))))
        }
        if legacyArguments == ["kernel", "install-recommended"] {
            return .success(CLIOptions(action: .direct(.init(method: .kernelInstallRecommended, parameters: [:]))))
        }
        if let result = legacyArguments.flatMap(parseResourceCleanupArguments) {
            return result
        }
        if qualified.namespace == "cn", qualified.resource == "mount",
           let legacyArguments, let result = parseGuestMountArguments(legacyArguments) {
            return result
        }
        if qualified.namespace == "cn", qualified.resource == "container", qualified.operation == "forward",
           let legacyArguments {
            return parseContainerForwardArguments(legacyArguments)
        }
        if qualified.namespace == "cn", ["reader-stream", "writer", "terminal"].contains(qualified.resource),
           let legacyArguments {
            return parseIOProxyArguments(legacyArguments)
        }
        return parseDirectArguments(arguments).map { CLIOptions(action: .direct($0)) }
    }
}

private func legacyExtensionArguments(
    _ command: GhostboxQualifiedCommand,
    arguments: [String]
) -> [String]? {
    guard command.namespace == "cn" else { return nil }
    if ["reader-stream", "writer", "terminal"].contains(command.resource) {
        if arguments.first?.hasPrefix("@") == true {
            return [command.resource, arguments[0], command.operation] + arguments.dropFirst()
        }
        return [command.resource, command.operation] + arguments
    }
    if command.operation == "delete" || command.operation == "close" || command.operation == "forward" {
        guard let receiver = arguments.first else { return [command.resource, command.operation] }
        return [command.resource, receiver, command.operation] + arguments.dropFirst()
    }
    return [command.resource, command.operation] + arguments
}

private func parseVolumeArguments(_ arguments: [String]) -> Result<CLIOptions, ParseError> {
    guard arguments.count >= 2 else {
        return .failure(.invalidDirect("volume requires an operation"))
    }
    if arguments[1] == "list" {
        guard arguments.count == 2 else {
            return .failure(.invalidDirect("volume list accepts no arguments"))
        }
        return directVolumeAction(.volumeList, parameters: [:])
    }
    if arguments[1] == "create" {
        guard arguments.count >= 3, isValidReferenceComponent(arguments[2]) else {
            return .failure(.invalidDirect("volume create requires a valid name"))
        }
        var parameters: [String: GhostboxJSONValue] = ["volume": .string(arguments[2])]
        var index = 3
        while index < arguments.count {
            let (name, attached) = splitLongOption(arguments[index])
            guard name == "--size" else {
                return .failure(.invalidDirect("unknown option '\(name)' for volume create"))
            }
            guard parameters["size"] == nil else {
                return .failure(.invalidDirect("option --size may be specified once"))
            }
            let value: String
            if let attached {
                value = attached
            } else {
                guard index + 1 < arguments.count else {
                    return .failure(.invalidDirect("option --size requires a value"))
                }
                index += 1
                value = arguments[index]
            }
            guard let size = UInt64(value) else {
                return .failure(.invalidDirect("--size requires an unsigned integer byte count"))
            }
            parameters["size"] = .unsignedInteger(size)
            index += 1
        }
        return directVolumeAction(.volumeCreate, parameters: parameters)
    }

    guard isValidReference(arguments[1], expectedKind: "volume"), arguments.count >= 3 else {
        return .failure(.invalidDirect("expected volume create, volume list, or an @volume/NAME reference"))
    }
    let reference = arguments[1]
    switch arguments[2] {
    case "inspect":
        guard arguments.count == 3 else {
            return .failure(.invalidDirect("volume inspect accepts no options"))
        }
        return directVolumeAction(.volumeInspect, parameters: ["volume": .string(reference)])
    case "delete":
        guard arguments.count == 3 else {
            return .failure(.invalidDirect("volume delete accepts no options"))
        }
        return directVolumeAction(.volumeDelete, parameters: ["volume": .string(reference)])
    case "mount":
        guard arguments.count >= 4, isValidReferenceComponent(arguments[3]) else {
            return .failure(.invalidDirect("volume mount requires a valid mount name"))
        }
        var parameters: [String: GhostboxJSONValue] = [
            "volume": .string(reference),
            "mount": .string(arguments[3]),
            "readOnly": .boolean(false),
        ]
        var suppliedOptions = Set<String>()
        var index = 4
        while index < arguments.count {
            let (name, attached) = splitLongOption(arguments[index])
            guard name == "--destination" || name == "--read-only" else {
                return .failure(.invalidDirect("unknown option '\(name)' for volume mount"))
            }
            guard suppliedOptions.insert(name).inserted else {
                return .failure(.invalidDirect("option \(name) may be specified once"))
            }
            let parameter = name == "--destination" ? "destination" : "readOnly"
            let value: String
            if let attached {
                value = attached
            } else if name == "--read-only", index + 1 == arguments.count || arguments[index + 1].hasPrefix("--") {
                value = "true"
            } else {
                guard index + 1 < arguments.count else {
                    return .failure(.invalidDirect("option \(name) requires a value"))
                }
                index += 1
                value = arguments[index]
            }
            if name == "--read-only" {
                guard value == "true" || value == "false" else {
                    return .failure(.invalidDirect("--read-only must be true or false"))
                }
                parameters[parameter] = .boolean(value == "true")
            } else {
                parameters[parameter] = .string(value)
            }
            index += 1
        }
        guard case .string(let destination) = parameters["destination"], isValidContainerMountPath(destination) else {
            return .failure(.invalidDirect("--destination must be an absolute non-root container path without dot components"))
        }
        return directVolumeAction(.volumeMount, parameters: parameters)
    default:
        return .failure(.invalidDirect("unknown volume operation '\(arguments[2])'"))
    }
}

private func directVolumeAction(
    _ method: GhostboxDirectMethod,
    parameters: [String: GhostboxJSONValue]
) -> Result<CLIOptions, ParseError> {
    .success(CLIOptions(action: .direct(.init(method: method, parameters: parameters))))
}

private func splitLongOption(_ option: String) -> (String, String?) {
    guard let separator = option.firstIndex(of: "=") else { return (option, nil) }
    return (String(option[..<separator]), String(option[option.index(after: separator)...]))
}

private func parseResourceCleanupArguments(_ arguments: [String]) -> Result<CLIOptions, ParseError>? {
    guard arguments.count >= 3, arguments[1].hasPrefix("@") else { return nil }
    let resource = arguments[0]
    let operation = arguments[2]
    let method: GhostboxDirectMethod
    let referenceKind: String
    let parameter: String
    switch (resource, operation) {
    case ("mount", "delete"):
        method = .mountDelete
        referenceKind = "mount"
        parameter = "mount"
    case ("dns", "delete"):
        method = .dnsDelete
        referenceKind = "dns"
        parameter = "dns"
    case ("process-config", "delete"):
        method = .processConfigDelete
        referenceKind = "process-config"
        parameter = "processConfig"
    case ("network", "delete"):
        method = .networkDelete
        referenceKind = "network"
        parameter = "network"
    case ("manager", "close"):
        method = .managerClose
        referenceKind = "manager"
        parameter = "manager"
    default:
        return nil
    }
    guard arguments.count == 3 else {
        return .failure(.invalidDirect("too many arguments for \(resource) \(operation)"))
    }
    guard isValidReference(arguments[1], expectedKind: referenceKind) else {
        return .failure(.invalidDirect("expected @\(referenceKind)/NAME reference"))
    }
    return .success(CLIOptions(action: .direct(.init(
        method: method,
        parameters: [parameter: .string(arguments[1])]
    ))))
}

private func parseGuestMountArguments(_ arguments: [String]) -> Result<CLIOptions, ParseError>? {
    guard arguments.count >= 2, arguments[1] == "guest-share" else { return nil }
    guard arguments.count >= 3, isValidReferenceComponent(arguments[2]) else {
        return .failure(.invalidDirect("mount guest-share requires a valid mount name"))
    }
    var parameters: [String: GhostboxJSONValue] = [
        "mount": .string(arguments[2]),
        "readOnly": .boolean(false),
        "option": .array([]),
        "runtimeOption": .array([]),
    ]
    var singularOptions = Set<String>()
    var index = 3
    while index < arguments.count {
        let option = arguments[index]
        let name: String
        let attached: String?
        if let separator = option.firstIndex(of: "=") {
            name = String(option[..<separator])
            attached = String(option[option.index(after: separator)...])
        } else {
            name = option
            attached = nil
        }
        let value: String
        if let attached {
            value = attached
        } else {
            guard index + 1 < arguments.count else {
                return .failure(.invalidDirect("option \(name) requires a value"))
            }
            index += 1
            value = arguments[index]
        }
        switch name {
        case "--source":
            guard singularOptions.insert(name).inserted else {
                return .failure(.invalidDirect("option \(name) may be specified once"))
            }
            parameters["source"] = .string(value)
        case "--destination":
            guard singularOptions.insert(name).inserted else {
                return .failure(.invalidDirect("option \(name) may be specified once"))
            }
            parameters["destination"] = .string(value)
        case "--read-only":
            guard singularOptions.insert(name).inserted else {
                return .failure(.invalidDirect("option \(name) may be specified once"))
            }
            guard value == "true" || value == "false" else {
                return .failure(.invalidDirect("--read-only must be true or false"))
            }
            parameters["readOnly"] = .boolean(value == "true")
        case "--cache-ttl":
            guard singularOptions.insert(name).inserted else {
                return .failure(.invalidDirect("option \(name) may be specified once"))
            }
            guard let seconds = UInt64(value), seconds <= 300 else {
                return .failure(.invalidDirect("--cache-ttl must be an integer from 0 through 300"))
            }
            parameters["cacheTTL"] = .unsignedInteger(seconds)
        case "--option", "--runtime-option":
            let parameter = name == "--option" ? "option" : "runtimeOption"
            if case .array(var values) = parameters[parameter] {
                values.append(.string(value))
                parameters[parameter] = .array(values)
            }
        default:
            return .failure(.invalidDirect("unknown option '\(name)' for mount guest-share"))
        }
        index += 1
    }
    guard case .string(let source) = parameters["source"], source.hasPrefix("/"), !source.contains("\0") else {
        return .failure(.invalidDirect("--source must be an absolute guest path"))
    }
    guard case .string(let destination) = parameters["destination"],
          isValidContainerMountPath(destination) else {
        return .failure(.invalidDirect("--destination must be an absolute non-root container path without dot components"))
    }
    return .success(CLIOptions(action: .direct(.init(method: .mountGuestShare, parameters: parameters))))
}

private func parseContainerForwardArguments(_ arguments: [String]) -> Result<CLIOptions, ParseError> {
    guard isValidReference(arguments[1], expectedKind: "container") else {
        return .failure(.invalidDirect("container forward requires an @container/NAME reference"))
    }
    var ports: [PublishedPort] = []
    var index = 3
    while index < arguments.count {
        let option = arguments[index]
        let specification: String
        if option == "-p" || option == "-P" || option == "--publish" {
            guard index + 1 < arguments.count else {
                return .failure(.invalidDirect("option \(option) requires a value"))
            }
            index += 1
            specification = arguments[index]
        } else if option.hasPrefix("--publish=") {
            specification = String(option.dropFirst("--publish=".count))
        } else {
            return .failure(.invalidDirect("container forward accepts repeated -p, -P, or --publish options"))
        }
        do {
            let port = try parsePublishedPort(specification).get()
            guard !ports.contains(where: { $0.hostAddress == port.hostAddress && $0.hostPort == port.hostPort }) else {
                return .failure(.invalidDirect("duplicate published port \(port.hostAddress):\(port.hostPort)"))
            }
            ports.append(port)
        } catch let error {
            return .failure(error)
        }
        index += 1
    }
    guard !ports.isEmpty else {
        return .failure(.invalidDirect("container forward requires at least one -p mapping"))
    }
    return .success(CLIOptions(action: .forward(container: arguments[1], ports: ports)))
}

func isValidContainerMountPath(_ path: String) -> Bool {
    let components = path.split(separator: "/", omittingEmptySubsequences: true)
    return path.hasPrefix("/") && path != "/" && !path.contains("\0")
        && !components.contains(where: { $0 == "." || $0 == ".." })
}

private func parseIOProxyArguments(_ arguments: [String]) -> Result<CLIOptions, ParseError> {
    guard arguments.count >= 2 else {
        return .failure(.invalidDirect("resource '\(arguments[0])' requires an operation"))
    }
    let resource = arguments[0]
    let referenceKind = resource
    let isReference = arguments[1].hasPrefix("@")
    let operationIndex = isReference ? 2 : 1
    guard arguments.indices.contains(operationIndex) else {
        return .failure(.invalidDirect("reference command for '\(resource)' requires an operation"))
    }
    let operation = arguments[operationIndex]

    func invocation(_ method: GhostboxDirectMethod, _ parameters: [String: GhostboxJSONValue]) -> CLIOptions {
        CLIOptions(action: .direct(.init(method: method, parameters: parameters)))
    }

    if !isReference, operation == "create" {
        guard arguments.count >= 3 else {
            return .failure(.invalidDirect("missing required positional name"))
        }
        let name = arguments[2]
        guard isValidReferenceComponent(name) else {
            return .failure(.invalidDirect("name must contain only letters, digits, '.', '_', or '-' and be at most 128 bytes"))
        }
        if resource == "terminal" {
            var width: UInt16 = 80
            var height: UInt16 = 24
            for argument in arguments.dropFirst(3) {
                if argument.hasPrefix("--width="), let value = UInt16(argument.dropFirst("--width=".count)), value > 0 {
                    width = value
                } else if argument.hasPrefix("--height="), let value = UInt16(argument.dropFirst("--height=".count)), value > 0 {
                    height = value
                } else {
                    return .failure(.invalidDirect("terminal create accepts --width=N and --height=N"))
                }
            }
            return .success(invocation(.terminalCreateProxy, [
                "terminal": .string(name), "width": .unsignedInteger(UInt64(width)),
                "height": .unsignedInteger(UInt64(height)),
            ]))
        }
        guard arguments.count == 3 else {
            return .failure(.invalidDirect("too many arguments for \(resource) create"))
        }
        let method: GhostboxDirectMethod = resource == "reader-stream" ? .readerStreamCreateProxy : .writerCreateProxy
        let parameter = resource == "reader-stream" ? "readerStream" : "writer"
        return .success(invocation(method, [parameter: .string(name)]))
    }

    guard isReference, isValidReference(arguments[1], expectedKind: referenceKind) else {
        return .failure(.invalidDirect("expected @\(referenceKind)/NAME reference and one operation"))
    }
    let reference = GhostboxJSONValue.string(arguments[1])
    let parameter = resource == "reader-stream" ? "readerStream" : resource
    switch (resource, operation) {
    case ("reader-stream", "attach"):
        guard arguments.count == 3 else {
            return .failure(.invalidDirect("too many arguments for reader-stream attach"))
        }
        return .success(CLIOptions(action: .attach(.init(
            method: .readerStreamAttachProxy, parameters: [parameter: reference]
        ), .input)))
    case ("reader-stream", "close"):
        guard arguments.count == 3 else {
            return .failure(.invalidDirect("too many arguments for reader-stream close"))
        }
        return .success(invocation(.readerStreamCloseProxy, [parameter: reference]))
    case ("writer", "attach"):
        guard arguments.count == 3 else {
            return .failure(.invalidDirect("too many arguments for writer attach"))
        }
        return .success(CLIOptions(action: .attach(.init(
            method: .writerAttachProxy, parameters: [parameter: reference]
        ), .output)))
    case ("writer", "close"):
        guard arguments.count == 3 else {
            return .failure(.invalidDirect("too many arguments for writer close"))
        }
        return .success(invocation(.writerCloseProxy, [parameter: reference]))
    case ("terminal", "attach"):
        var parameters = [parameter: reference]
        if arguments.count > 3 {
            let target: String
            if arguments.count == 4, arguments[3].hasPrefix("--resize-target=") {
                target = String(arguments[3].dropFirst("--resize-target=".count))
            } else if arguments.count == 5, arguments[3] == "--resize-target" {
                target = arguments[4]
            } else {
                return .failure(.invalidDirect("terminal attach accepts --resize-target @container/NAME or @process/NAME"))
            }
            guard isValidReference(target, expectedKind: "container")
                    || isValidReference(target, expectedKind: "process") else {
                return .failure(.invalidDirect("--resize-target must be an @container/NAME or @process/NAME reference"))
            }
            parameters["resizeTarget"] = .string(target)
        }
        return .success(CLIOptions(action: .attach(.init(
            method: .terminalAttachProxy, parameters: parameters
        ), .terminal)))
    case ("terminal", "wait-attached"):
        guard arguments.count == 3 else {
            return .failure(.invalidDirect("too many arguments for terminal wait-attached"))
        }
        return .success(invocation(.terminalWaitAttachedProxy, [parameter: reference]))
    case ("terminal", "close"):
        guard arguments.count == 3 else {
            return .failure(.invalidDirect("too many arguments for terminal close"))
        }
        return .success(invocation(.terminalCloseProxy, [parameter: reference]))
    default:
        return .failure(.invalidDirect("unsupported reference operation '\(operation)' for resource '\(resource)'"))
    }
}
