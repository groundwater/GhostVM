import Foundation
import GhostVMKit

enum GhostboxReference {
    static func canonical(kind: String, name: String) throws -> String {
        guard isComponent(kind), isComponent(name) else {
            throw DirectDispatchError(.invalidArgument, "object kind and name may contain only letters, digits, '.', '_', or '-'")
        }
        return "@\(kind)/\(name)"
    }

    static func canonical(_ reference: String, expectedKind: String) throws -> String {
        guard reference.first == "@",
              let slash = reference.firstIndex(of: "/"),
              reference[reference.index(after: slash)...].firstIndex(of: "/") == nil else {
            throw DirectDispatchError(.invalidArgument, "invalid @\(expectedKind)/NAME reference")
        }
        let kind = String(reference[reference.index(after: reference.startIndex)..<slash])
        let name = String(reference[reference.index(after: slash)...])
        guard kind == expectedKind else {
            throw DirectDispatchError(.invalidArgument, "expected @\(expectedKind)/NAME reference")
        }
        return try canonical(kind: kind, name: name)
    }

    private static func isComponent(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0)
        }
    }
}

final class GhostboxMutableSlot<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func get() -> Value {
        lock.withLock { value }
    }

    func set(_ value: Value) {
        lock.withLock { self.value = value }
    }

    func update(_ body: (inout Value) throws -> Void) rethrows {
        try lock.withLock { try body(&value) }
    }
}

final class GhostboxSession: @unchecked Sendable {
    static let objectQuota = 256

    private struct Entry {
        let value: Any
        let isEquivalent: (Any) -> Bool
        let cleanupPriority: Int
        let cancel: @Sendable () -> Void
        let cleanup: @Sendable () async -> Void
    }

    private let lock = NSLock()
    private let context: [String: Any]
    private var entries: [String: Entry] = [:]
    private var activeInvocations = 0
    private var closing = false
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    init(context: [String: Any] = [:]) {
        self.context = context
    }

    var count: Int {
        lock.withLock { entries.count }
    }

    func contextValue<Value>(_ key: String, as type: Value.Type = Value.self) -> Value? {
        context[key] as? Value
    }

    @discardableResult
    func register<Value: Sendable>(
        kind: String,
        name: String,
        value: Value,
        equivalent: @escaping @Sendable (Value, Value) -> Bool,
        cleanupPriority: Int = 0,
        cancel: @escaping @Sendable (Value) -> Void = { _ in },
        cleanup: @escaping @Sendable (Value) async -> Void = { _ in }
    ) throws -> String {
        let reference = try GhostboxReference.canonical(kind: kind, name: name)
        return try lock.withLock {
            guard !closing || activeInvocations > 0 else {
                throw DirectDispatchError(.unavailable, "direct session is closing")
            }
            if let existing = entries[reference] {
                guard existing.isEquivalent(value) else {
                    throw DirectDispatchError(.alreadyExists, "object '\(reference)' already exists")
                }
                return reference
            }
            guard entries.count < Self.objectQuota else {
                throw DirectDispatchError(.resourceExhausted, "direct object limit of \(Self.objectQuota) reached")
            }
            entries[reference] = Entry(
                value: value,
                isEquivalent: { candidate in
                    guard let candidate = candidate as? Value else { return false }
                    return equivalent(value, candidate)
                },
                cleanupPriority: cleanupPriority,
                cancel: { cancel(value) },
                cleanup: { await cleanup(value) }
            )
            return reference
        }
    }

    @discardableResult
    func registerNew<Value: Sendable>(
        kind: String,
        name: String,
        makeValue: () throws -> Value,
        equivalent: @escaping @Sendable (Value, Value) -> Bool,
        cleanupPriority: Int = 0,
        cancel: @escaping @Sendable (Value) -> Void = { _ in },
        cleanup: @escaping @Sendable (Value) async -> Void = { _ in }
    ) throws -> String {
        let reference = try GhostboxReference.canonical(kind: kind, name: name)
        return try lock.withLock {
            guard !closing || activeInvocations > 0 else {
                throw DirectDispatchError(.unavailable, "direct session is closing")
            }
            guard entries[reference] == nil else {
                throw DirectDispatchError(.alreadyExists, "object '\(reference)' already exists")
            }
            guard entries.count < Self.objectQuota else {
                throw DirectDispatchError(.resourceExhausted, "direct object limit of \(Self.objectQuota) reached")
            }
            let value = try makeValue()
            entries[reference] = Entry(
                value: value,
                isEquivalent: { candidate in
                    guard let candidate = candidate as? Value else { return false }
                    return equivalent(value, candidate)
                },
                cleanupPriority: cleanupPriority,
                cancel: { cancel(value) },
                cleanup: { await cleanup(value) }
            )
            return reference
        }
    }

