import Foundation
import Virtualization

/// Synchronously load a VZMacOSRestoreImage from a URL.
public func loadRestoreImage(from url: URL) throws -> VZMacOSRestoreImage {
    let semaphore = DispatchSemaphore(value: 0)
    var result: Result<VZMacOSRestoreImage, Error> = .failure(VMError.message("Unknown restore image load error"))
    VZMacOSRestoreImage.load(from: url) { loadResult in
        result = loadResult
        semaphore.signal()
    }
    semaphore.wait()
    return try result.get()
}

/// Discover a restore image from an explicit path or common locations.
public func discoverRestoreImage(explicitPath: String?) throws -> URL {
    let fm = FileManager.default
    if let explicit = explicitPath {
        let url = URL(fileURLWithPath: explicit).standardizedFileURL
        guard fm.fileExists(atPath: url.path) else {
            throw VMError.message("Restore image '\(url.path)' does not exist.")
        }
        return url
    }

    var candidates: [URL] = []
    let home = fm.homeDirectoryForCurrentUser
    let potentialDirectories: [URL] = [
        home.appendingPathComponent("Downloads"),
        URL(fileURLWithPath: "/Applications", isDirectory: true)
    ]

    if let downloadsEnumerator = fm.enumerator(at: potentialDirectories[0], includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
        for case let fileURL as URL in downloadsEnumerator {
            if fileURL.pathExtension.lowercased() == "ipsw" {
                candidates.append(fileURL)
            }
        }
    }

    if let applications = try? fm.contentsOfDirectory(at: potentialDirectories[1], includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles) {
        for app in applications where app.pathExtension == "app" && app.lastPathComponent.lowercased().contains("install macos") {
            let restore = app.appendingPathComponent("Contents/SharedSupport/SharedSupport.dmg")
            if fm.fileExists(atPath: restore.path) {
                candidates.append(restore)
            }
        }
    }

    if let chosen = candidates.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).first {
        return chosen
    }

    throw VMError.message("""
No macOS restore image found. Download one with:
  softwareupdate --fetch-full-installer
Then re-run with --restore-image <path>.
""")
}
