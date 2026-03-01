import SwiftUI
import GhostVMKit

@available(macOS 13.0, *)
struct DNSSectionView: View {
    @Binding var dns: DNSConfig
    @State private var newServer: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Mode:", selection: $dns.mode) {
                Text("Passthrough").tag(DNSMode.passthrough)
                Text("Custom").tag(DNSMode.custom)
                Text("Blocked").tag(DNSMode.blocked)
            }
            .pickerStyle(.radioGroup)
            .horizontalRadioGroupLayout()
            .accessibilityIdentifier("dns.modePicker")

            switch dns.mode {
            case .passthrough:
                Text("DNS queries forwarded to host resolver")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .custom:
                customServersList
            case .blocked:
                Text("All DNS queries are blocked")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var customServersList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(dns.servers.indices, id: \.self) { index in
                HStack(spacing: 6) {
                    Text(dns.servers[index])
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        dns.servers.remove(at: index)
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.secondary.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: 6) {
                TextField("e.g. 8.8.8.8", text: $newServer)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
                    .accessibilityIdentifier("dns.newServerField")
                    .onSubmit { addServer() }
                Button {
                    addServer()
                } label: {
                    Image(systemName: "plus.circle.fill")
                }
                .buttonStyle(.borderless)
                .disabled(newServer.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityIdentifier("dns.addServerButton")
            }
        }
    }

    private func addServer() {
        let trimmed = newServer.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        dns.servers.append(trimmed)
        newServer = ""
    }
}
