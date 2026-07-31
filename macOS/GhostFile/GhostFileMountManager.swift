import AppKit
import Foundation
import FSKit

struct MountedGhostFileShare: Identifiable, Equatable {
    let id: UUID
    let name: String
    let sourceURL: URL
    let mountPoint: URL
}

@MainActor
final class GhostFileMountManager: ObservableObject {
    @Published private(set) var mountedShares: [MountedGhostFileShare] = []
    @Published private(set) var extensionEnabled: Bool?
    @Published var errorMessage: String?
    @Published private(set) var isWorking = false

    func refreshExtensionStatus() async {
        do {
            let modules = try await FSClient.shared.installedExtensions
            extensionEnabled = modules.contains {
                $0.bundleIdentifier == "org.ghostvm.ghostfile.fs" && $0.isEnabled
            }
        } catch {
            extensionEnabled = false
            errorMessage = "Unable to inspect FSKit extensions: \(error.localizedDescription)"
        }
    }

    func mount(url: URL, accessKey: String, volumeName: String) async {
        guard !accessKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "Enter the share's access key."
            return
        }
        guard url.scheme == GhostFileProtocol.urlScheme else {
            errorMessage = "GhostFile share URLs must use ghostfile://."
            return
        }
        guard extensionEnabled == true else {
            errorMessage = "Enable the GhostFile file system extension in System Settings first."
            return
        }

        isWorking = true
        defer { isWorking = false }
        do {
            var resourceComponents = URLComponents(url: url, resolvingAgainstBaseURL: false)
            var queryItems = resourceComponents?.queryItems ?? []
            queryItems.removeAll { $0.name == "access_key" }
            queryItems.append(URLQueryItem(name: "access_key", value: accessKey))
            resourceComponents?.queryItems = queryItems
            guard let resourceURL = resourceComponents?.url else {
                throw MountFailure("Invalid share URL")
            }

            let mountRoot = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("GhostFile Mounts", isDirectory: true)
            try FileManager.default.createDirectory(at: mountRoot, withIntermediateDirectories: true)
            let safeName = sanitizedVolumeName(volumeName)
            let mountPoint = uniqueMountPoint(root: mountRoot, name: safeName)
            try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: false)

            do {
                try await Task.detached(priority: .userInitiated) {
                    try Self.run(
                        executable: "/sbin/mount",
                        arguments: [
                            "-F", "-t", "ghostfile",
                            "-o", "rdonly,nobrowse,nodev,nosuid",
                            resourceURL.absoluteString,
                            mountPoint.path,
                        ]
                    )
                }.value
            } catch {
                try? FileManager.default.removeItem(at: mountPoint)
                throw error
            }

            mountedShares.append(.init(
                id: UUID(),
                name: volumeName,
                sourceURL: url,
                mountPoint: mountPoint
            ))
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func unmount(_ mountedShare: MountedGhostFileShare) async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await Task.detached(priority: .userInitiated) {
                try Self.run(executable: "/sbin/umount", arguments: [mountedShare.mountPoint.path])
            }.value
            try? FileManager.default.removeItem(at: mountedShare.mountPoint)
            mountedShares.removeAll { $0.id == mountedShare.id }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func reveal(_ mountedShare: MountedGhostFileShare) {
        NSWorkspace.shared.activateFileViewerSelecting([mountedShare.mountPoint])
    }

    func openExtensionSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    private func sanitizedVolumeName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = trimmed.isEmpty ? "GhostFile Share" : trimmed
        let sanitized = source.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: "\0", with: "")
        return String(sanitized.prefix(80))
    }

    private func uniqueMountPoint(root: URL, name: String) -> URL {
        var candidate = root.appendingPathComponent(name, isDirectory: true)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = root.appendingPathComponent("\(name) \(suffix)", isDirectory: true)
            suffix += 1
        }
        return candidate
    }

    nonisolated private static func run(executable: String, arguments: [String]) throws {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw MountFailure(detail?.isEmpty == false ? detail! : "mount exited with status \(process.terminationStatus)")
        }
    }

    private struct MountFailure: LocalizedError {
        let detail: String
        init(_ detail: String) { self.detail = detail }
        var errorDescription: String? { detail }
    }
}
