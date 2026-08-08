import ContainerAPIClient
import ContainerPersistence
import ContainerResource
import Foundation
import GhostVMKit

struct GhostboxContainerMemorySizeCommands: GhostboxDomainHandler {
    let resource = "crMemorySize"

    func handle(
        method: GhostboxDirectMethod,
        parameters: [String: GhostboxJSONValue],
        session: GhostboxSession
    ) async throws -> GhostboxDirectValue {
        switch method.rawValue {
        case "crMemorySize.create":
            let decoded = try GhostboxParameters(parameters, allowed: ["memorySize", "value"])
            let name = try decoded.requiredString("memorySize")
            let memorySize: MemorySize
            do {
                memorySize = try MemorySize(decoded.requiredString("value"))
            } catch {
                throw DirectDispatchError(.invalidArgument, "invalid memory size: \(error)")
            }
            let bytes = memorySize.measurement.converted(to: .bytes).value
            guard bytes.isFinite, bytes >= 0, bytes <= Double(UInt64.max) else {
                throw DirectDispatchError(.invalidArgument, "memory size is outside the UInt64 byte range")
            }
            let reference = try session.registerNew(
                kind: "memory-size",
                name: name,
                makeValue: { memorySize },
                equivalent: ==
            )
            return .reference(reference)

        case "crMemorySize.formatted":
            let memorySize = try value(parameters, session: session)
            return .string(memorySize.formatted)

        case "crMemorySize.toUInt64":
            let decoded = try GhostboxParameters(parameters, allowed: ["memorySize", "unit"])
            let reference = try decoded.requiredReference("memorySize", expectedKind: "memory-size")
            let memorySize: MemorySize = try session.value(for: reference, expectedKind: "memory-size")
            let unit: UnitInformationStorage
            switch try decoded.requiredString("unit") {
            case "bytes": unit = .bytes
            case "kibibytes": unit = .kibibytes
            case "mebibytes": unit = .mebibytes
            case "gibibytes": unit = .gibibytes
            case "tebibytes": unit = .tebibytes
            case "pebibytes": unit = .pebibytes
            default:
                throw DirectDispatchError(.invalidArgument, "unsupported information-storage unit")
            }
            return .unsignedInteger(memorySize.toUInt64(unit: unit))

        default:
            throw ghostboxUnsupported(method)
        }
    }

    private func value(
        _ parameters: [String: GhostboxJSONValue],
        session: GhostboxSession
    ) throws -> MemorySize {
        let decoded = try GhostboxParameters(parameters, allowed: ["memorySize"])
        let reference = try decoded.requiredReference("memorySize", expectedKind: "memory-size")
        return try session.value(for: reference, expectedKind: "memory-size")
    }
}

struct GhostboxContainerResourceLabelsCommands: GhostboxDomainHandler {
    let resource = "crResourceLabels"

    func handle(
        method: GhostboxDirectMethod,
        parameters: [String: GhostboxJSONValue],
        session: GhostboxSession
    ) async throws -> GhostboxDirectValue {
        switch method.rawValue {
        case "crResourceLabels.create":
            let decoded = try GhostboxParameters(parameters, allowed: ["resourceLabels", "label"])
            let name = try decoded.requiredString("resourceLabels")
            let labels = try parseLabels(try decoded.optionalStringArray("label") ?? [])
            let value: ResourceLabels
            do {
                value = try ResourceLabels(labels)
            } catch {
                throw DirectDispatchError(.invalidArgument, error.localizedDescription)
            }
            return .reference(try session.registerNew(
                kind: "resource-labels",
                name: name,
                makeValue: { value },
                equivalent: ==
            ))

        case "crResourceLabels.validateKey":
            let decoded = try GhostboxParameters(parameters, allowed: ["key"])
            do {
                try ResourceLabels.validateLabelKey(decoded.requiredString("key"))
            } catch {
                throw DirectDispatchError(.invalidArgument, error.localizedDescription)
            }
            return .void

        case "crResourceLabels.validate":
            let decoded = try GhostboxParameters(parameters, allowed: ["key", "value"])
            do {
                try ResourceLabels.validateLabel(
                    key: decoded.requiredString("key"),
                    value: decoded.requiredString("value")
                )
            } catch {
                throw DirectDispatchError(.invalidArgument, error.localizedDescription)
            }
            return .void

        case "crResourceLabels.dictionary":
            return .object(try labels(parameters, session: session).dictionary.mapValues(GhostboxDirectValue.string))

        case "crResourceLabels.value":
            let decoded = try GhostboxParameters(parameters, allowed: ["resourceLabels", "key"])
            let reference = try decoded.requiredReference("resourceLabels", expectedKind: "resource-labels")
            let labels: ResourceLabels = try session.value(for: reference, expectedKind: "resource-labels")
            return labels[try decoded.requiredString("key")].map(GhostboxDirectValue.string) ?? .null

        case "crResourceLabels.keyLengthMax":
            _ = try GhostboxParameters(parameters, allowed: [])
            return .integer(Int64(ResourceLabels.keyLengthMax))

        case "crResourceLabels.labelLengthMax":
            _ = try GhostboxParameters(parameters, allowed: [])
            return .integer(Int64(ResourceLabels.labelLengthMax))

        default:
            throw ghostboxUnsupported(method)
        }
    }

