import SwiftUI
import GhostVMKit

@available(macOS 13.0, *)
struct NetworkRuleListView: View {
    @Binding var rules: [NetworkRule]
    @State private var editingRule: NetworkRule?
    @State private var isAddingRule = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Rules:")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button {
                    editingRule = NetworkRule()
                    isAddingRule = true
                } label: {
                    Label("Add", systemImage: "plus")
                        .labelStyle(.iconOnly)
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("networkRules.addButton")
            }

            // Quick-add presets
            HStack(spacing: 6) {
                Text("Quick Add:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Block LAN") { addPreset(.blockLAN) }
                    .controlSize(.small)
                    .accessibilityIdentifier("networkRules.presetBlockLAN")
                Button("Block Internet") { addPreset(.blockInternet) }
                    .controlSize(.small)
                    .accessibilityIdentifier("networkRules.presetBlockInternet")
                Button("Allow DNS Only") { addPreset(.allowDNSOnly) }
                    .controlSize(.small)
                    .accessibilityIdentifier("networkRules.presetAllowDNS")
                Button("Block Multicast") { addPreset(.blockMulticast) }
                    .controlSize(.small)
                    .accessibilityIdentifier("networkRules.presetBlockMulticast")
            }

            if rules.isEmpty {
                Text("No rules configured")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 10)
                    .accessibilityIdentifier("networkRules.emptyPlaceholder")
            } else {
                // Rule table
                VStack(spacing: 0) {
                    // Header
                    HStack(spacing: 0) {
                        Text("")
                            .frame(width: 28)
                        Text("Action")
                            .frame(width: 60, alignment: .leading)
                        Text("Layer")
                            .frame(width: 36, alignment: .leading)
                        Text("Zone")
                            .frame(width: 40, alignment: .leading)
                        Text("Match")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("Dir")
                            .frame(width: 40, alignment: .leading)
                        Text("")
                            .frame(width: 28)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)

                    Divider()

                    ForEach(rules) { rule in
                        ruleRow(rule)
                        if rule.id != rules.last?.id {
                            Divider().padding(.leading, 6)
                        }
                    }
                    .onMove { source, destination in
                        rules.move(fromOffsets: source, toOffset: destination)
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

                Text("Drag to reorder \u{2921}")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .sheet(isPresented: Binding(
            get: { editingRule != nil },
            set: { if !$0 { editingRule = nil; isAddingRule = false } }
        )) {
            if var rule = editingRule {
                NetworkRuleEditorView(
                    rule: Binding(
                        get: { rule },
                        set: { rule = $0; editingRule = $0 }
                    ),
                    onSave: {
                        if isAddingRule {
                            rules.append(rule)
                        } else if let idx = rules.firstIndex(where: { $0.id == rule.id }) {
                            rules[idx] = rule
                        }
                        editingRule = nil
                        isAddingRule = false
                    },
                    onCancel: {
                        editingRule = nil
                        isAddingRule = false
                    }
                )
            }
        }
    }

    @ViewBuilder
    private func ruleRow(_ rule: NetworkRule) -> some View {
        HStack(spacing: 0) {
            // Enabled toggle
            Toggle("", isOn: Binding(
                get: { rule.enabled },
                set: { newValue in
                    if let idx = rules.firstIndex(where: { $0.id == rule.id }) {
                        rules[idx].enabled = newValue
                    }
                }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .frame(width: 28)

            // Action
            Text(rule.action.rawValue.capitalized)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(rule.action == .block ? .red : (rule.action == .allow ? .green : .orange))
                .frame(width: 60, alignment: .leading)

            // Layer
            Text(rule.layer.rawValue.uppercased())
                .font(.system(.caption, design: .monospaced))
                .frame(width: 36, alignment: .leading)

            // Zone
            Text(rule.zoneLabel)
                .font(.system(.caption, design: .monospaced))
                .frame(width: 40, alignment: .leading)

            // Match summary
            Text(rule.matchSummary)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Direction
            Text(rule.directionLabel)
                .font(.system(.caption, design: .monospaced))
                .frame(width: 40, alignment: .leading)

            // Remove button
            Button {
                rules.removeAll { $0.id == rule.id }
            } label: {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.secondary.opacity(0.5))
            }
            .buttonStyle(.plain)
            .frame(width: 28)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            editingRule = rule
            isAddingRule = false
        }
    }

    private enum Preset {
        case blockLAN, blockInternet, allowDNSOnly, blockMulticast
    }

    private func addPreset(_ preset: Preset) {
        switch preset {
        case .blockLAN:
            rules.append(NetworkRule(action: .block, layer: .l3, direction: .both, dstCIDR: "192.168.0.0/16", comment: "Block LAN access"))
            rules.append(NetworkRule(action: .block, layer: .l3, direction: .both, dstCIDR: "10.0.0.0/8", comment: "Block LAN access"))
            rules.append(NetworkRule(action: .block, layer: .l3, direction: .both, dstCIDR: "172.16.0.0/12", comment: "Block LAN access"))
        case .blockInternet:
            rules.append(NetworkRule(action: .block, layer: .l3, direction: .outbound, comment: "Block internet"))
        case .allowDNSOnly:
            rules.append(NetworkRule(action: .allow, layer: .l3, direction: .outbound, ipProtocol: .udp, dstPort: 53, comment: "Allow DNS"))
            rules.append(NetworkRule(action: .block, layer: .l3, direction: .outbound, comment: "Block all other"))
        case .blockMulticast:
            rules.append(NetworkRule(action: .block, layer: .l2, direction: .outbound, blockBroadcast: true, comment: "Block broadcast/multicast"))
        }
    }
}
