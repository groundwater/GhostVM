import SwiftUI
import AppKit
import GhostVMKit
import Virtualization

@available(macOS 13.0, *)
struct NetworkSettingsView: View {
    @Binding var networkConfig: NetworkConfig
    @State private var availableInterfaces: [(id: String, name: String)] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Network Mode:", selection: $networkConfig.mode) {
                Text("NAT (Shared)").tag(NetworkMode.nat)
                Text("Bridged").tag(NetworkMode.bridged)
            }
            .pickerStyle(.radioGroup)
            .onChange(of: networkConfig.mode) { newMode in
                if newMode == .nat {
                    networkConfig.bridgeInterfaceIdentifier = nil
                } else if newMode == .bridged && networkConfig.bridgeInterfaceIdentifier == nil {
                    networkConfig.bridgeInterfaceIdentifier = availableInterfaces.first?.id
                }
            }

            if networkConfig.mode == .bridged {
                Picker("Bridge Interface:", selection: $networkConfig.bridgeInterfaceIdentifier) {
                    Text("None").tag(nil as String?)
                    ForEach(availableInterfaces, id: \.id) { interface in
                        Text(interface.name).tag(interface.id as String?)
                    }
                }
                .pickerStyle(.menu)
                .disabled(availableInterfaces.isEmpty)

                if availableInterfaces.isEmpty {
                    Text("No network interfaces available for bridging")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("VM will appear as a separate device on your network")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("VM shares the host's network connection")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            loadAvailableInterfaces()
        }
    }

    private func loadAvailableInterfaces() {
        let interfaces = VZBridgedNetworkInterface.networkInterfaces
        availableInterfaces = interfaces.map { interface in
            let displayName = interface.localizedDisplayName ?? interface.identifier
            return (id: interface.identifier, name: displayName)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

@available(macOS 13.0, *)
struct HostContainerSettingsView: View {
    @Binding var isEnabled: Bool
    let networkMode: NetworkMode
    let accessibilityIdentifier: String

    @State private var fileSystemExtensionEnabled: Bool?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Enable host-backed containers", isOn: Binding(
                get: { networkMode == .nat && isEnabled },
                set: { isEnabled = networkMode == .nat && $0 }
            ))
            .toggleStyle(.checkbox)
            .disabled(networkMode != .nat)
            .accessibilityIdentifier(accessibilityIdentifier)

            if networkMode != .nat {
                Text("Host-backed containers currently require NAT (Shared) networking.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if isEnabled {
                Text("Uses an isolated network shared by this VM and its containers.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(fileSystemExtensionStatus)
                    .font(.caption)
                    .foregroundStyle(fileSystemExtensionEnabled == false ? Color.orange : Color.secondary)

                if fileSystemExtensionEnabled == false {
                    Button("Open System Settings…") {
                        guard let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") else {
                            return
                        }
                        NSWorkspace.shared.open(url)
                    }
                    .font(.caption)
                }
            }
        }
        .task(id: isEnabled) {
            guard isEnabled else { return }
            fileSystemExtensionEnabled = await Task.detached(priority: .utility) {
                GuestVolumeMount.extensionIsEnabled()
            }.value
        }
        .onChange(of: networkMode) { _, newMode in
            if newMode != .nat {
                isEnabled = false
            }
        }
    }

    private var fileSystemExtensionStatus: String {
        switch fileSystemExtensionEnabled {
        case true:
            return "File System Extension: Enabled"
        case false:
            return "File System Extension: Not Enabled"
        case nil:
            return "File System Extension: Checking…"
        }
    }
}
