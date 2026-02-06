import Foundation
import vmnet

// vmnet.framework C enum values aren't directly importable in Swift.
private let kVmnetSharedMode: UInt64 = 1001                          // VMNET_SHARED_MODE
private let kVmnetSuccess = vmnet_return_t(rawValue: 1000)!          // VMNET_SUCCESS
private let kVmnetPacketsAvailable = interface_event_t(rawValue: 1)  // VMNET_INTERFACE_PACKETS_AVAILABLE

/// Swift wrapper around vmnet.framework for shared-mode networking.
/// Provides send/receive of raw Ethernet frames via a vmnet interface.
final class VMNetInterface {
    private var interface: interface_ref?
    private var eventQueue: DispatchQueue
    private(set) var maxPacketSize: Int = 1514
    private(set) var gatewayIPv4: UInt32?

    /// Called on eventQueue when frames arrive from the network.
    var onReceive: ((Data) -> Void)?

    init() {
        self.eventQueue = DispatchQueue(label: "ghostvm.vmnet", qos: .userInteractive)
    }

    /// Starts the vmnet interface in shared mode.
    /// Returns the gateway IP (host byte order) on success.
    func start() throws -> UInt32? {
        let xpcDict = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(xpcDict, vmnet_operation_mode_key, kVmnetSharedMode)

        var status = kVmnetSuccess
        let semaphore = DispatchSemaphore(value: 0)

        var iface: interface_ref?
        iface = vmnet_start_interface(xpcDict, eventQueue) { ifaceStatus, interfaceParams in
            status = ifaceStatus
            if ifaceStatus == kVmnetSuccess, let params = interfaceParams {
                // Read max packet size
                if let maxSize = xpc_dictionary_get_value(params, vmnet_max_packet_size_key) {
                    self.maxPacketSize = Int(xpc_uint64_get_value(maxSize))
                }
                // Read start address (gateway) — vmnet assigns the first IP in the range as the gateway
                if let startAddr = xpc_dictionary_get_string(params, vmnet_start_address_key) {
                    self.gatewayIPv4 = self.parseIPv4(String(cString: startAddr))
                }
            }
            semaphore.signal()
        }

        semaphore.wait()

        guard status == kVmnetSuccess, let ref = iface else {
            throw VMNetError.startFailed(status: status)
        }

        self.interface = ref

        // Set up receive callback
        vmnet_interface_set_event_callback(ref, kVmnetPacketsAvailable, eventQueue) { [weak self] _, _ in
            self?.readPackets()
        }

        return gatewayIPv4
    }

    /// Sends a single Ethernet frame to the network.
    func send(frame: Data) {
        guard let iface = interface else { return }

        frame.withUnsafeBytes { (rawBuf: UnsafeRawBufferPointer) in
            guard let baseAddress = rawBuf.baseAddress else { return }
            var iov = iovec(iov_base: UnsafeMutableRawPointer(mutating: baseAddress), iov_len: frame.count)
            withUnsafeMutablePointer(to: &iov) { iovPtr in
                var packet = vmpktdesc(vm_pkt_size: frame.count, vm_pkt_iov: iovPtr, vm_pkt_iovcnt: 1, vm_flags: 0)
                var pktCount: Int32 = 1
                withUnsafeMutablePointer(to: &packet) { pktPtr in
                    vmnet_write(iface, pktPtr, &pktCount)
                }
            }
        }
    }

    /// Stops the vmnet interface.
    func stop() {
        guard let iface = interface else { return }
        let semaphore = DispatchSemaphore(value: 0)
        vmnet_stop_interface(iface, eventQueue) { _ in
            semaphore.signal()
        }
        semaphore.wait()
        interface = nil
    }

    // MARK: - Private

    private func readPackets() {
        guard let iface = interface else { return }

        let maxPkts = 64
        let bufSize = maxPacketSize

        // Allocate buffers
        var buffers = [UnsafeMutableRawPointer]()
        for _ in 0..<maxPkts {
            buffers.append(UnsafeMutableRawPointer.allocate(byteCount: bufSize, alignment: 1))
        }

        // Build iovec + vmpktdesc arrays
        var iovecs = buffers.map { iovec(iov_base: $0, iov_len: bufSize) }

        var packets = [vmpktdesc]()
        for i in 0..<maxPkts {
            packets.append(vmpktdesc(vm_pkt_size: bufSize, vm_pkt_iov: &iovecs[i], vm_pkt_iovcnt: 1, vm_flags: 0))
        }

        var pktCount: Int32 = Int32(maxPkts)
        let status = packets.withUnsafeMutableBufferPointer { pktsBuf -> vmnet_return_t in
            return vmnet_read(iface, pktsBuf.baseAddress!, &pktCount)
        }

        if status == kVmnetSuccess {
            for i in 0..<Int(pktCount) {
                let size = packets[i].vm_pkt_size
                let data = Data(bytes: buffers[i], count: size)
                onReceive?(data)
            }
        }

        for buf in buffers {
            buf.deallocate()
        }
    }

    private func parseIPv4(_ str: String) -> UInt32? {
        let parts = str.split(separator: ".").compactMap { UInt32($0) }
        guard parts.count == 4 else { return nil }
        return (parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3]
    }

    deinit {
        stop()
    }
}

enum VMNetError: Error, CustomStringConvertible {
    case startFailed(status: vmnet_return_t)

    var description: String {
        switch self {
        case .startFailed(let status):
            return "vmnet_start_interface failed with status \(status.rawValue)"
        }
    }
}
