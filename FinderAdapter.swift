import Foundation
import AppKit

enum FinderAdapter {
    static func revealRestoreImage(filename: String, cacheDirectory: URL) {
        let fm = FileManager.default
        let baseURL = cacheDirectory.appendingPathComponent(filename, isDirectory: false)
        let downloadURL = baseURL.appendingPathExtension("download")
        let workspace = NSWorkspace.shared

        if fm.fileExists(atPath: baseURL.path) {
            workspace.activateFileViewerSelecting([baseURL])
        } else if fm.fileExists(atPath: downloadURL.path) {
            workspace.activateFileViewerSelecting([downloadURL])
        } else {
            workspace.selectFile(nil, inFileViewerRootedAtPath: cacheDirectory.path)
        }
    }

    static func revealItem(at url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
