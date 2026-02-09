import Foundation
import Darwin

/// Response model for port list endpoint
struct PortListResponse: Codable {
    let ports: [Int]
}

/// Response model for port forward requests
struct PortForwardResponse: Codable {
    let ports: [Int]
}

/// A listening port with the name of the process that owns it.
struct PortInfo {
    let port: Int
    let process: String
}

/// Scans for listening TCP ports using libproc.
final class PortScanner {
    static let shared = PortScanner()

    /// Minimum port to report (skip well-known/system ports)
    var minimumPort: UInt16 = 1025

    private init() {}

    /// Returns a sorted, deduplicated list of TCP ports in LISTEN state.
    func getListeningPorts() -> [Int] {
        return getListeningPortsWithProcess().map { $0.port }
    }

    /// Resolve a process name for a given PID.
    /// Tries proc_name() first, falls back to proc_pidpath() (last path component).
    private static func processName(forPid pid: pid_t) -> String {
        // Try proc_name first (returns p_comm, up to MAXCOMLEN chars)
        var nameBuffer = [CChar](repeating: 0, count: Int(MAXCOMLEN) + 1)
        let nameLen = proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
        if nameLen > 0 {
            let name = String(cString: nameBuffer)
            if !name.isEmpty {
                return name
            }
        }
        // Fallback: proc_pidpath gives full executable path
        var pathBuffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let pathLen = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        if pathLen > 0 {
            let path = String(cString: pathBuffer)
            let lastComponent = (path as NSString).lastPathComponent
            if !lastComponent.isEmpty {
                print("[PortScanner] proc_name failed but proc_pidpath succeeded for pid \(pid): \(lastComponent)")
                return lastComponent
            }
        }
        return ""
    }

    /// Returns listening ports with the process name that owns each socket.
    func getListeningPortsWithProcess() -> [PortInfo] {
        // 1. Get all PIDs
        var pidCount = proc_listallpids(nil, 0)
        guard pidCount > 0 else { return [] }

        var pids = [pid_t](repeating: 0, count: Int(pidCount))
        pidCount = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard pidCount > 0 else { return [] }

        // port → process name (first PID wins for dedup)
        var portProcessMap: [UInt16: String] = [:]

        for i in 0..<Int(pidCount) {
            let pid = pids[i]
            guard pid > 0 else { continue }

            // 2. Get FD list for this PID
            let fdBufferSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
            guard fdBufferSize > 0 else { continue }

            let fdCount = fdBufferSize / Int32(MemoryLayout<proc_fdinfo>.size)
            var fdInfos = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(fdCount))
            let actualSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fdInfos, fdBufferSize)
            guard actualSize > 0 else { continue }

            let actualCount = Int(actualSize) / MemoryLayout<proc_fdinfo>.size

            for j in 0..<actualCount {
                let fdInfo = fdInfos[j]
                // Only care about socket FDs
                guard fdInfo.proc_fdtype == PROX_FDTYPE_SOCKET else { continue }

                // 3. Get socket info for this FD
                var socketInfo = socket_fdinfo()
                let socketInfoSize = proc_pidfdinfo(
                    pid,
                    fdInfo.proc_fd,
                    PROC_PIDFDSOCKETINFO,
                    &socketInfo,
                    Int32(MemoryLayout<socket_fdinfo>.size)
                )
                guard socketInfoSize == MemoryLayout<socket_fdinfo>.size else { continue }

                let si = socketInfo.psi

                // Filter: TCP sockets only
                guard si.soi_kind == SOCKINFO_TCP else { continue }

                // Filter: LISTEN state only (TSI_S_LISTEN = 1)
                let tcpInfo = si.soi_proto.pri_tcp
                guard tcpInfo.tcpsi_state == TSI_S_LISTEN else { continue }

                // Get the local port (network byte order)
                let insi = si.soi_proto.pri_tcp.tcpsi_ini
                let rawPort = insi.insi_lport
                let port = UInt16(bigEndian: UInt16(rawPort))

                guard port >= minimumPort else { continue }

                if portProcessMap[port] == nil {
                    let name = Self.processName(forPid: pid)
                    if name.isEmpty {
                        print("[PortScanner] WARNING: could not resolve process name for pid \(pid) port \(port)")
                    }
                    portProcessMap[port] = name
                }
            }
        }

        return portProcessMap.keys.sorted().map { port in
            PortInfo(port: Int(port), process: portProcessMap[port] ?? "")
        }
    }
}

/// Stub for port forward request service - feature removed
/// Kept for API compatibility, returns empty results
final class PortForwardRequestService {
    static let shared = PortForwardRequestService()
    private init() {}

    func popRequests() -> [Int] {
        // Dynamic port forwarding removed - uses explicit config now
        return []
    }
}
