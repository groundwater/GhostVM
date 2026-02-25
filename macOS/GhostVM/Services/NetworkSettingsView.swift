import SwiftUI
import GhostVMKit
import Virtualization

@available(macOS 13.0, *)
struct NetworkSettingsView: View {
    @Binding var networkConfig: NetworkConfig
    var openNetworksWindow: (() -> Void)? = nil
    @State private var availableInterfaces: [(id: String, name: String)] = []
    #if DEBUG
    @State private var customNetworks: [RouterConfig] = []
    private let store = CustomNetworkStore.shared
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Network Mode:", selection: $networkConfig.mode) {
                Text("NAT (Shared)").tag(NetworkMode.nat)
                Text("Bridged").tag(NetworkMode.bridged)
                #if DEBUG
                Text("Custom").tag(NetworkMode.custom)
                #endif
            }
            .pickerStyle(.radioGroup)
            .onChange(of: networkConfig.mode) { newMode in
                handleModeChange(newMode)
            }

            modeDetail
        }
        .onAppear {
            loadAvailableInterfaces()
            #if DEBUG
            loadCustomNetworks()
            #endif
        }
    }

    @ViewBuilder
    private var modeDetail: some View {
        switch networkConfig.mode {
        case .bridged:
            bridgedDetail
        #if DEBUG
        case .custom:
            customDetail
        #endif
        default:
            Text("VM shares the host's network connection")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var bridgedDetail: some View {
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
    }

    #if DEBUG
    @ViewBuilder
    private var customDetail: some View {
        if customNetworks.isEmpty {
            Text("No custom networks configured. Create one in Settings \u{2192} Networks.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Picker("Custom Network:", selection: $networkConfig.customNetworkID) {
                Text("None").tag(nil as UUID?)
                ForEach(customNetworks) { network in
                    Text(network.name).tag(network.id as UUID?)
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("networkSettings.customNetworkPicker")

            if let selectedID = networkConfig.customNetworkID,
               let network = customNetworks.first(where: { $0.id == selectedID }) {
                Text(network.summaryLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        if let openNetworks = openNetworksWindow {
            Button("Manage Networks\u{2026}") {
                openNetworks()
            }
            .font(.caption)
            .accessibilityIdentifier("networkSettings.manageNetworksButton")
        }
    }
    #endif

    private func handleModeChange(_ newMode: NetworkMode) {
        if newMode == .nat {
            networkConfig.bridgeInterfaceIdentifier = nil
            networkConfig.customNetworkID = nil
        } else if newMode == .bridged {
            networkConfig.customNetworkID = nil
            if networkConfig.bridgeInterfaceIdentifier == nil {
                networkConfig.bridgeInterfaceIdentifier = availableInterfaces.first?.id
            }
        }
        #if DEBUG
        if newMode == .custom {
            networkConfig.bridgeInterfaceIdentifier = nil
            if networkConfig.customNetworkID == nil {
                networkConfig.customNetworkID = customNetworks.first?.id
            }
        }
        #endif
    }

    private func loadAvailableInterfaces() {
        let interfaces = VZBridgedNetworkInterface.networkInterfaces
        availableInterfaces = interfaces.map { interface in
            let displayName = interface.localizedDisplayName ?? interface.identifier
            return (id: interface.identifier, name: displayName)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    #if DEBUG
    private func loadCustomNetworks() {
        customNetworks = (try? store.list()) ?? []
    }
    #endif
}
