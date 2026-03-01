import SwiftUI
import GhostVMKit

@available(macOS 13.0, *)
struct RouterNATListView: View {
    @Binding var rules: [PortForwardRule]
    @State private var editingRule: PortForwardRule?
    @State private var isAdding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("NAT Port Forwarding:")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button {
                    editingRule = PortForwardRule()
                    isAdding = true
                } label: {
                    Label("Add", systemImage: "plus")
                        .labelStyle(.iconOnly)
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("routerNAT.addButton")
            }

            if rules.isEmpty {
                Text("No NAT rules")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 6)
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        Text("")
                            .frame(width: 28)
                        Text("Proto")
                            .frame(width: 50, alignment: .leading)
                        Text("Ext Port")
                            .frame(width: 70, alignment: .leading)
                        Text("Internal IP:Port")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("Comment")
                            .frame(width: 100, alignment: .leading)
                        Text("")
                            .frame(width: 28)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)

                    Divider()

                    ForEach(rules) { rule in
                        HStack(spacing: 0) {
                            Image(systemName: rule.enabled ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(rule.enabled ? .green : .secondary)
                                .frame(width: 28)
                            Text(rule.proto.rawValue.uppercased())
                                .font(.system(.caption, design: .monospaced))
                                .frame(width: 50, alignment: .leading)
                            Text("\(rule.externalPort)")
                                .font(.system(.caption, design: .monospaced))
                                .frame(width: 70, alignment: .leading)
                            Text("\(rule.internalIP):\(rule.internalPort)")
                                .font(.system(.caption, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(rule.comment ?? "")
                                .font(.caption)
                                .lineLimit(1)
                                .frame(width: 100, alignment: .leading)
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
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            editingRule = rule
                            isAdding = false
                        }

                        if rule.id != rules.last?.id {
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
            get: { editingRule != nil },
            set: { if !$0 { editingRule = nil; isAdding = false } }
        )) {
            if var rule = editingRule {
                natRuleEditor(rule: Binding(
                    get: { rule },
                    set: { rule = $0; editingRule = $0 }
                ))
            }
        }
    }

    @ViewBuilder
    private func natRuleEditor(rule: Binding<PortForwardRule>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isAdding ? "New NAT Rule" : "Edit NAT Rule")
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("Enabled:")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 90, alignment: .trailing)
                    Toggle("", isOn: rule.enabled)
                        .labelsHidden()
                }
                GridRow {
                    Text("Protocol:")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 90, alignment: .trailing)
                    Picker("", selection: rule.proto) {
                        Text("TCP").tag(IPProtocol.tcp)
                        Text("UDP").tag(IPProtocol.udp)
                        Text("Any").tag(IPProtocol.any)
                    }
                    .labelsHidden()
                    .frame(width: 120)
                }
                GridRow {
                    Text("Ext Port:")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 90, alignment: .trailing)
                    TextField("80", value: rule.externalPort, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("routerNAT.extPortField")
                }
                GridRow {
                    Text("Internal IP:")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 90, alignment: .trailing)
                    TextField("10.100.0.5", text: rule.internalIP)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("routerNAT.internalIPField")
                }
                GridRow {
                    Text("Int Port:")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 90, alignment: .trailing)
                    TextField("80", value: rule.internalPort, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("routerNAT.intPortField")
                }
                GridRow {
                    Text("Comment:")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 90, alignment: .trailing)
                    TextField("Optional", text: Binding(
                        get: { rule.wrappedValue.comment ?? "" },
                        set: { rule.wrappedValue.comment = $0.isEmpty ? nil : $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    editingRule = nil
                    isAdding = false
                }
                .keyboardShortcut(.cancelAction)
                Button("Save") {
                    if isAdding {
                        rules.append(rule.wrappedValue)
                    } else if let idx = rules.firstIndex(where: { $0.id == rule.wrappedValue.id }) {
                        rules[idx] = rule.wrappedValue
                    }
                    editingRule = nil
                    isAdding = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(rule.wrappedValue.internalIP.isEmpty || rule.wrappedValue.externalPort == 0)
            }
        }
        .padding(20)
        .frame(width: 400)
        .fixedSize(horizontal: false, vertical: true)
    }
}
