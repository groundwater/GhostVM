import Foundation

/// Owns one FSKit mount for the lifetime of a container run.
struct GuestVolumeMount: Sendable {
    let exportID: String
    let mountPoint: URL
    let destination: String
    let readOnly: Bool

    enum MountError: Error, LocalizedError {
        case bridgeUnavailable
        case extensionUnavailable
        case mountFailed(String)

        var errorDescription: String? {
            switch self {
            case .bridgeUnavailable:
                return "Guest filesystem bridge is unavailable."
            case .extensionUnavailable:
                return "GhostVM's file system extension is not enabled. Enable it in System Settings > General > Login Items & Extensions > File System Extensions."
            case .mountFailed(let detail):
                return "Failed to mount guest directory through FSKit: \(detail)"
            }
        }
    }

    static func mount(
        registeredExport: GuestFileSystemBridgeService.RegisteredExport,
        destination: String,
        readOnly: Bool,
        rootURL: URL
    ) throws -> Self {
        guard extensionIsEnabled() else { throw MountError.extensionUnavailable }

        let mountPoint = rootURL.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)

        do {
            try run(
                executable: "/sbin/mount",
                arguments: [
                    "-F", "-t", "ghostvm",
                    "-o", "rdonly,nobrowse,nodev,nosuid",
                    registeredExport.resourceURL.absoluteString,
                    mountPoint.path,
                ]
            )
        } catch {
            try? FileManager.default.removeItem(at: mountPoint)
            throw error
        }

        return Self(
            exportID: registeredExport.id,
            mountPoint: mountPoint,
            destination: destination,
            readOnly: readOnly
        )
    }

    func unmount() {
        do {
            try Self.run(executable: "/sbin/umount", arguments: [mountPoint.path])
            try? FileManager.default.removeItem(at: mountPoint)
        } catch {
            NSLog("GuestVolumeMount: failed to unmount %@: %@", mountPoint.path, error.localizedDescription)
        }
    }

    static func extensionIsEnabled() -> Bool {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
        process.arguments = ["-m", "-p", "com.apple.fskit.fsmodule"]
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let text = String(data: data, encoding: .utf8) else { return false }
            return text.contains("org.ghostvm.ghostvm.fs")
        } catch {
            return false
        }
    }

    private static func run(executable: String, arguments: [String]) throws {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
        } catch {
            throw MountError.mountFailed(error.localizedDescription)
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let message = detail.flatMap { $0.isEmpty ? nil : $0 }
                ?? "mount exited with status \(process.terminationStatus)"
            throw MountError.mountFailed(message)
        }
    }
}
