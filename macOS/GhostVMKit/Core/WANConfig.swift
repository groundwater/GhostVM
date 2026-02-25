import Foundation

public enum WANMode: String, Codable, CaseIterable {
    case nat
    case passthrough
    case isolated
}

public struct WANConfig: Codable, Equatable {
    public var upstream: String?
    public var mode: WANMode
    public var masquerade: Bool

    public init(
        upstream: String? = nil,
        mode: WANMode = .nat,
        masquerade: Bool = true
    ) {
        self.upstream = upstream
        self.mode = mode
        self.masquerade = masquerade
    }
}
