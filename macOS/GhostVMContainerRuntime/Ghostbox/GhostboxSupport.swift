import Foundation
import GhostVMKit

protocol GhostboxDomainHandler: Sendable {
    var resource: String { get }

    func handle(
        method: GhostboxDirectMethod,
        parameters: [String: GhostboxJSONValue],
        session: GhostboxSession
    ) async throws -> GhostboxDirectValue
}

func ghostboxUnsupported(_ method: GhostboxDirectMethod) -> DirectDispatchError {
    DirectDispatchError(.unsupported, "unsupported direct method '\(method.rawValue)'")
}

func ghostboxEncodedValue<Value: Encodable>(_ value: Value) throws -> GhostboxDirectValue {
    let data = try JSONEncoder().encode(value)
    let json = try JSONDecoder().decode(GhostboxJSONValue.self, from: data)
    return ghostboxDirectValue(json)
}

private func ghostboxDirectValue(_ value: GhostboxJSONValue) -> GhostboxDirectValue {
    switch value {
    case .null: return .null
    case .boolean(let value): return .boolean(value)
    case .string(let value): return .string(value)
    case .integer(let value): return .integer(value)
    case .unsignedInteger(let value): return .unsignedInteger(value)
    case .array(let values): return .array(values.map(ghostboxDirectValue))
    case .object(let values): return .object(values.mapValues(ghostboxDirectValue))
    }
}
