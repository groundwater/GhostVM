import Foundation

public enum SharedVmnetIPv4PoolError: Error, Equatable {
    case exhausted
}

/// Deterministic first-fit allocator for the static container range of a
/// shared vmnet subnet. The gateway (.1) and macOS DHCP lease (.2) are skipped.
public struct SharedVmnetIPv4Pool {
    public let subnet: UInt32
    public let mask: UInt32
    public let prefixLength: UInt64
    private var allocations: [String: UInt32] = [:]

    public init(subnet: UInt32, mask: UInt32, prefixLength: UInt64) {
        self.subnet = subnet & mask
        self.mask = mask
        self.prefixLength = prefixLength
    }

    public mutating func allocate(endpointIdentifier: String) throws -> UInt32 {
        if let existing = allocations[endpointIdentifier] { return existing }
        let broadcast = subnet | ~mask
        guard broadcast > subnet + 3 else { throw SharedVmnetIPv4PoolError.exhausted }

        let used = Set(allocations.values)
        for address in (subnet + 3)..<broadcast where !used.contains(address) {
            allocations[endpointIdentifier] = address
            return address
        }
        throw SharedVmnetIPv4PoolError.exhausted
    }

    public mutating func release(endpointIdentifier: String) {
        allocations[endpointIdentifier] = nil
    }

    public static func string(for address: UInt32) -> String {
        "\((address >> 24) & 0xff).\((address >> 16) & 0xff).\((address >> 8) & 0xff).\(address & 0xff)"
    }
}
