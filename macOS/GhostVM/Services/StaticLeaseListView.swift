import SwiftUI
import GhostVMKit

@available(macOS 13.0, *)
struct StaticLeaseListView: View {
    @Binding var leases: [DHCPStaticLease]
    @State private var editingLease: DHCPStaticLease?
    @State private var isAdding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Static Leases:")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button {
                    editingLease = DHCPStaticLease()
                    isAdding = true
                } label: {
                    Label("Add", systemImage: "plus")
                        .labelStyle(.iconOnly)
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("staticLeases.addButton")
            }

            if leases.isEmpty {
                Text("No static leases")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 6)
            } else {
                VStack(spacing: 0) {
                    // Header
                    HStack(spacing: 0) {
                        Text("MAC Address")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("IP Address")
                            .frame(width: 120, alignment: .leading)
                        Text("Hostname")
                            .frame(width: 100, alignment: .leading)
                        Text("")
                            .frame(width: 28)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)

                    Divider()

                    ForEach(leases) { lease in
                        HStack(spacing: 0) {
                            Text(lease.mac)
                                .font(.system(.caption, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(lease.ip)
                                .font(.system(.caption, design: .monospaced))
                                .frame(width: 120, alignment: .leading)
                            Text(lease.hostname)
                                .font(.caption)
                                .lineLimit(1)
                                .frame(width: 100, alignment: .leading)
                            Button {
                                leases.removeAll { $0.id == lease.id }
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.secondary.opacity(0.5))
                            }
                            .buttonStyle(.plain)
                            .frame(width: 28)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            editingLease = lease
                            isAdding = false
                        }

                        if lease.id != leases.last?.id {
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
            get: { editingLease != nil },
            set: { if !$0 { editingLease = nil; isAdding = false } }
        )) {
            if var lease = editingLease {
                staticLeaseEditor(lease: Binding(
                    get: { lease },
                    set: { lease = $0; editingLease = $0 }
                ))
            }
        }
    }

    @ViewBuilder
    private func staticLeaseEditor(lease: Binding<DHCPStaticLease>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isAdding ? "New Static Lease" : "Edit Static Lease")
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("MAC:")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 70, alignment: .trailing)
                    TextField("AA:BB:CC:DD:EE:FF", text: lease.mac)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("staticLease.macField")
                }
                GridRow {
                    Text("IP:")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 70, alignment: .trailing)
                    TextField("10.100.0.5", text: lease.ip)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("staticLease.ipField")
                }
                GridRow {
                    Text("Hostname:")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 70, alignment: .trailing)
                    TextField("devbox", text: lease.hostname)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("staticLease.hostnameField")
                }
            }

            Divider().padding(.vertical, 4)
            Text("Advanced Options")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("DNS:")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 70, alignment: .trailing)
                    TextField("Optional DNS server", text: Binding(
                        get: { lease.wrappedValue.dnsServer ?? "" },
                        set: { lease.wrappedValue.dnsServer = $0.isEmpty ? nil : $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("staticLease.dnsField")
                }
                GridRow {
                    Text("Gateway:")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 70, alignment: .trailing)
                    TextField("Optional gateway override", text: Binding(
                        get: { lease.wrappedValue.gatewayOverride ?? "" },
                        set: { lease.wrappedValue.gatewayOverride = $0.isEmpty ? nil : $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("staticLease.gatewayField")
                }
                GridRow {
                    Text("PXE IP:")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 70, alignment: .trailing)
                    TextField("Optional PXE server", text: Binding(
                        get: { lease.wrappedValue.pxeServer ?? "" },
                        set: { lease.wrappedValue.pxeServer = $0.isEmpty ? nil : $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("staticLease.pxeServerField")
                }
                GridRow {
                    Text("PXE File:")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 70, alignment: .trailing)
                    TextField("Optional PXE filename", text: Binding(
                        get: { lease.wrappedValue.pxeFilename ?? "" },
                        set: { lease.wrappedValue.pxeFilename = $0.isEmpty ? nil : $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("staticLease.pxeFileField")
                }
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    editingLease = nil
                    isAdding = false
                }
                .keyboardShortcut(.cancelAction)
                Button("Save") {
                    if isAdding {
                        leases.append(lease.wrappedValue)
                    } else if let idx = leases.firstIndex(where: { $0.id == lease.wrappedValue.id }) {
                        leases[idx] = lease.wrappedValue
                    }
                    editingLease = nil
                    isAdding = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(lease.wrappedValue.mac.isEmpty || lease.wrappedValue.ip.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
    }
}
