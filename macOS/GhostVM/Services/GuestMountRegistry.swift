import Foundation

enum GuestMountAccessPolicy {
    private static let guestMountMethods: Set<String> = [
        "mount.guestShare",
        "mount.sharedMount",
        "mount.delete",
        "mount.isBlock",
        "mount.type",
        "mount.source",
        "mount.destination",
        "mount.options",
        "mount.runtimeOptions",
    ]

    static func allowsGuestInvocation(_ method: String) -> Bool {
        !method.hasPrefix("mount.") || guestMountMethods.contains(method)
    }
}

enum PrivateGuestMountDirectory {
    static let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("GhostVM/container-runtime/mounts", isDirectory: true)

    static func create() throws -> URL {
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: rootURL.path)

        let mountPoint = rootURL.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(
            at: mountPoint,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return mountPoint
    }
}

struct GuestMountRegistry<Value> {
    enum Completion: Equatable {
        case registered
        case deleted
    }

    private var mounts: [String: Value] = [:]
    private var pending: Set<String> = []
    private var deletedPending: Set<String> = []

    mutating func reserve(_ reference: String) -> Bool {
        guard mounts[reference] == nil, !pending.contains(reference) else { return false }
        pending.insert(reference)
        deletedPending.remove(reference)
        return true
    }

    mutating func complete(_ reference: String, value: Value) -> Completion {
        precondition(pending.remove(reference) != nil)
        if deletedPending.remove(reference) != nil {
            return .deleted
        }
        mounts[reference] = value
        return .registered
    }

    mutating func abandon(_ reference: String) {
        pending.remove(reference)
        deletedPending.remove(reference)
    }

    mutating func release(_ reference: String) -> Value? {
        if pending.contains(reference) {
            deletedPending.insert(reference)
            return nil
        }
        return mounts.removeValue(forKey: reference)
    }

    mutating func removeAll() -> [Value] {
        let values = Array(mounts.values)
        mounts.removeAll()
        pending.removeAll()
        deletedPending.removeAll()
        return values
    }

    subscript(reference: String) -> Value? {
        mounts[reference]
    }
}
