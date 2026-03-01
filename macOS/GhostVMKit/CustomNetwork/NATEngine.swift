import Foundation
import Network

// MARK: - NAT Entry

public struct NATEntry {
    public let proto: UInt8
    public let originalSrcIP: IPv4Address
    public let originalSrcPort: UInt16
    public let dstIP: IPv4Address
    public let dstPort: UInt16
    public let mappedPort: UInt16
    public var lastActivity: Date
    public var connection: NWConnection?

    /// TCP state for connection lifecycle management.
    public enum TCPState {
        case synSent
        case established
        case finWait
        case closed
    }
    public var tcpState: TCPState?
}

// MARK: - NAT Key

private struct NATKey: Hashable {
    let proto: UInt8
    let srcIP: IPv4Address
    let srcPort: UInt16
    let dstIP: IPv4Address
    let dstPort: UInt16
}

private struct ReverseNATKey: Hashable {
    let proto: UInt8
    let mappedPort: UInt16
}

// MARK: - NATEngine

public final class NATEngine {
    private var forwardTable: [NATKey: NATEntry] = [:]
    private var reverseTable: [ReverseNATKey: NATKey] = [:]
    private var nextPort: UInt16 = 10000
    private let portRangeStart: UInt16 = 10000
    private let portRangeEnd: UInt16 = 60000
    private let udpTimeout: TimeInterval
    private let lock = NSLock()
    private var cleanupTimer: DispatchSourceTimer?

    public init(udpTimeout: TimeInterval = 60) {
        self.udpTimeout = udpTimeout
    }

    /// Start periodic cleanup of expired entries.
    public func startCleanup(queue: DispatchQueue) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self] in
            self?.purgeExpired()
        }
        timer.resume()
        cleanupTimer = timer
    }

    /// Stop the cleanup timer.
    public func stop() {
        cleanupTimer?.cancel()
        cleanupTimer = nil
        lock.lock()
        // Close all connections
        for (_, entry) in forwardTable {
            entry.connection?.cancel()
        }
        forwardTable.removeAll()
        reverseTable.removeAll()
        lock.unlock()
    }

    /// Look up or create a NAT mapping for an outbound packet.
    /// Returns the allocated ephemeral port, or nil if the table is full.
    public func outboundMapping(proto: UInt8, srcIP: IPv4Address, srcPort: UInt16,
                                dstIP: IPv4Address, dstPort: UInt16) -> NATEntry? {
        let key = NATKey(proto: proto, srcIP: srcIP, srcPort: srcPort, dstIP: dstIP, dstPort: dstPort)

        lock.lock()
        if var existing = forwardTable[key] {
            existing.lastActivity = Date()
            forwardTable[key] = existing
            lock.unlock()
            return existing
        }

        // Allocate new ephemeral port
        guard let port = allocatePort() else {
            lock.unlock()
            return nil
        }

        var entry = NATEntry(proto: proto, originalSrcIP: srcIP, originalSrcPort: srcPort,
                             dstIP: dstIP, dstPort: dstPort, mappedPort: port,
                             lastActivity: Date(), connection: nil,
                             tcpState: proto == IPProto.tcp ? .synSent : nil)
        forwardTable[key] = entry
        reverseTable[ReverseNATKey(proto: proto, mappedPort: port)] = key
        lock.unlock()

        return entry
    }

    /// Look up a NAT entry by reverse (inbound) mapping.
    public func inboundLookup(proto: UInt8, mappedPort: UInt16) -> NATEntry? {
        let rkey = ReverseNATKey(proto: proto, mappedPort: mappedPort)
        lock.lock()
        guard let fkey = reverseTable[rkey], let entry = forwardTable[fkey] else {
            lock.unlock()
            return nil
        }
        lock.unlock()
        return entry
    }

    /// Store the NWConnection for a NAT entry.
    public func setConnection(proto: UInt8, srcIP: IPv4Address, srcPort: UInt16,
                              dstIP: IPv4Address, dstPort: UInt16, connection: NWConnection) {
        let key = NATKey(proto: proto, srcIP: srcIP, srcPort: srcPort, dstIP: dstIP, dstPort: dstPort)
        lock.lock()
        forwardTable[key]?.connection = connection
        lock.unlock()
    }

    /// Update TCP state for a NAT entry.
    public func updateTCPState(proto: UInt8, srcIP: IPv4Address, srcPort: UInt16,
                               dstIP: IPv4Address, dstPort: UInt16, flags: UInt8) {
        guard proto == IPProto.tcp else { return }
        let key = NATKey(proto: proto, srcIP: srcIP, srcPort: srcPort, dstIP: dstIP, dstPort: dstPort)
        lock.lock()
        guard var entry = forwardTable[key] else { lock.unlock(); return }

        if flags & TCPHeader.RST != 0 {
            entry.tcpState = .closed
        } else if flags & TCPHeader.FIN != 0 {
            entry.tcpState = .finWait
        } else if flags & TCPHeader.ACK != 0 && entry.tcpState == .synSent {
            entry.tcpState = .established
        }

        entry.lastActivity = Date()
        forwardTable[key] = entry
        lock.unlock()
    }

    /// Remove a specific NAT entry and cancel its connection.
    public func removeEntry(proto: UInt8, srcIP: IPv4Address, srcPort: UInt16,
                            dstIP: IPv4Address, dstPort: UInt16) {
        let key = NATKey(proto: proto, srcIP: srcIP, srcPort: srcPort, dstIP: dstIP, dstPort: dstPort)
        lock.lock()
        if let entry = forwardTable.removeValue(forKey: key) {
            reverseTable.removeValue(forKey: ReverseNATKey(proto: proto, mappedPort: entry.mappedPort))
            entry.connection?.cancel()
        }
        lock.unlock()
    }

    /// Current number of active entries.
    public var entryCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return forwardTable.count
    }

    // MARK: - Private

    private func allocatePort() -> UInt16? {
        let range = portRangeEnd - portRangeStart
        let usedPorts = Set(forwardTable.values.map { $0.mappedPort })

        for _ in 0..<range {
            let port = nextPort
            nextPort = nextPort >= portRangeEnd ? portRangeStart : nextPort + 1
            if !usedPorts.contains(port) {
                return port
            }
        }
        return nil // all ports used
    }

    private func purgeExpired() {
        let now = Date()
        lock.lock()
        var keysToRemove: [NATKey] = []

        for (key, entry) in forwardTable {
            let shouldRemove: Bool
            if entry.proto == IPProto.udp {
                shouldRemove = now.timeIntervalSince(entry.lastActivity) > udpTimeout
            } else if entry.proto == IPProto.tcp {
                shouldRemove = entry.tcpState == .closed ||
                    (entry.tcpState == .finWait && now.timeIntervalSince(entry.lastActivity) > 30)
            } else {
                shouldRemove = now.timeIntervalSince(entry.lastActivity) > udpTimeout
            }

            if shouldRemove {
                keysToRemove.append(key)
            }
        }

        for key in keysToRemove {
            if let entry = forwardTable.removeValue(forKey: key) {
                reverseTable.removeValue(forKey: ReverseNATKey(proto: entry.proto, mappedPort: entry.mappedPort))
                entry.connection?.cancel()
            }
        }
        lock.unlock()
    }
}
