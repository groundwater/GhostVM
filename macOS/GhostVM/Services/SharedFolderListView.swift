import SwiftUI
import GhostVMKit

// MARK: - Shared Folder Entry (display model for runtime panels)

struct SharedFolderEntry: Identifiable {
    let id: UUID
    var path: String
    var readOnly: Bool

    var displayName: String {
        URL(fileURLWithPath: path).lastPathComponent
    }
}

// MARK: - Remove Button with Hover

@available(macOS 13.0, *)
private struct FolderRemoveButtonView: View {
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "minus.circle.fill")
                .foregroundColor(isHovered ? .red : .secondary.opacity(0.5))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Shared Folder Row

@available(macOS 13.0, *)
private struct FolderRowView: View {
    let folder: SharedFolderConfig
    let onRemove: () -> Void

    private var displayName: String {
        URL(fileURLWithPath: folder.path).lastPathComponent
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder.fill")
                .foregroundStyle(.blue)
                .font(.title3)

            VStack(alignment: .leading, spacing: 1) {
                Text(displayName)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text(folder.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            if folder.readOnly {
                Text("Read Only")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.quaternary))
            }

            FolderRemoveButtonView(action: onRemove)
        }
    }
}

// MARK: - Shared Folder List (Binding mode for EditVMView)

@available(macOS 13.0, *)
struct SharedFolderListView: View {
    @Binding var folders: [SharedFolderConfig]
    @State private var readOnly = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if folders.isEmpty {
                Text("No shared folders")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 10)
            }

            ForEach(folders) { folder in
                FolderRowView(folder: folder) {
                    folders.removeAll { $0.id == folder.id }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)

                if folder.id != folders.last?.id {
                    Divider().padding(.leading, 10)
                }
            }

            if !folders.isEmpty {
                Divider()
            }

            HStack(spacing: 12) {
                Button {
                    selectFolder()
                } label: {
                    Label("Add Folder\u{2026}", systemImage: "plus")
                }

                Toggle("Read Only", isOn: $readOnly)
                    .toggleStyle(.checkbox)
                    .fixedSize()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.background)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(.separator, lineWidth: 1)
        )
    }

    private func selectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Select"
        panel.message = "Choose a folder to share with the VM"

        if panel.runModal() == .OK, let url = panel.url {
            let path = url.path
            if !folders.contains(where: { $0.path == path }) {
                folders.append(SharedFolderConfig(path: path, readOnly: readOnly))
            }
        }
    }
}

// MARK: - Shared Folder List (Callback mode for runtime)

@available(macOS 13.0, *)
struct SharedFolderCallbackListView: View {
    var folders: [SharedFolderEntry]
    var onAdd: (String, Bool) -> Void
    var onRemove: (UUID) -> Void
    var onToggleReadOnly: ((UUID, Bool) -> Void)? = nil
    @State private var readOnly = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if folders.isEmpty {
                Text("No shared folders")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 10)
            }

            ForEach(folders) { folder in
                HStack(spacing: 8) {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(.blue)
                        .font(.title3)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(folder.displayName)
                            .fontWeight(.medium)
                            .lineLimit(1)
                        Text(folder.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer()

                    Toggle("Read Only", isOn: Binding(
                        get: { folder.readOnly },
                        set: { onToggleReadOnly?(folder.id, $0) }
                    ))
                    .toggleStyle(.checkbox)
                    .fixedSize()

                    FolderRemoveButtonView {
                        onRemove(folder.id)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)

                if folder.id != folders.last?.id {
                    Divider().padding(.leading, 10)
                }
            }

            Spacer()

            Divider()

            HStack(spacing: 12) {
                Button {
                    selectFolder()
                } label: {
                    Label("Add Folder\u{2026}", systemImage: "plus")
                }

                Toggle("Read Only", isOn: $readOnly)
                    .toggleStyle(.checkbox)
                    .fixedSize()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .frame(maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.background)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(.separator, lineWidth: 1)
        )
    }

    private func selectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Share"
        panel.message = "Select a folder to share with the VM"

        panel.begin { response in
            if response == .OK, let url = panel.url {
                onAdd(url.path, readOnly)
            }
        }
    }
}
