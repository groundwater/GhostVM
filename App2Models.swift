import Foundation

// Lightweight view model for a real .GhostVM bundle on disk.
struct App2VM: Identifiable, Hashable, Codable {
    let id: UUID
    var name: String
    var bundlePath: String
    var osVersion: String
    var status: String

    var bundleURL: URL {
        URL(fileURLWithPath: bundlePath).standardizedFileURL
    }
}

// Subset of the stored config we need to run an existing VM.
struct App2StoredConfig: Codable {
    var cpus: Int
    var memoryBytes: UInt64
    var diskBytes: UInt64
    var hardwareModelPath: String
    var machineIdentifierPath: String
    var auxiliaryStoragePath: String
    var diskPath: String
    var sharedFolderPath: String?
    var sharedFolderReadOnly: Bool
    var installed: Bool
    var lastInstallVersion: String?

    enum CodingKeys: String, CodingKey {
        case cpus
        case memoryBytes
        case diskBytes
        case hardwareModelPath
        case machineIdentifierPath
        case auxiliaryStoragePath
        case diskPath
        case sharedFolderPath
        case sharedFolderReadOnly
        case installed
        case lastInstallVersion
    }
}

// Resolves paths that may be stored as relative filenames inside the bundle
// or as absolute paths on disk.
struct App2BundleLayout {
    let bundleURL: URL

    var configURL: URL { bundleURL.appendingPathComponent("config.json") }

    func resolve(path stored: String) -> URL {
        let expanded = (stored as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded).standardizedFileURL
        }
        return bundleURL.appendingPathComponent(expanded)
    }
}

final class App2VMStore: ObservableObject {
    @Published var vms: [App2VM] = []

    private let fileManager = FileManager.default

    init() {
        reloadDefaultDirectory()
    }

    func reloadDefaultDirectory() {
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
        for url in contents where url.pathExtension.lowercased() == "ghostvm" {
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
            if url.pathExtension.lowercased() == "ghostvm" {
                bundleURL = url
            } else if url.pathExtension.isEmpty {
                // If a plain directory is dropped, treat it as a bundle only if it has the right suffix.
                if url.lastPathComponent.lowercased().hasSuffix(".ghostvm") {
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
            updated.append(vm)
            seenPaths.insert(path)
        }

        updated.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        vms = updated
    }

    func updateStatus(for vmID: App2VM.ID, status: String) {
        guard let index = vms.firstIndex(where: { $0.id == vmID }) else { return }
        vms[index].status = status
    }

    func vm(for bundlePath: String) -> App2VM? {
        let standardized = URL(fileURLWithPath: bundlePath).standardizedFileURL.path
        return vms.first { $0.bundleURL.path == standardized }
    }

    private func loadVM(from bundleURL: URL) throws -> App2VM {
        let layout = App2BundleLayout(bundleURL: bundleURL.standardizedFileURL)
        let data = try Data(contentsOf: layout.configURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let stored = try decoder.decode(App2StoredConfig.self, from: data)

        let name = bundleURL.deletingPathExtension().lastPathComponent
        let osVersion: String
        if let version = stored.lastInstallVersion {
            osVersion = "macOS \(version)"
        } else if stored.installed {
            osVersion = "Installed"
        } else {
            osVersion = "Not Installed"
        }

        return App2VM(
            id: UUID(),
            name: name,
            bundlePath: bundleURL.path,
            osVersion: osVersion,
            status: stored.installed ? "Stopped" : "Not Installed"
        )
    }
}

