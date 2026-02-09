import Foundation

public struct FlagDescriptor: Identifiable {
    public let key: String
    public let displayName: String
    public let description: String
    public var id: String { key }
}

public final class FeatureFlags {
    public static let shared = FeatureFlags()
    private let defaults: UserDefaults
    private static let keyPrefix = "featureFlag_"

    public static let allFlags: [FlagDescriptor] = [
    ]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func isEnabled(_ key: String) -> Bool {
        defaults.bool(forKey: Self.keyPrefix + key)
    }

    public func setEnabled(_ key: String, value: Bool) {
        defaults.set(value, forKey: Self.keyPrefix + key)
    }
}