    private func labels(
        _ parameters: [String: GhostboxJSONValue],
        session: GhostboxSession
    ) throws -> ResourceLabels {
        let decoded = try GhostboxParameters(parameters, allowed: ["resourceLabels"])
        let reference = try decoded.requiredReference("resourceLabels", expectedKind: "resource-labels")
        return try session.value(for: reference, expectedKind: "resource-labels")
    }

    private func parseLabels(_ labels: [String]) throws -> [String: String] {
        var result: [String: String] = [:]
        for label in labels {
            guard let separator = label.firstIndex(of: "="), separator != label.startIndex else {
                throw DirectDispatchError(.invalidArgument, "labels must use key=value syntax")
            }
            let key = String(label[..<separator])
            guard result[key] == nil else {
                throw DirectDispatchError(.invalidArgument, "duplicate label key '\(key)'")
            }
            result[key] = String(label[label.index(after: separator)...])
        }
        return result
    }
}

struct GhostboxContainerParserCommands: GhostboxDomainHandler {
    let resource = "crParser"

    func handle(
        method: GhostboxDirectMethod,
        parameters: [String: GhostboxJSONValue],
        session _: GhostboxSession
    ) async throws -> GhostboxDirectValue {
        switch method.rawValue {
        case "crParser.memoryAsMiB":
            let memory = try singleString(parameters, name: "memory")
            try validateMemoryConversion(memory)
            return .integer(try ContainerAPIClient.Parser.memoryStringAsMiB(memory))

        case "crParser.memoryAsBytes":
            let memory = try singleString(parameters, name: "memory")
            try validateMemoryConversion(memory)
            return .unsignedInteger(try ContainerAPIClient.Parser.memoryStringAsBytes(memory))

        case "crParser.labels":
            let decoded = try GhostboxParameters(parameters, allowed: ["label"])
            let labels = try ContainerAPIClient.Parser.labels(decoded.requiredStringArray("label"))
            return .object(labels.mapValues(GhostboxDirectValue.string))

        case "crParser.platform":
            return try ghostboxEncodedValue(
                ContainerAPIClient.Parser.platform(from: singleString(parameters, name: "platform"))
            )

        case "crParser.isValidDomainName":
            return .boolean(ContainerAPIClient.Parser.isValidDomainName(try singleString(parameters, name: "name")))

        case "crParser.isValidDomainNameLabel":
            return .boolean(ContainerAPIClient.Parser.isValidDomainNameLabel(try singleString(parameters, name: "label")))

        case "crParser.parseBool":
            return ContainerAPIClient.Parser.parseBool(string: try singleString(parameters, name: "value"))
                .map(GhostboxDirectValue.boolean) ?? .null

        default:
            throw ghostboxUnsupported(method)
        }
    }

    private func singleString(_ parameters: [String: GhostboxJSONValue], name: String) throws -> String {
        try GhostboxParameters(parameters, allowed: [name]).requiredString(name)
    }

    private func validateMemoryConversion(_ value: String) throws {
        let memory: MemorySize
        do {
            memory = try MemorySize(value)
        } catch {
            throw DirectDispatchError(.invalidArgument, "invalid memory size: \(error)")
        }
        let bytes = memory.measurement.converted(to: .bytes).value
        guard bytes.isFinite, bytes >= 0, bytes <= Double(UInt64.max) else {
            throw DirectDispatchError(.invalidArgument, "memory size is outside the UInt64 byte range")
        }
    }
}
