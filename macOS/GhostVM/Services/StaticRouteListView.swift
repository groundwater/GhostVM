import SwiftUI
import GhostVMKit

@available(macOS 13.0, *)
struct StaticRouteListView: View {
    @Binding var routes: [StaticRoute]
    @State private var editingRoute: StaticRoute?
    @State private var isAdding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Static Routes:")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button {
                    editingRoute = StaticRoute()
                    isAdding = true
                } label: {
                    Label("Add", systemImage: "plus")
                        .labelStyle(.iconOnly)
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("staticRoutes.addButton")
            }

            if routes.isEmpty {
                Text("No static routes")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 6)
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        Text("")
                            .frame(width: 28)
                        Text("Destination")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("Gateway")
                            .frame(width: 130, alignment: .leading)
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

                    ForEach(routes) { route in
                        HStack(spacing: 0) {
                            Image(systemName: route.enabled ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(route.enabled ? .green : .secondary)
                                .frame(width: 28)
                            Text(route.destination)
                                .font(.system(.caption, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(route.gateway)
                                .font(.system(.caption, design: .monospaced))
                                .frame(width: 130, alignment: .leading)
                            Text(route.comment ?? "")
                                .font(.caption)
                                .lineLimit(1)
                                .frame(width: 100, alignment: .leading)
                            Button {
                                routes.removeAll { $0.id == route.id }
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
                            editingRoute = route
                            isAdding = false
                        }

                        if route.id != routes.last?.id {
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
            get: { editingRoute != nil },
            set: { if !$0 { editingRoute = nil; isAdding = false } }
        )) {
            if var route = editingRoute {
                staticRouteEditor(route: Binding(
                    get: { route },
                    set: { route = $0; editingRoute = $0 }
                ))
            }
        }
    }

    @ViewBuilder
    private func staticRouteEditor(route: Binding<StaticRoute>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isAdding ? "New Static Route" : "Edit Static Route")
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("Enabled:")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 90, alignment: .trailing)
                    Toggle("", isOn: route.enabled)
                        .labelsHidden()
                }
                GridRow {
                    Text("Destination:")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 90, alignment: .trailing)
                    TextField("192.168.50.0/24", text: route.destination)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("staticRoute.destinationField")
                }
                GridRow {
                    Text("Gateway:")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 90, alignment: .trailing)
                    TextField("10.100.0.1", text: route.gateway)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("staticRoute.gatewayField")
                }
                GridRow {
                    Text("Comment:")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 90, alignment: .trailing)
                    TextField("Optional", text: Binding(
                        get: { route.wrappedValue.comment ?? "" },
                        set: { route.wrappedValue.comment = $0.isEmpty ? nil : $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    editingRoute = nil
                    isAdding = false
                }
                .keyboardShortcut(.cancelAction)
                Button("Save") {
                    if isAdding {
                        routes.append(route.wrappedValue)
                    } else if let idx = routes.firstIndex(where: { $0.id == route.wrappedValue.id }) {
                        routes[idx] = route.wrappedValue
                    }
                    editingRoute = nil
                    isAdding = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(route.wrappedValue.destination.isEmpty || route.wrappedValue.gateway.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
        .fixedSize(horizontal: false, vertical: true)
    }
}
