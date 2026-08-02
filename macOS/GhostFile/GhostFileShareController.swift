import AppKit
import Foundation

@MainActor
final class GhostFileShareController: ObservableObject {
    @Published var selectedFolder: URL?
    @Published var shareName = "DemoShare"
    @Published var portText = "0"
    @Published var accessKey = UUID().uuidString.lowercased()
    @Published private(set) var server: GhostFileShareServer?
    @Published var errorMessage: String?

    private var isAccessingSecurityScopedFolder = false
    private static let selectedFolderBookmarkKey = "GhostFile.selectedFolderBookmark"

    init() {
        restoreSelectedFolder()
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose a folder to share"
        panel.prompt = "Share Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        selectedFolder = url
        persistSelectedFolder(url)
        if shareName == "DemoShare" || shareName.isEmpty {
            shareName = url.lastPathComponent
        }
    }

    func start() {
        guard let selectedFolder else {
            errorMessage = "Choose a folder to share."
            return
        }
        let trimmedName = shareName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            errorMessage = "Enter a share name."
            return
        }
        guard !accessKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "Enter an access key."
            return
        }
        guard let preferredPort = UInt16(portText) else {
            errorMessage = "The port must be between 0 and 65535. Use 0 to choose automatically."
            return
        }

        isAccessingSecurityScopedFolder = selectedFolder.startAccessingSecurityScopedResource()
        let newServer = GhostFileShareServer(
            rootURL: selectedFolder,
            shareName: trimmedName,
            accessKey: accessKey
        )
        do {
            try newServer.start(preferredPort: preferredPort)
            server = newServer
            errorMessage = nil
        } catch {
            if isAccessingSecurityScopedFolder {
                selectedFolder.stopAccessingSecurityScopedResource()
                isAccessingSecurityScopedFolder = false
            }
            errorMessage = "Unable to start sharing: \(error.localizedDescription)"
        }
    }

    func stop() {
        server?.stop()
        server = nil
        if isAccessingSecurityScopedFolder {
            selectedFolder?.stopAccessingSecurityScopedResource()
            isAccessingSecurityScopedFolder = false
        }
    }

    func regenerateAccessKey() {
        accessKey = UUID().uuidString.lowercased()
    }

    func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func persistSelectedFolder(_ url: URL) {
        do {
            let bookmark = try url.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(bookmark, forKey: Self.selectedFolderBookmarkKey)
        } catch {
            errorMessage = "Unable to remember the shared folder: \(error.localizedDescription)"
        }
    }

    private func restoreSelectedFolder() {
        guard let bookmark = UserDefaults.standard.data(forKey: Self.selectedFolderBookmarkKey) else {
            return
        }
        do {
            var stale = false
            let url = try URL(
                resolvingBookmarkData: bookmark,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            selectedFolder = url
            shareName = url.lastPathComponent
            if stale {
                persistSelectedFolder(url)
            }
        } catch {
            UserDefaults.standard.removeObject(forKey: Self.selectedFolderBookmarkKey)
            errorMessage = "Choose the shared folder again; its saved permission is no longer valid."
        }
    }
}
