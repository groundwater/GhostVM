import Foundation

/// Runtime override for shared folder settings during VM start.
public struct RuntimeSharedFolderOverride {
    public let path: String
    public let readOnly: Bool

    public init(path: String, readOnly: Bool) {
        self.path = path
        self.readOnly = readOnly
    }
}
