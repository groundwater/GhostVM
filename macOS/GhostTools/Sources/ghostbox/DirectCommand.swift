import Foundation

func parseDirectArguments(_ argv: [String]) -> Result<GhostboxDirectInvocation, ParseError> {
    guard !argv.isEmpty else {
        return .failure(.invalidDirect("direct invocation requires at least one argument"))
    }
    guard argv.count <= kMaxDirectArgumentCount else {
        return .failure(.invalidDirect("direct invocation exceeds the \(kMaxDirectArgumentCount)-argument limit"))
    }
    var totalBytes = 0
    for argument in argv {
        guard !argument.contains("\0") else {
            return .failure(.invalidDirect("direct arguments must not contain NUL"))
        }
        let byteCount = argument.utf8.count
        guard byteCount <= kMaxDirectArgumentBytes else {
            return .failure(.invalidDirect("a direct argument exceeds the \(kMaxDirectArgumentBytes)-byte limit"))
        }
        totalBytes += byteCount
        guard totalBytes <= kMaxDirectArgumentsBytes else {
            return .failure(.invalidDirect("direct arguments exceed the \(kMaxDirectArgumentsBytes)-byte limit"))
        }
    }

    do {
        let (signature, argumentStart) = try selectSignature(argv)
        let parameters = try parseParameters(argv, startingAt: argumentStart, signature: signature)
        return .success(GhostboxDirectInvocation(
            method: GhostboxDirectMethod(rawValue: signature.methodID),
            parameters: parameters
        ))
    } catch let error as ParseError {
        return .failure(error)
    } catch {
        return .failure(.invalidDirect(String(describing: error)))
    }
}

private func selectSignature(_ argv: [String]) throws -> (GhostboxCommandSignature, Int) {
    let command = argv[0]
    guard let signature = ghostboxCommandCatalog.first(where: {
        $0.commandID == command || $0.aliases.contains(command)
    }) else {
        throw ParseError.invalidDirect(
            "unknown qualified command '\(command)'; expected NAMESPACE:RESOURCE:OPERATION"
        )
    }
    return (signature, 1)
}

private func parseParameters(
    _ argv: [String],
    startingAt argumentStart: Int,
    signature: GhostboxCommandSignature
) throws -> [String: GhostboxJSONValue] {
    var parameters = signature.implicitDefaults
    for option in signature.options {
        if let defaultValue = option.defaultValue {
            parameters[option.parameterName] = defaultValue
        }
    }

    var positionals = signature.positionals
    if signature.shape == .reference {
        guard let receiver = positionals.first else {
            throw ParseError.invalidDirect("catalog entry '\(signature.methodID)' has no receiver")
        }
        parameters[receiver.parameterName] = try parseCatalogValue(
            argv[argumentStart],
            type: receiver.type,
            label: receiver.name
        )
        positionals.removeFirst()
    }

    var positionalValues: [String] = []
    var seenOptions: [String: Int] = [:]
    var acceptsOptions = true
    var index = argumentStart + (signature.shape == .reference ? 1 : 0)
    while index < argv.count {
        let argument = argv[index]
        if acceptsOptions && argument == "--" {
            acceptsOptions = false
            index += 1
            continue
        }
        if acceptsOptions && argument.hasPrefix("--") {
            let (name, attachedValue) = splitOption(argument)
            guard let option = signature.options.first(where: { $0.names.contains(name) }) else {
                throw ParseError.invalidDirect("unknown option '\(name)' for \(signature.resource) \(signature.operation)")
            }
            let count = seenOptions[option.parameterName, default: 0]
            guard option.repeatable || count == 0 else {
                throw ParseError.invalidDirect("option \(name) may be specified once")
            }

            let rawValue: String
            if let attachedValue {
                rawValue = attachedValue
            } else if option.type == "bool",
                      index + 1 == argv.count || argv[index + 1].hasPrefix("--") {
                rawValue = "true"
            } else {
                guard index + 1 < argv.count, !argv[index + 1].hasPrefix("--") else {
                    throw ParseError.invalidDirect("option \(name) requires a value")
                }
                index += 1
                rawValue = argv[index]
            }
            let value = try parseCatalogValue(rawValue, type: option.type, label: name)
            if option.repeatable {
                appendRepeated(value, for: option.parameterName, to: &parameters)
            } else {
                parameters[option.parameterName] = value
            }
            seenOptions[option.parameterName] = count + 1
            index += 1
            continue
        }
        positionalValues.append(argument)
        index += 1
    }

    for option in signature.options where option.required {
        guard seenOptions[option.parameterName, default: 0] > 0 else {
            throw ParseError.invalidDirect("missing required option \(option.names[0])")
        }
    }

    var positionalIndex = 0
    for positional in positionals {
        if positional.repeatable {
            let remaining = positionalValues[positionalIndex...]
            guard !positional.required || !remaining.isEmpty else {
                throw ParseError.invalidDirect("missing required positional \(positional.name)")
            }
            parameters[positional.parameterName] = .array(try remaining.map {
                try parseCatalogValue($0, type: positional.type, label: positional.name)
            })
            positionalIndex = positionalValues.count
            continue
        }
        guard positionalIndex < positionalValues.count else {
            if positional.required {
                throw ParseError.invalidDirect("missing required positional \(positional.name)")
            }
            continue
        }
        parameters[positional.parameterName] = try parseCatalogValue(
            positionalValues[positionalIndex],
            type: positional.type,
            label: positional.name
        )
        positionalIndex += 1
    }
    guard positionalIndex == positionalValues.count else {
        throw ParseError.invalidDirect("too many positional arguments for \(signature.resource) \(signature.operation)")
    }
    return parameters
}

