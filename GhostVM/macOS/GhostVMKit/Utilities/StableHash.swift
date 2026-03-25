import Foundation

extension String {
    /// Deterministic hash that is stable across processes (unlike `.hashValue`).
    ///
    /// Swift's `Hashable` uses random per-process seeding (SE-0206), so the same
    /// string produces different `.hashValue` values in different processes. This
    /// property uses the DJB2 algorithm to produce a consistent result regardless
    /// of process, making it safe for cross-process notification names.
    public var stableHash: UInt64 {
        var hash: UInt64 = 5381
        for byte in self.utf8 {
            hash = ((hash &<< 5) &+ hash) &+ UInt64(byte)
        }
        return hash
    }
}
