import Containerization
import ContainerizationError
import ContainerizationExtras
import GhostVMKit
import Virtualization
import vmnet

let ghostboxSharedNetworkContextKey = "org.ghostvm.ghostbox.shared-network"

final class GhostboxNetwork: Network, @unchecked Sendable {
    private final class SharedBackend: @unchecked Sendable {
        let subnet: CIDRv4
        let reference: vmnet_network_ref
        private let lock = NSLock()
        private var allocations: [String: UInt32] = [:]

        init(reference: vmnet_network_ref, subnet: CIDRv4) {
            self.reference = reference
            self.subnet = subnet
        }

        deinit {
            SharedVmnetNetwork.releaseVmnetReference(reference)
        }

        func allocate(_ id: String, gateway: Bool, mtu: UInt32) throws -> Containerization.Interface {
            let address = try lock.withLock { () -> UInt32 in
                guard allocations[id] == nil else {
                    throw ContainerizationError(.exists, message: "allocation with id \(id) already exists")
                }
                let network = subnet.lower.value
                let span = subnet.upper.value - network
                guard span > 3 else {
                    throw ContainerizationError(.empty, message: "shared GhostVM network is exhausted")
                }
                let midpoint = network + (span / 2) + (span % 2)
                let first = max(network + 3, midpoint)
                let used = Set(allocations.values)
                guard let address = (first..<subnet.upper.value).first(where: { !used.contains($0) }) else {
                    throw ContainerizationError(.empty, message: "shared GhostVM network is exhausted")
                }
                allocations[id] = address
                return address
            }
            return VmnetNetwork.Interface(
                reference: reference,
                ipv4Address: try CIDRv4(IPv4Address(address), prefix: subnet.prefix),
                ipv4Gateway: gateway ? subnet.gateway : nil,
                macAddress: try MACAddress(SharedVmnetIPv4Pool.macAddress(for: address)),
                mtu: mtu
            )
        }

        func release(_ id: String) {
            lock.withLock { allocations[id] = nil }
        }
    }

    private enum Backend {
        case owned(VmnetNetwork)
        case shared(SharedBackend)
    }

    private let lock = NSLock()
    private var backend: Backend

    init(mode: operating_modes_t, subnet: CIDRv4?, prefixV6: CIDRv6?) throws {
        backend = .owned(try VmnetNetwork(mode: mode, subnet: subnet, prefixV6: prefixV6))
    }

    init(sharedReference: vmnet_network_ref, subnet: CIDRv4) {
        backend = .shared(SharedBackend(reference: sharedReference, subnet: subnet))
    }

    var subnet: CIDRv4 {
        lock.withLock {
            switch backend {
            case .owned(let network): return network.subnet
            case .shared(let network): return network.subnet
            }
        }
    }

    var prefixV6: CIDRv6? {
        lock.withLock {
            guard case .owned(let network) = backend else { return nil }
            return network.prefixV6
        }
    }

    var ipv4Gateway: IPv4Address { subnet.gateway }

    var ipv6Gateway: IPv6Address? { prefixV6?.gateway }

    func createInterface(_ id: String) throws -> Containerization.Interface? {
        try createInterface(id, mtu: 1500, gateway: true)
    }

    func createInterface(_ id: String, mtu: UInt32) throws -> Containerization.Interface? {
        try createInterface(id, mtu: mtu, gateway: true)
    }

    func createInterfaceWithoutGateway(_ id: String) throws -> Containerization.Interface? {
        try createInterface(id, mtu: 1500, gateway: false)
    }

    func releaseInterface(_ id: String) throws {
        try lock.withLock {
            switch backend {
            case .owned(var network):
                try network.releaseInterface(id)
                backend = .owned(network)
            case .shared(let network):
                network.release(id)
            }
        }
    }

    private func createInterface(_ id: String, mtu: UInt32, gateway: Bool) throws -> Containerization.Interface? {
        try lock.withLock {
            switch backend {
            case .owned(var network):
                let interface = gateway
                    ? try network.createInterface(id, mtu: mtu)
                    : try network.createInterfaceWithoutGateway(id)
                backend = .owned(network)
                return interface
            case .shared(let network):
                return try network.allocate(id, gateway: gateway, mtu: mtu)
            }
        }
    }
}
