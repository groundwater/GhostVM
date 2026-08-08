import Foundation
import GhostVMKit

struct GhostboxParameters: Sendable {
    private let values: [String: GhostboxJSONValue]

    init(_ values: [String: GhostboxJSONValue], allowed: Set<String>) throws {
        if let unknown = values.keys.sorted().first(where: { !allowed.contains($0) }) {
            throw DirectDispatchError(.invalidArgument, "unknown parameter '\(unknown)'")
        }
        self.values = values
    }

    func contains(_ name: String) -> Bool {
        values[name] != nil
    }

    func requiredString(_ name: String) throws -> String {
        guard let value = values[name] else { throw missing(name) }
        guard case .string(let result) = value else { throw typeError(name, "a string") }
        return result
    }

    func optionalString(_ name: String) throws -> String? {
        guard let value = values[name] else { return nil }
        guard case .string(let result) = value else { throw typeError(name, "a string") }
        return result
    }

    func requiredNullableString(_ name: String) throws -> String? {
        guard let value = values[name] else { throw missing(name) }
        if case .null = value { return nil }
        guard case .string(let result) = value else { throw typeError(name, "a string or null") }
        return result
    }

    func requiredBool(_ name: String) throws -> Bool {
        guard let value = values[name] else { throw missing(name) }
        guard case .boolean(let result) = value else { throw typeError(name, "a boolean") }
        return result
    }

    func optionalBool(_ name: String) throws -> Bool? {
        guard let value = values[name] else { return nil }
        guard case .boolean(let result) = value else { throw typeError(name, "a boolean") }
        return result
    }

    func requiredInteger<T: FixedWidthInteger & Sendable>(
        _ name: String,
        as type: T.Type = T.self
    ) throws -> T {
        guard let result: T = try optionalInteger(name, as: type) else { throw missing(name) }
        return result
    }

    func optionalInteger<T: FixedWidthInteger & Sendable>(
        _ name: String,
        as type: T.Type = T.self
    ) throws -> T? {
        guard let value = values[name] else { return nil }
        let result: T?
        if T.isSigned, case .integer(let raw) = value {
            result = T(exactly: raw)
        } else if !T.isSigned, case .unsignedInteger(let raw) = value {
            result = T(exactly: raw)
        } else {
            result = nil
        }
        guard let result else {
            let signedness = T.isSigned ? "signed" : "unsigned"
            throw typeError(name, "a \(signedness) integer representable as \(T.self)")
        }
        return result
    }

    func requiredNullableInteger<T: FixedWidthInteger & Sendable>(
        _ name: String,
        as type: T.Type = T.self
    ) throws -> T? {
        guard let value = values[name] else { throw missing(name) }
        if case .null = value { return nil }
        return try requiredInteger(name, as: type)
    }

    func requiredInt(_ name: String) throws -> Int {
        try requiredInteger(name)
    }

    func optionalInt(_ name: String) throws -> Int? {
        try optionalInteger(name)
    }

    func requiredInt64(_ name: String) throws -> Int64 {
        try requiredInteger(name)
    }

    func optionalInt64(_ name: String) throws -> Int64? {
        try optionalInteger(name)
    }

    func requiredUInt(_ name: String) throws -> UInt {
        try requiredInteger(name)
    }

    func optionalUInt(_ name: String) throws -> UInt? {
        try optionalInteger(name)
    }

    func requiredUInt64(_ name: String) throws -> UInt64 {
        try requiredInteger(name)
    }

    func optionalUInt64(_ name: String) throws -> UInt64? {
        try optionalInteger(name)
    }

    func requiredArray(_ name: String) throws -> [GhostboxJSONValue] {
        guard let value = values[name] else { throw missing(name) }
        guard case .array(let result) = value else { throw typeError(name, "an array") }
        return result
    }

    func optionalArray(_ name: String) throws -> [GhostboxJSONValue]? {
        guard let value = values[name] else { return nil }
        guard case .array(let result) = value else { throw typeError(name, "an array") }
        return result
    }

    func requiredStringArray(_ name: String) throws -> [String] {
        try strings(requiredArray(name), name: name)
    }

    func optionalStringArray(_ name: String) throws -> [String]? {
        guard let values = try optionalArray(name) else { return nil }
        return try strings(values, name: name)
    }

    func requiredObject(_ name: String) throws -> [String: GhostboxJSONValue] {
        guard let value = values[name] else { throw missing(name) }
        guard case .object(let result) = value else { throw typeError(name, "an object") }
        return result
    }

    func optionalObject(_ name: String) throws -> [String: GhostboxJSONValue]? {
        guard let value = values[name] else { return nil }
        guard case .object(let result) = value else { throw typeError(name, "an object") }
        return result
    }

    func optionalValue(_ name: String) -> GhostboxJSONValue? {
        values[name]
    }

    func requiredReference(_ name: String, expectedKind: String) throws -> String {
        try GhostboxReference.canonical(requiredString(name), expectedKind: expectedKind)
    }

    func optionalReference(_ name: String, expectedKind: String) throws -> String? {
        guard let reference = try optionalString(name) else { return nil }
        return try GhostboxReference.canonical(reference, expectedKind: expectedKind)
    }

    func requiredNullableReference(_ name: String, expectedKind: String) throws -> String? {
        guard let reference = try requiredNullableString(name) else { return nil }
        return try GhostboxReference.canonical(reference, expectedKind: expectedKind)
    }

    func requiredReferences(_ name: String, expectedKind: String) throws -> [String] {
        try requiredStringArray(name).map {
            try GhostboxReference.canonical($0, expectedKind: expectedKind)
        }
    }

    func optionalReferences(_ name: String, expectedKind: String) throws -> [String]? {
        guard let references = try optionalStringArray(name) else { return nil }
        return try references.map {
            try GhostboxReference.canonical($0, expectedKind: expectedKind)
        }
    }

    private func strings(_ values: [GhostboxJSONValue], name: String) throws -> [String] {
        try values.enumerated().map { index, value in
            guard case .string(let result) = value else {
                throw DirectDispatchError(
                    .invalidArgument,
                    "parameter '\(name)' element \(index) must be a string"
                )
            }
            return result
        }
    }

    private func missing(_ name: String) -> DirectDispatchError {
        DirectDispatchError(.invalidArgument, "missing required parameter '\(name)'")
    }

    private func typeError(_ name: String, _ expected: String) -> DirectDispatchError {
        DirectDispatchError(.invalidArgument, "parameter '\(name)' must be \(expected)")
    }
}
