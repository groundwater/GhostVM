import Foundation

/// Error type for VM operations.
public enum VMError: Error, CustomStringConvertible {
    case message(String)

    public var description: String {
        switch self {
        case .message(let text):
            return text
        }
    }
}
