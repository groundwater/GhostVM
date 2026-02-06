import Foundation

/// Service for managing file transfer operations between host and guest
final class FileService {
    static let shared = FileService()

    /// Base directory for received files
    private let receiveDirectory: URL

    /// Files queued for sending to host
    private var outgoingFiles: [URL] = []

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
    ///   - filename: The filename or relative path to save as (e.g., "folder/subfolder/file.txt")
    /// - Returns: The URL where the file was saved
    func receiveFile(data: Data, filename: String) throws -> URL {
        // Sanitize path to prevent path traversal while preserving folder structure
        let sanitizedPath = sanitizeRelativePath(filename)
        print("[FileService] Receiving: '\(filename)' -> sanitized: '\(sanitizedPath)'")

        let destinationURL = receiveDirectory.appendingPathComponent(sanitizedPath)
        print("[FileService] Destination: \(destinationURL.path)")

        // Create intermediate directories if needed
        let parentDirectory = destinationURL.deletingLastPathComponent()
        print("[FileService] Creating directory: \(parentDirectory.path)")
        try FileManager.default.createDirectory(at: parentDirectory, withIntermediateDirectories: true)

        // Handle filename conflicts
        let finalURL = uniqueURL(for: destinationURL)
        print("[FileService] Final URL: \(finalURL.path)")

        try data.write(to: finalURL)
        print("[FileService] File written successfully")
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

    /// Lists files queued for sending to host (full paths)
    func listOutgoingFiles() -> [String] {
        return outgoingFiles.map { $0.path }
    }

    /// Queue a file for sending to host
    func queueOutgoingFile(_ url: URL) {
        if !outgoingFiles.contains(url) {
            outgoingFiles.append(url)
            EventPushServer.shared.pushEvent(.files(listOutgoingFiles()))
        }
    }

    /// Queue multiple files for sending to host
    func queueOutgoingFiles(_ urls: [URL]) {
        for url in urls {
            if !outgoingFiles.contains(url) {
                outgoingFiles.append(url)
            }
        }
        if !urls.isEmpty {
            EventPushServer.shared.pushEvent(.files(listOutgoingFiles()))
        }
    }

    /// Remove a file from the outgoing queue
    func removeOutgoingFile(_ url: URL) {
        outgoingFiles.removeAll { $0 == url }
    }

    /// Clear all outgoing files
    func clearOutgoingFiles() {
        outgoingFiles.removeAll()
    }

    /// Check if a path is in the outgoing queue
    func isOutgoingFile(_ path: String) -> Bool {
        return outgoingFiles.contains { $0.path == path }
    }

    // MARK: - Private Helpers

    /// Sanitize a relative path, preserving folder structure but preventing traversal attacks
    private func sanitizeRelativePath(_ path: String) -> String {
        // Split into components and filter out dangerous ones
        let components = path.components(separatedBy: "/")
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
            .map { sanitizePathComponent($0) }

        // Ensure we have at least a filename
        if components.isEmpty {
            return "unnamed"
        }

        return components.joined(separator: "/")
    }

    /// Sanitize a single path component (filename or folder name)
    private func sanitizePathComponent(_ component: String) -> String {
        // Remove dangerous characters while preserving the component
        let sanitized = component
            .replacingOccurrences(of: "..", with: "_")
            .replacingOccurrences(of: "\\", with: "_")

        return sanitized.isEmpty ? "unnamed" : sanitized
    }

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
