import SwiftUI
import GhostVMKit

@available(macOS 13.0, *)
struct AliasListView: View {
    @Binding var aliases: [NetworkAlias]
    @State private var editingAlias: NetworkAlias?
    @State private var isAdding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Aliases:")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button {
                    editingAlias = NetworkAlias()
                    isAdding = true
                } label: {
                    Label("Add", systemImage: "plus")
                        .labelStyle(.iconOnly)
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("aliases.addButton")
            }

            if aliases.isEmpty {
                Text("No aliases")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 6)
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        Text("Name")
                            .frame(width: 100, alignment: .leading)
                        Text("Type")
                            .frame(width: 80, alignment: .leading)
                        Text("Entries")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("")
                            .frame(width: 28)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)

                    Divider()

                    ForEach(aliases) { alias in
                        HStack(spacing: 0) {
                            Text(alias.name)
                                .font(.caption.weight(.medium))
                                .frame(width: 100, alignment: .leading)
                            Text(alias.type.rawValue)
                                .font(.caption)
                                .frame(width: 80, alignment: .leading)
                            Text(alias.entries.joined(separator: ", "))
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button {
                                aliases.removeAll { $0.id == alias.id }
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
                            editingAlias = alias
                            isAdding = false
                        }

                        if alias.id != aliases.last?.id {
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
            get: { editingAlias != nil },
            set: { if !$0 { editingAlias = nil; isAdding = false } }
        )) {
            if var alias = editingAlias {
                aliasEditor(alias: Binding(
                    get: { alias },
                    set: { alias = $0; editingAlias = $0 }
                ))
            }
        }
    }

    @ViewBuilder
    private func aliasEditor(alias: Binding<NetworkAlias>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isAdding ? "New Alias" : "Edit Alias")
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("Name:")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 70, alignment: .trailing)
                    TextField("web_servers", text: alias.name)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("alias.nameField")
                }
                GridRow {
                    Text("Type:")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 70, alignment: .trailing)
                    Picker("", selection: alias.type) {
                        Text("Hosts").tag(AliasType.hosts)
                        Text("Networks").tag(AliasType.networks)
                        Text("Ports").tag(AliasType.ports)
                    }
                    .labelsHidden()
                    .frame(width: 140)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Entries:")
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    Button {
                        alias.wrappedValue.entries.append("")
                    } label: {
                        Label("Add", systemImage: "plus")
                            .labelStyle(.iconOnly)
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                }

                if alias.wrappedValue.entries.isEmpty {
                    Text("No entries")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                        .padding(.vertical, 4)
                } else {
                    ForEach(alias.wrappedValue.entries.indices, id: \.self) { idx in
                        HStack(spacing: 4) {
                            TextField(placeholderForType(alias.wrappedValue.type), text: Binding(
                                get: { alias.wrappedValue.entries[idx] },
                                set: { alias.wrappedValue.entries[idx] = $0 }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))

                            Button {
                                alias.wrappedValue.entries.remove(at: idx)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.secondary.opacity(0.5))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    editingAlias = nil
                    isAdding = false
                }
                .keyboardShortcut(.cancelAction)
                Button("Save") {
                    // Remove empty entries before saving
                    alias.wrappedValue.entries.removeAll { $0.isEmpty }
                    if isAdding {
                        aliases.append(alias.wrappedValue)
                    } else if let idx = aliases.firstIndex(where: { $0.id == alias.wrappedValue.id }) {
                        aliases[idx] = alias.wrappedValue
                    }
                    editingAlias = nil
                    isAdding = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(alias.wrappedValue.name.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func placeholderForType(_ type: AliasType) -> String {
        switch type {
        case .hosts: return "10.100.0.5"
        case .networks: return "192.168.1.0/24"
        case .ports: return "443"
        }
    }
}
