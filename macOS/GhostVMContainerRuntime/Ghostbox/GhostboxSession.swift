import Foundation

extension GhostboxSession {
    @discardableResult
    func registerMutable<Value: Sendable>(
        kind: String,
        name: String,
        value: Value,
        equivalent: @escaping @Sendable (Value, Value) -> Bool
    ) throws -> String {
        let slot = GhostboxMutableSlot(value)
        return try register(kind: kind, name: name, value: slot) { lhs, rhs in
            equivalent(lhs.get(), rhs.get())
        }
    }

    func mutableValue<Value: Sendable>(
        for reference: String,
        expectedKind: String,
        as type: Value.Type = Value.self
    ) throws -> GhostboxMutableSlot<Value> {
        try value(for: reference, expectedKind: expectedKind, as: GhostboxMutableSlot<Value>.self)
    }

    func valueSnapshot<Value: Sendable>(
        for reference: String,
        expectedKind: String,
        as type: Value.Type = Value.self
    ) throws -> Value {
        try mutableValue(for: reference, expectedKind: expectedKind, as: type).get()
    }

    func writeBack<Value: Sendable>(
        _ value: Value,
        for reference: String,
        expectedKind: String
    ) throws {
        let slot: GhostboxMutableSlot<Value> = try mutableValue(
            for: reference,
            expectedKind: expectedKind
        )
        slot.set(value)
    }

    func updateValue<Value: Sendable>(
        for reference: String,
        expectedKind: String,
        as type: Value.Type = Value.self,
        _ update: (inout Value) throws -> Void
    ) throws {
        let slot = try mutableValue(for: reference, expectedKind: expectedKind, as: type)
        try slot.update(update)
    }

}
