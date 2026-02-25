import SwiftUI
import GhostVMKit

@available(macOS 13.0, *)
struct NetworkInterfaceListView: View {
    @Binding var interfaces: [NetworkInterfaceConfig]
    var openNetworksWindow: (() -> Void)? = nil

    @State private var editingInterface: NetworkInterfaceConfig?
    @State private var isAdding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Network Interfaces:")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button {
                    let n = interfaces.count + 1
                    editingInterface = NetworkInterfaceConfig(label: "Network \(n)")
                    isAdding = true
                } label: {
                    Label("Add", systemImage: "plus")
                        .labelStyle(.iconOnly)
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("networkInterfaces.addButton")
            }

            Text("First interface maps to en0 in the guest.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if interfaces.isEmpty {
                Text("No network interfaces")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 6)
            } else {
                VStack(spacing: 0) {
                    // Header
                    HStack(spacing: 0) {
                        Text("")
                            .frame(width: 44) // reorder buttons
                        Text("Label")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("Mode")
                            .frame(width: 170, alignment: .leading)
                        Text("")
                            .frame(width: 32)
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)

                    Divider()

                    ForEach(Array(interfaces.enumerated()), id: \.element.id) { index, iface in
                        HStack(spacing: 0) {
                            // Reorder buttons
                            VStack(spacing: 2) {
                                Button {
                                    guard index > 0 else { return }
                                    interfaces.swapAt(index, index - 1)
                                } label: {
                                    Image(systemName: "chevron.up")
                                        .font(.system(size: 10, weight: .medium))
                                }
                                .buttonStyle(.plain)
                                .disabled(index == 0)
                                .opacity(index == 0 ? 0.3 : 1)

                                Button {
                                    guard index < interfaces.count - 1 else { return }
                                    interfaces.swapAt(index, index + 1)
                                } label: {
                                    Image(systemName: "chevron.down")
                                        .font(.system(size: 10, weight: .medium))
                                }
                                .buttonStyle(.plain)
                                .disabled(index == interfaces.count - 1)
                                .opacity(index == interfaces.count - 1 ? 0.3 : 1)
                            }
                            .frame(width: 44)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(iface.label)
                                    .font(.subheadline)
                                    .lineLimit(1)
                                if !iface.macAddress.isEmpty {
                                    Text(iface.macAddress)
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            Text(modeSummary(iface))
                                .font(.subheadline)
                                .lineLimit(1)
                                .frame(width: 170, alignment: .leading)

                            Button {
                                interfaces.removeAll { $0.id == iface.id }
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .font(.system(size: 14))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .frame(width: 32)
                            .disabled(interfaces.count <= 1)
                            .opacity(interfaces.count <= 1 ? 0.25 : 1)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            editingInterface = iface
                            isAdding = false
                        }

                        if iface.id != interfaces.last?.id {
                            Divider().padding(.leading, 6)
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.background)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(.separator, lineWidth: 1)
                )
            }
        }
        .sheet(isPresented: Binding(
            get: { editingInterface != nil },
            set: { if !$0 { editingInterface = nil; isAdding = false } }
        )) {
            if var iface = editingInterface {
                interfaceEditor(iface: Binding(
                    get: { iface },
                    set: { iface = $0; editingInterface = $0 }
                ))
            }
        }
    }

    private func modeSummary(_ iface: NetworkInterfaceConfig) -> String {
        switch iface.networkConfig.mode {
        case .nat:
            return "NAT"
        case .bridged:
            return "Bridged: \(iface.networkConfig.bridgeInterfaceIdentifier ?? "none")"
        case .custom:
            return "Custom"
        }
    }

    @ViewBuilder
    private func interfaceEditor(iface: Binding<NetworkInterfaceConfig>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isAdding ? "New Network Interface" : "Edit Network Interface")
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("Label:")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 70, alignment: .trailing)
                    TextField("e.g. Primary, Management", text: iface.label)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("networkInterface.labelField")
                }
            }

            Divider().padding(.vertical, 2)

            #if DEBUG
            NetworkSettingsView(networkConfig: iface.networkConfig, openNetworksWindow: openNetworksWindow)
            #else
            NetworkSettingsView(networkConfig: iface.networkConfig)
            #endif

            HStack {
                Spacer()
                Button("Cancel") {
                    editingInterface = nil
                    isAdding = false
                }
                .keyboardShortcut(.cancelAction)
                Button("Save") {
                    if isAdding {
                        interfaces.append(iface.wrappedValue)
                    } else if let idx = interfaces.firstIndex(where: { $0.id == iface.wrappedValue.id }) {
                        interfaces[idx] = iface.wrappedValue
                    }
                    editingInterface = nil
                    isAdding = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }
}
