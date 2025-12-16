import Foundation

/// Tracks whether a VM is owned by the CLI or embedded in the app.
public enum VMLockOwner: Equatable {
    case cli(pid_t)
    case embedded(pid_t)

    public var pid: pid_t {
        switch self {
        case .cli(let pid), .embedded(let pid):
            return pid
        }
    }

    public var isEmbedded: Bool {
        if case .embedded = self { return true }
        return false
    }
}

/// Read the VM lock owner from a PID file.
public func readVMLockOwner(from url: URL) -> VMLockOwner? {
    guard let data = try? Data(contentsOf: url),
          let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
          !text.isEmpty else {
        return nil
    }

    if text.hasPrefix("embedded:") {
        let suffix = text.dropFirst("embedded:".count)
        if let pid = pid_t(suffix) {
            return .embedded(pid)
        }
        return nil
    }

    if let pid = pid_t(text) {
        return .cli(pid)
    }
    return nil
}

/// Write the VM lock owner to a PID file.
public func writeVMLockOwner(_ owner: VMLockOwner, to url: URL) throws {
    let prefix = owner.isEmbedded ? "embedded:" : ""
    try "\(prefix)\(owner.pid)\n".data(using: .utf8)?.write(to: url, options: .atomic)
}

/// Remove the VM lock file.
public func removeVMLock(at url: URL) {
    try? FileManager.default.removeItem(at: url)
}
