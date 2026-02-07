import Foundation
import Virtualization
import GhostVMKit

/// Manages shared folders for a running VM using VZMultipleDirectoryShare.
///
/// Folders can be added/removed at runtime. The service rebuilds the
/// VZMultipleDirectoryShare and assigns it to the VM's file-system device.
@MainActor
public final class FolderShareService: ObservableObject {
    private let virtualMachine: VZVirtualMachine
    private let vmQueue: DispatchQueue

    @Published public private(set) var activeFolders: [SharedFolderConfig] = []

    public init(vm: VZVirtualMachine, queue: DispatchQueue) {
        self.virtualMachine = vm
        self.vmQueue = queue
    }

    /// Load initial state. The VMConfigurationBuilder already set the device
    /// share at boot, so we just record the folder list for the UI.
    public func start(folders: [SharedFolderConfig]) {
        activeFolders = folders
        print("[FolderShareService] Started with \(folders.count) folder(s)")
    }

    /// Add a shared folder and rebuild the device share.
    public func addFolder(_ folder: SharedFolderConfig) {
        // Check for duplicates by path
        guard !activeFolders.contains(where: { $0.path == folder.path }) else {
            print("[FolderShareService] Folder already shared: \(folder.path)")
            return
        }

        // Validate path exists and is a directory
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            print("[FolderShareService] Path does not exist or is not a directory: \(folder.path)")
            return
        }

        activeFolders.append(folder)
        rebuildShare()
        print("[FolderShareService] Added folder: \(folder.path)")
    }

    /// Remove a shared folder by ID and rebuild the device share.
    public func removeFolder(id: UUID) {
        guard let index = activeFolders.firstIndex(where: { $0.id == id }) else { return }
        let removed = activeFolders.remove(at: index)
        rebuildShare()
        print("[FolderShareService] Removed folder: \(removed.path)")
    }

    /// Stop the service and clear state.
    public func stop() {
        activeFolders.removeAll()
        print("[FolderShareService] Stopped")
    }

    /// Build a new VZMultipleDirectoryShare from activeFolders and assign it
    /// to the VM's file-system device on the vmQueue.
    private func rebuildShare() {
        var directories: [String: VZSharedDirectory] = [:]
        var usedNames: [String: Int] = [:]

        for folder in activeFolders {
            let url = URL(fileURLWithPath: folder.path)
            let sharedDirectory = VZSharedDirectory(url: url, readOnly: folder.readOnly)

            var name = url.lastPathComponent
            if let count = usedNames[name] {
                usedNames[name] = count + 1
                name = "\(name)-\(count + 1)"
            } else {
                usedNames[name] = 1
            }
            directories[name] = sharedDirectory
        }

        let multiShare = VZMultipleDirectoryShare(directories: directories)

        // Find the directory sharing device and update its share on vmQueue.
        // VZ operations must happen on the queue the VM was created on.
        guard let device = virtualMachine.directorySharingDevices.first as? VZVirtioFileSystemDevice else {
            print("[FolderShareService] No VZVirtioFileSystemDevice found on VM")
            return
        }

        vmQueue.async {
            device.share = multiShare
            print("[FolderShareService] Rebuilt share with \(directories.count) folder(s)")
        }
    }
}
