import Foundation
import Virtualization
import XPC
import vmnet

public enum SharedVmnetError: Error, LocalizedError {
    case invalidMACAddress(String)
    case networkCreationFailed(vmnet_return_t)
    case serializationFailed(vmnet_return_t)
    case networkClosed

    public var errorDescription: String? {
        switch self {
        case .invalidMACAddress(let address):
            return "Invalid MAC address for shared vmnet network: \(address)"
        case .networkCreationFailed(let status):
            return "Failed to create shared vmnet network (status \(status.rawValue))."
        case .serializationFailed(let status):
            return "Failed to serialize shared vmnet network (status \(status.rawValue))."
        case .networkClosed:
            return "The shared vmnet network is closed."
        }
    }
}

/// Owns the shared-mode vmnet network used by one NAT macOS VM and allocates
/// endpoint settings for container VMs hosted by the runtime XPC service.
public final class SharedVmnetNetwork: @unchecked Sendable {
    public let networkIdentifier: String
    public let networkReference: vmnet_network_ref
    public let serialization: xpc_object_t
    public let ipv4Subnet: String
    public let ipv4Gateway: String

    private let lock = NSLock()
    private var pool: SharedVmnetIPv4Pool
    private var closed = false

    public init(networkIdentifier: String, vmMACAddress: String, preferredIPv4Subnet: String? = nil) throws {
        let macBytes = try Self.parseMACAddress(vmMACAddress)
        let created = try Self.createNetwork(
            vmMACAddress: macBytes,
            preferredSubnetOctet: Self.subnetOctet(from: preferredIPv4Subnet)
        )

        var status: vmnet_return_t = .VMNET_FAILURE
        guard let serialization = vmnet_network_copy_serialization(created.reference, &status), status == .VMNET_SUCCESS else {
            Self.releaseVmnetReference(created.reference)
            throw SharedVmnetError.serializationFailed(status)
        }

        self.networkIdentifier = networkIdentifier
        self.networkReference = created.reference
        self.serialization = serialization
        self.ipv4Subnet = "\(created.subnetString)/\(created.prefixLength)"
        self.ipv4Gateway = created.gateway
        self.pool = SharedVmnetIPv4Pool(
            subnet: created.subnet,
            mask: created.mask,
            prefixLength: created.prefixLength
        )
    }

    public var attachment: VZVmnetNetworkDeviceAttachment {
        VZVmnetNetworkDeviceAttachment(network: networkReference)
    }

    public func acquireEndpoint(identifier: String) throws -> SharedVmnetEndpointLease {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { throw SharedVmnetError.networkClosed }
        let address = try pool.allocate(endpointIdentifier: identifier)
        return SharedVmnetEndpointLease(
            owner: self,
            endpointIdentifier: identifier,
            serialization: serialization,
            ipv4Address: "\(SharedVmnetIPv4Pool.string(for: address))/\(pool.prefixLength)",
            ipv4Gateway: ipv4Gateway,
            macAddress: Self.macAddress(networkIdentifier: networkIdentifier, endpointIdentifier: identifier),
            mtu: 1500
        )
    }

    public func close() {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        closed = true
        lock.unlock()
        Self.releaseVmnetReference(networkReference)
    }

    deinit {
        close()
    }

    private struct CreatedNetwork {
        let reference: vmnet_network_ref
        let subnet: UInt32
        let mask: UInt32
        let prefixLength: UInt64
        let subnetString: String
        let gateway: String
    }

