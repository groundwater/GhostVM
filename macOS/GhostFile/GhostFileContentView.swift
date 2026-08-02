import AppKit
import SwiftUI

private enum GhostFileMode: String, CaseIterable, Identifiable {
    case share = "Share"
    case mount = "Mount"
    var id: Self { self }
}

struct GhostFileContentView: View {
    @State private var mode: GhostFileMode = .share
    @StateObject private var shareController = GhostFileShareController()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("GhostFile")
                        .font(.title2.weight(.semibold))
                    Text("Share and mount folders over your local network")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Mode", selection: $mode) {
                    ForEach(GhostFileMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 230)
            }
            .padding()

            Divider()

            switch mode {
            case .share:
                GhostFileShareView(controller: shareController)
            case .mount:
                GhostFileMountView()
            }
        }
    }
}

private struct GhostFileShareView: View {
    @ObservedObject var controller: GhostFileShareController

    var body: some View {
        Group {
            if let server = controller.server {
                activeShare(server)
            } else {
                shareSetup
            }
        }
        .padding(24)
    }

    private var shareSetup: some View {
        Form {
            Section("Folder") {
                HStack {
                    Text(controller.selectedFolder?.path ?? "No folder selected")
                        .foregroundStyle(controller.selectedFolder == nil ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Choose…") { controller.chooseFolder() }
                }
            }

            Section("Network Share") {
                TextField("Share name", text: $controller.shareName)
                HStack {
                    TextField("Port", text: $controller.portText)
                        .frame(width: 100)
                    Text("Use 0 to select an available port automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    SecureField("Access key", text: $controller.accessKey)
                    Button("Regenerate") { controller.regenerateAccessKey() }
                }
            }

            Section("Protocol") {
                LabeledContent("Discovery", value: "Bonjour / mDNS")
                LabeledContent("Filesystem API", value: "GhostFile v1")
                LabeledContent("Transport", value: "HTTP/3 · QUIC / UDP · multiplexed")
                LabeledContent("Access", value: "Read only")
            }

            if let message = controller.errorMessage {
                Text(message).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Start Sharing") { controller.start() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        }
        .formStyle(.grouped)
    }

    private func activeShare(_ server: GhostFileShareServer) -> some View {
        GhostFileActiveShareView(server: server, controller: controller)
    }
}

private struct GhostFileActiveShareView: View {
    @ObservedObject var server: GhostFileShareServer
    @ObservedObject var controller: GhostFileShareController

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Sharing “\(server.shareName)”", systemImage: "network")
                        .font(.title2.weight(.semibold))
                    Text(server.rootURL.path)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Label("Online", systemImage: "circle.fill")
                    .foregroundStyle(.green)
            }

            GroupBox("Share URL") {
                HStack {
                    Text(server.shareURL?.absoluteString ?? "Starting…")
                        .textSelection(.enabled)
                    Spacer()
                    Button("Copy") {
                        if let value = server.shareURL?.absoluteString { controller.copy(value) }
                    }
                }
                .padding(.vertical, 4)
            }

            GroupBox("Access Key") {
                HStack {
                    Text(controller.accessKey)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                    Spacer()
                    Button("Copy") { controller.copy(controller.accessKey) }
                }
                .padding(.vertical, 4)
            }

            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
                GridRow { Text("Bonjour").foregroundStyle(.secondary); Text("\(server.shareName) · _ghostfile._udp") }
                GridRow { Text("Transport").foregroundStyle(.secondary); Text("HTTP/3 · QUIC / UDP") }
                GridRow { Text("Access").foregroundStyle(.secondary); Text("Read only") }
                GridRow { Text("Requests").foregroundStyle(.secondary); Text("\(server.requestCount)") }
            }

            Spacer()
            HStack {
                Spacer()
                Button("Stop Sharing", role: .destructive) { controller.stop() }
                    .controlSize(.large)
            }
        }
    }
}

