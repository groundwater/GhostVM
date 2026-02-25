import SwiftUI
import GhostVMKit

@available(macOS 13.0, *)
struct WANSectionView: View {
    @Binding var wan: WANConfig
    @State private var hostInterfaces: [HostNetworkInterface] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Mode:", selection: $wan.mode) {
                Text("NAT").tag(WANMode.nat)
                Text("Passthrough").tag(WANMode.passthrough)
                Text("Isolated").tag(WANMode.isolated)
            }
            .pickerStyle(.radioGroup)
            .horizontalRadioGroupLayout()
            .accessibilityIdentifier("wan.modePicker")

            if wan.mode != .isolated {
                HStack(spacing: 12) {
                    Text("Upstream:")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 80, alignment: .leading)

                    Picker("", selection: $wan.upstream) {
                        Text("Auto (default route)").tag(nil as String?)
                        ForEach(hostInterfaces) { iface in
                            Text(iface.displayName).tag(iface.id as String?)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 280)
                    .accessibilityIdentifier("wan.upstreamPicker")

                    Button {
                        hostInterfaces = HostNetworkScanner.bridgeableInterfaces()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Refresh interface list")
                    .accessibilityIdentifier("wan.refreshInterfaces")
                }

                if wan.mode == .nat {
                    Toggle("Masquerade", isOn: $wan.masquerade)
                        .toggleStyle(.checkbox)
                        .accessibilityIdentifier("wan.masqueradeToggle")
                }
            }

            modeDescription
        }
        .onAppear {
            hostInterfaces = HostNetworkScanner.bridgeableInterfaces()
        }
    }

    @ViewBuilder
    private var modeDescription: some View {
        switch wan.mode {
        case .nat:
            Text("VM traffic is NAT'd through the host")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .passthrough:
            Text("VM is bridged directly to the upstream interface")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .isolated:
            Text("No external connectivity (air-gapped)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