    func registerAliases<Value: Sendable>(
        _ aliases: [(kind: String, name: String)],
        value: Value,
        equivalent: @escaping @Sendable (Value, Value) -> Bool
    ) throws -> [String] {
        let references = try aliases.map { try GhostboxReference.canonical(kind: $0.kind, name: $0.name) }
        return try lock.withLock {
            guard !closing || activeInvocations > 0 else {
                throw DirectDispatchError(.unavailable, "direct session is closing")
            }
            for reference in references {
                if let existing = entries[reference], !existing.isEquivalent(value) {
                    throw DirectDispatchError(.alreadyExists, "object '\(reference)' already exists")
                }
            }
            let newCount = references.filter { entries[$0] == nil }.count
            guard entries.count + newCount <= Self.objectQuota else {
                throw DirectDispatchError(.resourceExhausted, "direct object limit of \(Self.objectQuota) reached")
            }
            for reference in references where entries[reference] == nil {
                entries[reference] = Entry(
                    value: value,
                    isEquivalent: { candidate in
                        guard let candidate = candidate as? Value else { return false }
                        return equivalent(value, candidate)
                    },
                    cleanupPriority: 0,
                    cancel: {},
                    cleanup: {}
                )
            }
            return references
        }
    }

    func value<Value: Sendable>(
        for reference: String,
        expectedKind: String,
        as type: Value.Type = Value.self
    ) throws -> Value {
        let canonical = try GhostboxReference.canonical(reference, expectedKind: expectedKind)
        let result: (found: Bool, value: Value?) = lock.withLock {
            guard let entry = entries[canonical] else { return (false, nil) }
            return (true, entry.value as? Value)
        }
        guard result.found else {
            throw DirectDispatchError(.notFound, "object '\(canonical)' was not found")
        }
        guard let value = result.value else {
            throw DirectDispatchError(.failedPrecondition, "object '\(canonical)' has an incompatible stored representation")
        }
        return value
    }

    func valueSnapshots<Value: Sendable>(
        ofKind kind: String,
        as type: Value.Type = Value.self
    ) throws -> [(reference: String, value: Value)] {
        let prefix = String(try GhostboxReference.canonical(kind: kind, name: "snapshot").dropLast("snapshot".count))
        return try lock.withLock {
            try entries.compactMap { reference, entry in
                guard reference.hasPrefix(prefix) else { return nil }
                guard let value = entry.value as? Value else {
                    throw DirectDispatchError(
                        .failedPrecondition,
                        "object '\(reference)' has an incompatible stored representation"
                    )
                }
                return (reference: reference, value: value)
            }.sorted { $0.reference < $1.reference }
        }
    }

    @discardableResult
    func unregister<Value: Sendable>(
        _ reference: String,
        expectedKind: String,
        matching value: Value
    ) throws -> Bool {
        let canonical = try GhostboxReference.canonical(reference, expectedKind: expectedKind)
        return lock.withLock {
            guard let entry = entries[canonical], entry.isEquivalent(value) else { return false }
            entries.removeValue(forKey: canonical)
            return true
        }
    }

    @discardableResult
    func unregisterAndCleanup<Value: Sendable>(
        _ reference: String,
        expectedKind: String,
        matching value: Value
    ) async throws -> Bool {
        let canonical = try GhostboxReference.canonical(reference, expectedKind: expectedKind)
        let cleanup: (@Sendable () async -> Void)? = lock.withLock {
            guard let entry = entries[canonical], entry.isEquivalent(value) else { return nil }
            entries.removeValue(forKey: canonical)
            return entry.cleanup
        }
        guard let cleanup else { return false }
        await cleanup()
        return true
    }

    func beginInvocation() throws {
        try lock.withLock {
            guard !closing else {
                throw DirectDispatchError(.unavailable, "direct session is closing")
            }
            activeInvocations += 1
        }
    }

    func endInvocation() {
        let waiters: [CheckedContinuation<Void, Never>] = lock.withLock {
            precondition(activeInvocations > 0)
            activeInvocations -= 1
            guard closing, activeInvocations == 0 else { return [] }
            defer { idleWaiters.removeAll() }
            return idleWaiters
        }
        for waiter in waiters { waiter.resume() }
    }

    func close() async {
        let cancellations = lock.withLock {
            closing = true
            return entries.values.map(\.cancel)
        }
        for cancel in cancellations { cancel() }

        await withCheckedContinuation { continuation in
            let resumeImmediately = lock.withLock {
                if activeInvocations == 0 { return true }
                idleWaiters.append(continuation)
                return false
            }
            if resumeImmediately { continuation.resume() }
        }

        let cleanups = lock.withLock {
            let values = entries.values.sorted { $0.cleanupPriority > $1.cleanupPriority }.map(\.cleanup)
            entries.removeAll()
            return values
        }
        for cleanup in cleanups {
            await cleanup()
        }
    }
}
