import Foundation

/// Represents a listening port with associated process information
struct ListeningPort: Codable, Equatable {
    let port: UInt16
    let process: String
}

/// Service for detecting TCP ports listening on localhost
final class PortScanner: @unchecked Sendable {
    static let shared = PortScanner()

    private init() {}

    /// Get all TCP ports currently listening on localhost
    /// Uses lsof to detect listening processes
    func getListeningPorts() -> [ListeningPort] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-iTCP", "-sTCP:LISTEN", "-n", "-P"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            print("[PortScanner] Failed to run lsof: \(error)")
            return []
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else {
            return []
        }

        return parseLsofOutput(output)
    }

    /// Check if a specific port is currently listening
    func isPortListening(_ port: UInt16) -> Bool {
        let ports = getListeningPorts()
        return ports.contains { $0.port == port }
    }

    /// Parse lsof output into ListeningPort objects
    /// lsof output format:
    /// COMMAND     PID   USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
    /// node      12345  user   22u  IPv4 0x...             0t0  TCP *:3000 (LISTEN)
    private func parseLsofOutput(_ output: String) -> [ListeningPort] {
        var ports: [ListeningPort] = []
        var seenPorts = Set<UInt16>()

        let lines = output.components(separatedBy: "\n")

        for line in lines.dropFirst() { // Skip header line
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            // Split by whitespace
            let parts = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }

            // Need at least COMMAND and NAME columns
            guard parts.count >= 9 else { continue }

            let command = parts[0]
            let name = parts[8]

            // Parse port from NAME column (e.g., "*:3000" or "localhost:3000" or "127.0.0.1:3000")
            if let port = parsePortFromName(name) {
                // Avoid duplicates
                if !seenPorts.contains(port) {
                    seenPorts.insert(port)
                    ports.append(ListeningPort(port: port, process: command))
                }
            }
        }

        return ports.sorted { $0.port < $1.port }
    }

    /// Parse port number from lsof NAME column
    /// Examples: "*:3000", "localhost:3000", "127.0.0.1:3000", "[::1]:3000"
    private func parsePortFromName(_ name: String) -> UInt16? {
        // Find the last colon and extract port number
        guard let colonIndex = name.lastIndex(of: ":") else {
            return nil
        }

        let portString = String(name[name.index(after: colonIndex)...])

        // Remove any trailing info like " (LISTEN)"
        let cleanPort = portString.components(separatedBy: " ")[0]

        return UInt16(cleanPort)
    }
}

// MARK: - Response Types

/// Response for GET /api/v1/ports endpoint
struct PortListResponse: Codable {
    let ports: [ListeningPort]
}