private struct GhostFileMountView: View {
    @StateObject private var discovery = GhostFileDiscovery()
    @StateObject private var mountManager = GhostFileMountManager()
    @State private var selectedShareID: UUID?
    @State private var urlText = ""
    @State private var accessKey = ""
    @State private var volumeName = "GhostFile Share"
    @State private var mountPoint: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Nearby Shares").font(.headline)
                Spacer()
                if discovery.isSearching {
                    ProgressView().controlSize(.small)
                    Text("Searching…").font(.caption).foregroundStyle(.secondary)
                }
            }

            List(discovery.shares, selection: $selectedShareID) { share in
                Button {
                    select(share)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "externaldrive.connected.to.line.below")
                            .font(.title2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(share.name).fontWeight(.medium)
                            Text("\(share.host) · \(share.transport) · \(share.readOnly ? "Read only" : "Read & write")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .tag(share.id)
            }
            .frame(minHeight: 130, maxHeight: 200)
            .overlay {
                if discovery.shares.isEmpty {
                    ContentUnavailableView(
                        "No Nearby Shares",
                        systemImage: "network.slash",
                        description: Text("Start sharing in another GhostFile window, or enter a URL below.")
                    )
                }
            }

            GroupBox("Mount from URL") {
                Form {
                    TextField("Share URL", text: $urlText, prompt: Text("ghostfile://mac.local:8049/v1/shares/…"))
                    SecureField("Access key", text: $accessKey)
                    TextField("Volume name", text: $volumeName)
                    LabeledContent("Mount point") {
                        HStack {
                            Text(mountPoint?.path ?? "Automatic — ~/GhostFile Mounts")
                                .foregroundStyle(mountPoint == nil ? .secondary : .primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if mountPoint != nil {
                                Button("Use Automatic") { mountPoint = nil }
                            }
                            Button("Choose…") { chooseMountPoint() }
                        }
                    }
                }
                .formStyle(.columns)
                .padding(.vertical, 8)
            }

            HStack {
                switch mountManager.extensionEnabled {
                case true:
                    Label("FSKit extension enabled", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case false:
                    Label("FSKit extension not enabled", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Button("Open File System Extensions…") { mountManager.openExtensionSettings() }
                    if mountManager.extensionRepairAvailable {
                        Button("Repair & Open Settings…") {
                            Task { await mountManager.repairExtensionRegistration() }
                        }
                    }
                case nil:
                    ProgressView().controlSize(.small)
                    Text("Checking FSKit extension…").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Mount") {
                    guard let url = URL(string: urlText) else {
                        mountManager.errorMessage = "Enter a valid share URL."
                        return
                    }
                    Task {
                        await mountManager.mount(
                            url: url,
                            accessKey: accessKey,
                            volumeName: volumeName,
                            requestedMountPoint: mountPoint
                        )
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(mountManager.isWorking || mountManager.extensionEnabled != true)
            }

            if let detail = mountManager.extensionStatusDetail {
                Text(detail).foregroundStyle(.orange).font(.callout)
            }

            if !mountManager.mountedShares.isEmpty {
                Divider()
                Text("Mounted").font(.headline)
                ForEach(mountManager.mountedShares) { mountedShare in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(mountedShare.name).fontWeight(.medium)
                            Text(mountedShare.mountPoint.path).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Reveal") { mountManager.reveal(mountedShare) }
                        Button("Unmount") { Task { await mountManager.unmount(mountedShare) } }
                    }
                }
            }

            if let message = mountManager.errorMessage {
                Text(message).foregroundStyle(.red).font(.callout)
            }
        }
        .padding(24)
        .task {
            discovery.start()
            await mountManager.refreshExtensionStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await mountManager.refreshExtensionStatus() }
        }
        .onChange(of: discovery.removalEvent) { _, removal in
            guard let removal else { return }
            Task { await mountManager.unmountDisconnectedShare(withID: removal.shareID) }
        }
    }

    private func select(_ share: DiscoveredGhostFileShare) {
        selectedShareID = share.id
        urlText = share.url?.absoluteString ?? ""
        volumeName = share.name
    }

    private func chooseMountPoint() {
        let panel = NSOpenPanel()
        panel.title = "Choose an empty folder to use as the mount point"
        panel.prompt = "Choose Mount Point"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if let mountPoint {
            panel.directoryURL = mountPoint
        }
        guard panel.runModal() == .OK, let selectedURL = panel.url else { return }
        mountPoint = selectedURL.standardizedFileURL
    }
}