private func parseCatalogValue(_ rawValue: String, type: String, label: String) throws -> GhostboxJSONValue {
    let nullable = type.hasSuffix("?")
    let baseType = nullable ? String(type.dropLast()) : type
    if nullable && rawValue == "null" {
        return .null
    }

    if let separator = baseType.firstIndex(of: "=") {
        let leftType = String(baseType[..<separator])
        let rightType = String(baseType[baseType.index(after: separator)...])
        guard let valueSeparator = rawValue.firstIndex(of: "="), valueSeparator != rawValue.startIndex else {
            throw ParseError.invalidDirect("\(label) must be a \(leftType)=\(rightType) assignment")
        }
        let left = String(rawValue[..<valueSeparator])
        let right = String(rawValue[rawValue.index(after: valueSeparator)...])
        _ = try parseCatalogValue(left, type: leftType, label: label)
        _ = try parseCatalogValue(right, type: rightType, label: label)
        return .string(rawValue)
    }

    if baseType.hasPrefix("reference:") {
        let kind = String(baseType.dropFirst("reference:".count))
        guard isValidReference(rawValue, expectedKind: kind) else {
            throw ParseError.invalidDirect("\(label) must be an @\(kind)/NAME reference")
        }
        return .string(rawValue)
    }
    if baseType == "name" {
        guard isValidReferenceComponent(rawValue) else {
            throw ParseError.invalidDirect("\(label) must contain only letters, digits, '.', '_', or '-' and be at most 128 bytes")
        }
        return .string(rawValue)
    }
    if baseType == "container-path" {
        guard isValidContainerMountPath(rawValue) else {
            throw ParseError.invalidDirect(
                "\(label) must be an absolute non-root container path without dot components"
            )
        }
        return .string(rawValue)
    }
    if baseType == "bool" {
        switch rawValue {
        case "true": return .boolean(true)
        case "false": return .boolean(false)
        default: throw ParseError.invalidDirect("\(label) must be true or false")
        }
    }
    if baseType == "int" || baseType == "int64" {
        guard let value = Int64(rawValue) else {
            throw ParseError.invalidDirect("\(label) is not a valid \(baseType)")
        }
        return .integer(value)
    }
    if baseType == "int32" {
        guard let value = Int32(rawValue) else {
            throw ParseError.invalidDirect("\(label) is not a valid int32")
        }
        return .integer(Int64(value))
    }
    if baseType == "uint16" {
        guard let value = UInt16(rawValue) else {
            throw ParseError.invalidDirect("\(label) is not a valid uint16")
        }
        return .unsignedInteger(UInt64(value))
    }
    if baseType == "uint32" {
        guard let value = UInt32(rawValue) else {
            throw ParseError.invalidDirect("\(label) is not a valid uint32")
        }
        return .unsignedInteger(UInt64(value))
    }
    if baseType == "uint64" {
        guard let value = UInt64(rawValue) else {
            throw ParseError.invalidDirect("\(label) is not a valid uint64")
        }
        return .unsignedInteger(value)
    }
    if jsonObjectTypes.contains(baseType) {
        do {
            let value = try JSONDecoder().decode(GhostboxJSONValue.self, from: Data(rawValue.utf8))
            guard case .object = value else {
                throw ParseError.invalidDirect("\(label) must be a JSON object")
            }
            return value
        } catch let error as ParseError {
            throw error
        } catch {
            throw ParseError.invalidDirect("\(label) must be a valid JSON object")
        }
    }
    if baseType.contains("|") {
        let allowed = baseType.split(separator: "|").map(String.init)
        guard allowed.contains(rawValue) else {
            throw ParseError.invalidDirect("\(label) must be one of \(allowed.joined(separator: ", "))")
        }
    }
    return .string(rawValue)
}

private let jsonObjectTypes: Set<String> = [
    "mount-runtime-options",
    "oci-descriptor-json",
    "oci-image-config",
    "oci-user",
    "pod-volume-source",
]

private func appendRepeated(
    _ value: GhostboxJSONValue,
    for key: String,
    to parameters: inout [String: GhostboxJSONValue]
) {
    if let existing = parameters[key], case .array(var values) = existing {
        values.append(value)
        parameters[key] = .array(values)
    } else {
        parameters[key] = .array([value])
    }
}

private func splitOption(_ argument: String) -> (String, String?) {
    guard let separator = argument.firstIndex(of: "=") else { return (argument, nil) }
    return (String(argument[..<separator]), String(argument[argument.index(after: separator)...]))
}

func isValidReference(_ reference: String, expectedKind: String) -> Bool {
    guard reference.first == "@", let slash = reference.firstIndex(of: "/") else { return false }
    let kind = String(reference[reference.index(after: reference.startIndex)..<slash])
    let name = String(reference[reference.index(after: slash)...])
    return kind == expectedKind && !name.contains("/")
        && isValidReferenceComponent(kind) && isValidReferenceComponent(name)
}

func isValidReferenceComponent(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 128 && value.utf8.allSatisfy {
        (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
            || $0 == 45 || $0 == 46 || $0 == 95
    }
}
