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
        FlagDescriptor(
            key: "linuxVMSupport",
            displayName: "Linux VM Support",
            description: "Enable creating and managing Linux virtual machines. Existing Linux VMs remain accessible regardless of this setting."
        ),
    ]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var linuxVMSupport: Bool {
        get { defaults.bool(forKey: Self.keyPrefix + "linuxVMSupport") }
        set { defaults.set(newValue, forKey: Self.keyPrefix + "linuxVMSupport") }
    }

    public func isEnabled(_ key: String) -> Bool {
        defaults.bool(forKey: Self.keyPrefix + key)
    }

    public func setEnabled(_ key: String, value: Bool) {
        defaults.set(value, forKey: Self.keyPrefix + key)
    }
}
