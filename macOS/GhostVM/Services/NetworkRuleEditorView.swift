import SwiftUI
import GhostVMKit

@available(macOS 13.0, *)
struct NetworkRuleEditorView: View {
    @Binding var rule: NetworkRule
    var onSave: () -> Void
    var onCancel: () -> Void

    private let labelWidth: CGFloat = 100

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Title
            Text(rule.comment == nil ? "New Rule" : "Edit Rule")
                .font(.headline)
                .padding(.bottom, 16)

            // Action / Layer / Direction — compact grid
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    label("Action")
                    Picker("", selection: $rule.action) {
                        Text("Block").tag(RuleAction.block)
                        Text("Allow").tag(RuleAction.allow)
                        Text("Redirect").tag(RuleAction.redirect)
                    }
                    .pickerStyle(.radioGroup)
                    .horizontalRadioGroupLayout()
                    .labelsHidden()
                }

                GridRow {
                    label("Layer")
                    Picker("", selection: $rule.layer) {
                        Text("L2 (Ethernet)").tag(RuleLayer.l2)
                        Text("L3 (IP)").tag(RuleLayer.l3)
                    }
                    .pickerStyle(.radioGroup)
                    .horizontalRadioGroupLayout()
                    .labelsHidden()
                }

                GridRow {
                    label("Direction")
                    Picker("", selection: $rule.direction) {
                        Text("Inbound").tag(RuleDirection.inbound)
                        Text("Outbound").tag(RuleDirection.outbound)
                        Text("Both").tag(RuleDirection.both)
                    }
                    .pickerStyle(.radioGroup)
                    .horizontalRadioGroupLayout()
                    .labelsHidden()
                }

                GridRow {
                    label("Zone")
                    Picker("", selection: Binding(
                        get: { rule.zone ?? .any },
                        set: { rule.zone = $0 == .any ? nil : $0 }
                    )) {
                        Text("Any").tag(NetworkZone.any)
                        Text("WAN").tag(NetworkZone.wan)
                        Text("LAN").tag(NetworkZone.lan)
                    }
                    .pickerStyle(.radioGroup)
                    .horizontalRadioGroupLayout()
                    .labelsHidden()
                    .accessibilityIdentifier("ruleEditor.zonePicker")
                }
            }

            Divider()
                .padding(.vertical, 12)

            // Layer-specific match fields
            if rule.layer == .l2 {
                l2Fields
            } else {
                l3Fields
            }

            Divider()
                .padding(.vertical, 12)

            // Comment
            fieldRow("Comment") {
                TextField("Optional description", text: Binding(
                    get: { rule.comment ?? "" },
                    set: { rule.comment = $0.isEmpty ? nil : $0 }
                ))
                .textFieldStyle(.roundedBorder)
            }

            Spacer(minLength: 16)

            // Buttons
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("ruleEditor.cancelButton")
                Button("Save", action: onSave)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("ruleEditor.saveButton")
            }
        }
        .padding(20)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - L2 Fields

    @ViewBuilder
    private var l2Fields: some View {
        Text("L2 Match")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.bottom, 6)

        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
            GridRow {
                label("Source MAC")
                TextField("e.g. AA:BB:CC:DD:EE:FF", text: optionalBinding(\.srcMAC))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("ruleEditor.srcMACField")
            }

            GridRow {
                label("Dest MAC")
                TextField("e.g. AA:BB:CC:DD:EE:FF", text: optionalBinding(\.dstMAC))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("ruleEditor.dstMACField")
            }

            GridRow {
                label("EtherType")
                TextField("e.g. 0x0800 (IPv4), 0x86DD (IPv6)", text: optionalBinding(\.etherType))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("ruleEditor.etherTypeField")
            }

            GridRow {
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                Toggle("Block Broadcast", isOn: Binding(
                    get: { rule.blockBroadcast ?? false },
                    set: { rule.blockBroadcast = $0 ? true : nil }
                ))
                .toggleStyle(.checkbox)
            }
        }
    }

    // MARK: - L3 Fields

    @ViewBuilder
    private var l3Fields: some View {
        Text("L3 Match")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.bottom, 6)

        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
            GridRow {
                label("Source CIDR")
                TextField("e.g. 10.0.0.0/8 or leave empty for any", text: optionalBinding(\.srcCIDR))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("ruleEditor.srcCIDRField")
            }

            GridRow {
                label("Dest CIDR")
                TextField("e.g. 192.168.0.0/16", text: optionalBinding(\.dstCIDR))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("ruleEditor.dstCIDRField")
            }

            GridRow {
                label("Protocol")
                Picker("", selection: Binding(
                    get: { rule.ipProtocol ?? .any },
                    set: { rule.ipProtocol = $0 == .any ? nil : $0 }
                )) {
                    Text("Any").tag(IPProtocol.any)
                    Text("TCP").tag(IPProtocol.tcp)
                    Text("UDP").tag(IPProtocol.udp)
                    Text("ICMP").tag(IPProtocol.icmp)
                }
                .labelsHidden()
                .frame(maxWidth: 140, alignment: .leading)
                .accessibilityIdentifier("ruleEditor.protocolPicker")
            }

            GridRow {
                label("Dest Port")
                TextField("e.g. 443", text: portBinding(\.dstPort))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 100)
                    .accessibilityIdentifier("ruleEditor.dstPortField")
            }

            GridRow {
                label("Source Port")
                TextField("e.g. 8080", text: portBinding(\.srcPort))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 100)
                    .accessibilityIdentifier("ruleEditor.srcPortField")
            }
        }
    }

    // MARK: - Helpers

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: labelWidth, alignment: .trailing)
    }

    private func fieldRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            label(title)
            content()
        }
    }

    private func optionalBinding(_ keyPath: WritableKeyPath<NetworkRule, String?>) -> Binding<String> {
        Binding(
            get: { rule[keyPath: keyPath] ?? "" },
            set: { rule[keyPath: keyPath] = $0.isEmpty ? nil : $0 }
        )
    }

    private func portBinding(_ keyPath: WritableKeyPath<NetworkRule, UInt16?>) -> Binding<String> {
        Binding(
            get: { rule[keyPath: keyPath].map(String.init) ?? "" },
            set: { rule[keyPath: keyPath] = UInt16($0) }
        )
    }
}
