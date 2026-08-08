import Foundation
import GhostVMKit

struct DirectDispatchError: Error, LocalizedError {
    let code: ContainerRuntimeErrorCode
    let message: String

    init(_ code: ContainerRuntimeErrorCode, _ message: String) {
        self.code = code
        self.message = message
    }

    var errorDescription: String? { message }
}

enum GhostboxResourceOverheadPolicy {
    // The bundled Linux environment reserves this much RAM before reporting MemTotal.
    static let guestKernelMemoryBytes: UInt64 = 28_808 * 1024

    static func cpu(requested: Int?, explicit: Int?) -> Int? {
        explicit ?? requested.map { _ in 0 }
    }

    static func memory(requested: UInt64?, explicit: UInt64?) -> UInt64? {
        explicit ?? requested.map { _ in guestKernelMemoryBytes }
    }
}

struct GhostboxCommandArguments: Sendable {
    let positionals: [String]
    private let options: [String: [String?]]

    init(_ arguments: [String]) throws {
        var positionals: [String] = []
        var options: [String: [String?]] = [:]
        var index = 0
        var optionsEnded = false

        while index < arguments.count {
            let argument = arguments[index]
            if !optionsEnded, argument == "--" {
                optionsEnded = true
                index += 1
                continue
            }
            guard !optionsEnded, argument.hasPrefix("--"), argument.count > 2 else {
                positionals.append(argument)
                index += 1
                continue
            }

            if let equals = argument.firstIndex(of: "=") {
                let name = String(argument[..<equals])
                guard name.count > 2 else {
                    throw DirectDispatchError(.invalidArgument, "invalid option '\(argument)'")
                }
                options[name, default: []].append(String(argument[argument.index(after: equals)...]))
                index += 1
                continue
            }

            if index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") {
                options[argument, default: []].append(arguments[index + 1])
                index += 2
            } else {
                options[argument, default: []].append(nil)
                index += 1
            }
        }

        self.positionals = positionals
        self.options = options
    }

    func contains(_ name: String) -> Bool {
        options[name] != nil
    }

    func rejectOptions(except allowed: Set<String> = []) throws {
        if let unknown = options.keys.first(where: { !allowed.contains($0) }) {
            throw DirectDispatchError(.invalidArgument, "unknown option '\(unknown)'")
        }
    }

    func values(_ name: String) throws -> [String] {
        guard let values = options[name] else { return [] }
        return try values.map { value in
            guard let value else {
                throw DirectDispatchError(.invalidArgument, "option \(name) requires a value")
            }
            return value
        }
    }

    func string(_ name: String) throws -> String? {
        guard let values = options[name] else { return nil }
        guard values.count == 1 else {
            throw DirectDispatchError(.invalidArgument, "option \(name) may be specified once")
        }
        guard let value = values[0] else {
            throw DirectDispatchError(.invalidArgument, "option \(name) requires a value")
        }
        return value
    }

    func boolean(_ name: String, default defaultValue: Bool = false) throws -> Bool {
        guard let values = options[name] else { return defaultValue }
        guard values.count == 1 else {
            throw DirectDispatchError(.invalidArgument, "option \(name) may be specified once")
        }
        guard let value = values[0] else { return true }
        switch value.lowercased() {
        case "true", "1", "yes": return true
        case "false", "0", "no": return false
        default: throw DirectDispatchError(.invalidArgument, "option \(name) requires a boolean value")
        }
    }

    func integer(_ name: String) throws -> Int64? {
        guard let value = try string(name) else { return nil }
        guard let result = Int64(value) else {
            throw DirectDispatchError(.invalidArgument, "option \(name) requires a signed integer")
        }
        return result
    }

    func unsignedInteger(_ name: String) throws -> UInt64? {
        guard let value = try string(name) else { return nil }
        guard let result = UInt64(value) else {
            throw DirectDispatchError(.invalidArgument, "option \(name) requires an unsigned integer")
        }
        return result
    }

    func jsonString(_ name: String) throws -> String? {
        guard let value = try string(name) else { return nil }
        do {
            return try JSONDecoder().decode(String.self, from: Data(value.utf8))
        } catch {
            throw DirectDispatchError(.invalidArgument, "option \(name) requires a JSON string")
        }
    }

    func reference(at index: Int, expectedKind: String) throws -> String {
        guard positionals.indices.contains(index) else {
            throw DirectDispatchError(.invalidArgument, "missing @\(expectedKind)/NAME reference")
        }
        return try GhostboxReference.canonical(positionals[index], expectedKind: expectedKind)
    }
}
