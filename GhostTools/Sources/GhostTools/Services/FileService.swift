import Foundation

/// Service for managing file transfer operations between host and guest
final class FileService {
    static let shared = FileService()

    /// Base directory for received files
    private let receiveDirectory: URL

    private init() {
        // Use Downloads folder for received files
        receiveDirectory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
            .appendingPathComponent("GhostTools", isDirectory: true)

        // Ensure receive directory exists
        try? FileManager.default.createDirectory(at: receiveDirectory, withIntermediateDirectories: true)
    }

    /// Receives a file from the host and saves it to the receive directory
    /// - Parameters:
    ///   - data: The file data
    ///   - filename: The filename to save as
    /// - Returns: The URL where the file was saved
    func receiveFile(data: Data, filename: String) throws -> URL {
        // Sanitize filename to prevent path traversal
        let sanitizedFilename = sanitizeFilename(filename)
        let destinationURL = receiveDirectory.appendingPathComponent(sanitizedFilename)

        // Handle filename conflicts
        let finalURL = uniqueURL(for: destinationURL)

        try data.write(to: finalURL)
        return finalURL
    }

    /// Reads a file from the specified path
    /// - Parameter path: The file path to read (relative paths are resolved from home directory)
    /// - Returns: The file data and filename
    func readFile(at path: String) throws -> (data: Data, filename: String) {
        let url = resolveFilePath(path)

        // Security check: ensure we're not accessing sensitive system files
        guard isPathAllowed(url) else {
            throw FileServiceError.accessDenied
        }

        let data = try Data(contentsOf: url)
        let filename = url.lastPathComponent

        return (data, filename)
    }

    /// Lists files in the receive directory
    func listReceivedFiles() -> [String] {
        let contents = try? FileManager.default.contentsOfDirectory(atPath: receiveDirectory.path)
        return contents ?? []
    }

    // MARK: - Private Helpers

    private func sanitizeFilename(_ filename: String) -> String {
        // Remove path components and dangerous characters
        let name = (filename as NSString).lastPathComponent
        let sanitized = name.replacingOccurrences(of: "..", with: "_")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")

        return sanitized.isEmpty ? "unnamed" : sanitized
    }

    private func uniqueURL(for url: URL) -> URL {
        var finalURL = url
        var counter = 1

        while FileManager.default.fileExists(atPath: finalURL.path) {
            let filename = url.deletingPathExtension().lastPathComponent
            let ext = url.pathExtension

            let newFilename: String
            if ext.isEmpty {
                newFilename = "\(filename)_\(counter)"
            } else {
                newFilename = "\(filename)_\(counter).\(ext)"
            }

            finalURL = url.deletingLastPathComponent().appendingPathComponent(newFilename)
            counter += 1
        }

        return finalURL
    }

    private func resolveFilePath(_ path: String) -> URL {
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path)
        } else if path.hasPrefix("~") {
            let expanded = NSString(string: path).expandingTildeInPath
            return URL(fileURLWithPath: expanded)
        } else {
            // Relative to home directory
            return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(path)
        }
    }

    private func isPathAllowed(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path

        // Block sensitive system directories
        let blockedPrefixes = [
            "/System",
            "/Library/Keychains",
            "/private/var",
            "/etc/passwd",
            "/etc/shadow"
        ]

        for prefix in blockedPrefixes {
            if path.hasPrefix(prefix) {
                return false
            }
        }

        return true
    }
}

enum FileServiceError: Error, LocalizedError {
    case accessDenied
    case fileNotFound
    case invalidPath

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "Access to this path is not allowed"
        case .fileNotFound:
            return "File not found"
        case .invalidPath:
            return "Invalid file path"
        }
    }
}