    private static func createNetwork(vmMACAddress: [UInt8], preferredSubnetOctet: UInt8?) throws -> CreatedNetwork {
        var lastStatus: vmnet_return_t = .VMNET_FAILURE
        var candidates: [UInt8] = preferredSubnetOctet.map { [$0] } ?? []
        while candidates.count < 64 {
            let candidate = UInt8.random(in: 1...254)
            if !candidates.contains(candidate) { candidates.append(candidate) }
        }

        // vmnet reserves the configured subnet atomically. Retry random /24s
        // so concurrently running GhostVM instances cannot collide.
        for octet in candidates {
            var status: vmnet_return_t = .VMNET_FAILURE
            guard let configuration = vmnet_network_configuration_create(.VMNET_SHARED_MODE, &status) else {
                throw SharedVmnetError.networkCreationFailed(status)
            }

            let gatewayString = "192.168.\(octet).1"
            let vmAddressString = "192.168.\(octet).2"
            var gatewayAddress = in_addr()
            var mask = in_addr()
            var vmAddress = in_addr()
            _ = gatewayString.withCString { inet_pton(AF_INET, $0, &gatewayAddress) }
            _ = "255.255.255.0".withCString { inet_pton(AF_INET, $0, &mask) }
            _ = vmAddressString.withCString { inet_pton(AF_INET, $0, &vmAddress) }

            // Despite its parameter name, vmnet expects the first host address,
            // which becomes the shared-mode gateway, rather than the network address.
            let subnetStatus = vmnet_network_configuration_set_ipv4_subnet(configuration, &gatewayAddress, &mask)
            var mac = ether_addr(octet: (
                vmMACAddress[0], vmMACAddress[1], vmMACAddress[2],
                vmMACAddress[3], vmMACAddress[4], vmMACAddress[5]
            ))
            let reservationStatus = vmnet_network_configuration_add_dhcp_reservation(configuration, &mac, &vmAddress)

            if subnetStatus == .VMNET_SUCCESS, reservationStatus == .VMNET_SUCCESS,
               let reference = vmnet_network_create(configuration, &status), status == .VMNET_SUCCESS {
                releaseVmnetReference(configuration)
                var actualSubnet = in_addr()
                var actualMask = in_addr()
                vmnet_network_get_ipv4_subnet(reference, &actualSubnet, &actualMask)
                let subnet = UInt32(bigEndian: actualSubnet.s_addr) & UInt32(bigEndian: actualMask.s_addr)
                let maskValue = UInt32(bigEndian: actualMask.s_addr)
                return CreatedNetwork(
                    reference: reference,
                    subnet: subnet,
                    mask: maskValue,
                    prefixLength: UInt64(maskValue.nonzeroBitCount),
                    subnetString: SharedVmnetIPv4Pool.string(for: subnet),
                    gateway: SharedVmnetIPv4Pool.string(for: subnet + 1)
                )
            }

            lastStatus = status
            releaseVmnetReference(configuration)
        }

        throw SharedVmnetError.networkCreationFailed(lastStatus)
    }

    private static func parseMACAddress(_ address: String) throws -> [UInt8] {
        let parts = address.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 6 else { throw SharedVmnetError.invalidMACAddress(address) }
        let bytes = parts.compactMap { UInt8($0, radix: 16) }
        guard bytes.count == 6 else { throw SharedVmnetError.invalidMACAddress(address) }
        return bytes
    }

    private static func subnetOctet(from subnet: String?) -> UInt8? {
        guard let subnet else { return nil }
        let components = subnet.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 4,
              components[0] == "192",
              components[1] == "168",
              components[3] == "0/24",
              let octet = UInt8(components[2]),
              octet > 0,
              octet < 255 else {
            return nil
        }
        return octet
    }

    fileprivate func releaseEndpoint(identifier: String) {
        lock.lock()
        pool.release(endpointIdentifier: identifier)
        lock.unlock()
    }

    private static func macAddress(networkIdentifier: String, endpointIdentifier: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in "\(networkIdentifier):\(endpointIdentifier)".utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        let bytes: [UInt8] = [
            0x02,
            UInt8((hash >> 32) & 0xff),
            UInt8((hash >> 24) & 0xff),
            UInt8((hash >> 16) & 0xff),
            UInt8((hash >> 8) & 0xff),
            UInt8(hash & 0xff),
        ]
        return bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
    }

    public static func releaseVmnetReference(_ reference: OpaquePointer) {
        Unmanaged<AnyObject>.fromOpaque(UnsafeRawPointer(reference)).release()
    }
}

/// Helper-owned endpoint allocation. Its opaque network serialization is sent
/// directly to the runtime service and the address is returned to IPAM on close.
public final class SharedVmnetEndpointLease: @unchecked Sendable {
    public let serialization: xpc_object_t
    public let ipv4Address: String
    public let ipv4Gateway: String
    public let macAddress: String
    public let mtu: UInt32

    private let owner: SharedVmnetNetwork
    private let endpointIdentifier: String
    private let lock = NSLock()
    private var closed = false

    fileprivate init(
        owner: SharedVmnetNetwork,
        endpointIdentifier: String,
        serialization: xpc_object_t,
        ipv4Address: String,
        ipv4Gateway: String,
        macAddress: String,
        mtu: UInt32
    ) {
        self.owner = owner
        self.endpointIdentifier = endpointIdentifier
        self.serialization = serialization
        self.ipv4Address = ipv4Address
        self.ipv4Gateway = ipv4Gateway
        self.macAddress = macAddress
        self.mtu = mtu
    }

    public func close() {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        closed = true
        lock.unlock()
        owner.releaseEndpoint(identifier: endpointIdentifier)
    }

    deinit {
        close()
    }
}
