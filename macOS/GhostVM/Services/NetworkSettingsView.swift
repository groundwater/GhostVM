import SwiftUI
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
