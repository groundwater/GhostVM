import Foundation
import GhostVMKit

// Lightweight view model for a real .GhostVM bundle on disk.
struct App2VM: Identifiable, Hashable, Codable {
    let id: UUID
    var name: String
    var bundlePath: String
    var osVersion: String
    var status: String
    var installed: Bool

    var bundleURL: URL {
        URL(fileURLWithPath: bundlePath).standardizedFileURL
    }

    var needsInstall: Bool {
        !installed
    }
}

final class App2VMStore: ObservableObject {
    @Published var vms: [App2VM] = []

    private let defaults = UserDefaults.standard
    private let fileManager = FileManager.default
    private let knownBundlesKey = "SwiftUIKnownVMBundles"
    private let controller = VMController()

    init() {
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            if ProcessInfo.processInfo.arguments.contains("--ui-testing-with-vms") {
                vms = Self.mockVMs
            } else {
                vms = []
            }
        } else {
            loadKnownVMs()
        }
    }

    private static let mockVMs: [App2VM] = [
        App2VM(id: UUID(), name: "macOS Sequoia", bundlePath: "/tmp/mock/macOS-Sequoia.GhostVM", osVersion: "macOS 15.2", status: "Running", installed: true),
        App2VM(id: UUID(), name: "macOS Dev", bundlePath: "/tmp/mock/macOS-Dev.GhostVM", osVersion: "macOS 15.4 Beta", status: "Stopped", installed: true),
        App2VM(id: UUID(), name: "macOS Sonoma", bundlePath: "/tmp/mock/macOS-Sonoma.GhostVM", osVersion: "macOS 14.7", status: "Suspended", installed: true),
    ]

    func reloadDefaultDirectory() {
        // Legacy helper retained for debugging.
        let home = fileManager.homeDirectoryForCurrentUser
        let root = home.appendingPathComponent("VMs", isDirectory: true)
        guard fileManager.fileExists(atPath: root.path) else {
            vms = []
            return
        }

        guard let contents = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        var discovered: [App2VM] = []
        for url in contents {
            let ext = url.pathExtension.lowercased()
            guard ext == "ghostvm" else { continue }
            if let vm = try? loadVM(from: url) {
                discovered.append(vm)
            }
        }

        discovered.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        vms = discovered
    }

    func addBundles(from urls: [URL]) {
        var updated = vms
        var seenPaths = Set(updated.map { $0.bundleURL.path })

        for rawURL in urls {
            let url = rawURL.standardizedFileURL
            let bundleURL: URL
            let ext = url.pathExtension.lowercased()
            if ext == "ghostvm" {
                bundleURL = url
            } else if ext.isEmpty {
                // If a plain directory is dropped, treat it as a bundle only if it has the right suffix.
                let name = url.lastPathComponent.lowercased()
                if name.hasSuffix(".ghostvm") {
                    bundleURL = url
                } else {
                    continue
                }
            } else {
                continue
            }

            let path = bundleURL.path
            guard !seenPaths.contains(path) else { continue }
            guard let vm = try? loadVM(from: bundleURL) else { continue }

            // Treat drops of a renamed bundle as updates when they refer to
            // the same underlying directory on disk (same fileResourceIdentifier),
            // otherwise append as a new entry.
            var updatedExisting = false
            if let newID = (try? bundleURL.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier) as? NSData {
                if let existingIndex = updated.firstIndex(where: { existing in
                    guard let existingID = (try? existing.bundleURL.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier) as? NSData else {
                        return false
                    }
                    return existingID.isEqual(newID) && existing.bundleURL.path != bundleURL.path
                }) {
                    updated[existingIndex] = vm
                    updatedExisting = true
                }
            }

            if !updatedExisting {
                updated.append(vm)
            }

            seenPaths.insert(path)
        }

        updated.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        vms = updated
        persistKnownVMs()
    }

    func updateStatus(for vmID: App2VM.ID, status: String) {
        guard let index = vms.firstIndex(where: { $0.id == vmID }) else { return }
        vms[index].status = status
    }

    func reloadVM(at bundleURL: URL) {
        let standardized = bundleURL.standardizedFileURL
        guard let index = vms.firstIndex(where: { $0.bundleURL.path == standardized.path }) else { return }
        guard let reloaded = try? loadVM(from: standardized) else { return }
        // Preserve the existing ID to maintain SwiftUI identity
        var updated = reloaded
        updated = App2VM(
            id: vms[index].id,
            name: reloaded.name,
            bundlePath: reloaded.bundlePath,
            osVersion: reloaded.osVersion,
            status: reloaded.status,
            installed: reloaded.installed
        )
        vms[index] = updated
    }

    func removeFromList(_ vm: App2VM) {
        vms.removeAll { $0.id == vm.id }
        persistKnownVMs()
    }

    func deleteVM(_ vm: App2VM) {
        let url = vm.bundleURL
        let lowercasedStatus = vm.status.lowercased()
        let isBusy = lowercasedStatus.contains("running") ||
                     lowercasedStatus.contains("starting") ||
                     lowercasedStatus.contains("stopping")
        guard !isBusy else { return }

        do {
            try controller.moveVMToTrash(bundleURL: url)
        } catch {
            print("Failed to move VM bundle to Trash: \(error)")
        }

        removeFromList(vm)
    }

    func vm(for bundlePath: String) -> App2VM? {
        let standardized = URL(fileURLWithPath: bundlePath).standardizedFileURL.path
        return vms.first { $0.bundleURL.path == standardized }
    }

    // MARK: - Persistence

    private func loadKnownVMs() {
        guard let stored = defaults.array(forKey: knownBundlesKey) as? [String], !stored.isEmpty else {
            vms = []
            return
        }

        var discovered: [App2VM] = []
        var runningVMs: [(App2VM, pid_t)] = []
        for path in stored {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            if fileManager.fileExists(atPath: url.path),
               let (vm, pid) = try? loadVMWithPID(from: url) {
                discovered.append(vm)
                if let pid = pid {
                    runningVMs.append((vm, pid))
                }
            }
        }

        discovered.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        vms = discovered

        // Reconnect to helpers that are still running from before the app quit
        for (vm, pid) in runningVMs {
            App2VMSessionRegistry.shared.startVM(
                bundleURL: vm.bundleURL,
                store: self,
                vmID: vm.id,
                runningPID: pid
            )
        }
    }

    private func persistKnownVMs() {
        let paths = vms.map { $0.bundleURL.path }
        defaults.set(paths, forKey: knownBundlesKey)
    }

    private func loadVM(from bundleURL: URL) throws -> App2VM {
        let (vm, _) = try loadVMWithPID(from: bundleURL)
        return vm
    }

    private func loadVMWithPID(from bundleURL: URL) throws -> (App2VM, pid_t?) {
        // Use framework's VMController to load entry
        let entry = try controller.loadEntry(for: bundleURL)

        let osVersion: String
        if let version = entry.lastInstallVersion {
            osVersion = "macOS \(version)"
        } else if entry.installed {
            osVersion = "Installed"
        } else {
            osVersion = "Not Installed"
        }

        let vm = App2VM(
            id: UUID(),
            name: entry.name,
            bundlePath: bundleURL.path,
            osVersion: osVersion,
            status: entry.statusDescription,
            installed: entry.installed
        )
        return (vm, entry.runningPID)
    }
}
