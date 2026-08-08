import Foundation

/// Owns one FSKit mount for the lifetime of a container run.
struct GuestVolumeMount: Sendable {
    let exportID: String
    let mountPoint: URL
    let destination: String
    let readOnly: Bool

    enum MountError: Error, LocalizedError {
        case bridgeUnavailable
        case mountFailed(String)

        var errorDescription: String? {
            switch self {
            case .bridgeUnavailable:
                return "Guest filesystem bridge is unavailable."
            case .mountFailed(let detail):
                return "Outer-host FSKit mount failed: \(detail) Nothing needs to be installed in this VM; check GhostVMFS in GhostVM on the outer Mac."
            }
        }
    }

    static func mount(
        registeredExport: GuestFileSystemBridgeService.RegisteredExport,
        destination: String,
        readOnly: Bool
    ) throws -> Self {
        let mountPoint = try PrivateGuestMountDirectory.create()

        do {
            let mountOptions = readOnly ? "rdonly,nobrowse,nodev,nosuid" : "nobrowse,nodev,nosuid"
            try run(
                executable: "/sbin/mount",
                arguments: [
                    "-F", "-t", "ghostvm",
                    "-o", mountOptions,
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
