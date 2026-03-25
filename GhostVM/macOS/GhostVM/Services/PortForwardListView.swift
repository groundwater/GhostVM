import SwiftUI
import GhostVMKit

// MARK: - Port Forward Entry (display model for runtime panels)

struct PortForwardEntry: Identifiable {
    let id = UUID()
    var hostPort: UInt16
    var guestPort: UInt16
    var enabled: Bool
    var isAutoMapped: Bool = false
    var processName: String? = nil
}

// MARK: - Remove Button with Hover

@available(macOS 13.0, *)
private struct RemoveButtonView: View {
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "minus.circle.fill")
                .foregroundColor(isHovered ? .red : .secondary.opacity(0.5))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Port Forward List (Binding mode for EditVMView)

@available(macOS 13.0, *)
struct PortForwardListView: View {
    @Binding var forwards: [PortForwardConfig]

    @State private var hostPortText = ""
    @State private var guestPortText = ""
    @State private var errorMessage: String?
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case host, guest
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if forwards.isEmpty && hostPortText.isEmpty && guestPortText.isEmpty {
                Text("No port forwards")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 10)
                    .accessibilityIdentifier("portForward.noForwardsPlaceholder")
            }

            ForEach(forwards) { forward in
                HStack(spacing: 6) {
                    Text(verbatim: "localhost:\(forward.hostPort)")
                        .font(.system(.body, design: .monospaced))
                    Image(systemName: "arrow.right")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    Text(verbatim: "guest:\(forward.guestPort)")
                        .font(.system(.body, design: .monospaced))
                    Spacer()
                    RemoveButtonView {
                        forwards.removeAll { $0.id == forward.id }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)

                if forward.id != forwards.last?.id {
                    Divider().padding(.leading, 10)
                }
            }

            if !forwards.isEmpty {
                Divider()
            }

            // Add row
            HStack(spacing: 6) {
                TextField("Host port", text: $hostPortText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                    .focused($focusedField, equals: .host)
                    .onSubmit { focusedField = .guest }
                    .accessibilityIdentifier("portForward.hostPortField")

                Image(systemName: "arrow.right")
                    .foregroundStyle(.secondary)
                    .font(.caption)

                TextField("Guest port", text: $guestPortText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                    .focused($focusedField, equals: .guest)
                    .onSubmit { addForward() }
                    .accessibilityIdentifier("portForward.guestPortField")

                Button("Add") { addForward() }
                    .disabled(hostPortText.isEmpty || guestPortText.isEmpty)
                    .accessibilityIdentifier("portForward.addButton")

                Button("Cancel") { clearFields() }
                    .disabled(hostPortText.isEmpty && guestPortText.isEmpty && errorMessage == nil)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.background)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(.separator, lineWidth: 1)
        )
    }

    private func addForward() {
        errorMessage = nil
        guard let host = UInt16(hostPortText), host > 0 else {
            errorMessage = "Invalid host port"
            return
        }
        guard let guest = UInt16(guestPortText), guest > 0 else {
            errorMessage = "Invalid guest port"
            return
        }
        if forwards.contains(where: { $0.hostPort == host }) {
            errorMessage = "Host port \(host) already in use"
            return
        }
        forwards.append(PortForwardConfig(hostPort: host, guestPort: guest, enabled: true))
        clearFields()
        focusedField = .host
    }

    private func clearFields() {
        hostPortText = ""
        guestPortText = ""
        errorMessage = nil
    }
}

// MARK: - Port Forward List (Callback mode for runtime)

@available(macOS 13.0, *)
struct PortForwardCallbackListView: View {
    var forwards: [PortForwardConfig]
    var onAdd: (UInt16, UInt16) -> String?  // returns error message or nil
    var onRemove: (UInt16) -> Void

    @State private var hostPortText = ""
    @State private var guestPortText = ""
    @State private var errorMessage: String?
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case host, guest
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if forwards.isEmpty && hostPortText.isEmpty && guestPortText.isEmpty {
                Text("No port forwards")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 10)
            }

            ForEach(forwards) { forward in
                HStack(spacing: 6) {
                    Text(verbatim: "localhost:\(forward.hostPort)")
                        .font(.system(.body, design: .monospaced))
                    Image(systemName: "arrow.right")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    Text(verbatim: "guest:\(forward.guestPort)")
                        .font(.system(.body, design: .monospaced))
                    Spacer()
                    RemoveButtonView {
                        onRemove(forward.hostPort)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)

                if forward.id != forwards.last?.id {
                    Divider().padding(.leading, 10)
                }
            }

            Spacer()

            Divider()

            // Add row
            HStack(spacing: 6) {
                TextField("Host port", text: $hostPortText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                    .focused($focusedField, equals: .host)
                    .onSubmit { focusedField = .guest }

                Image(systemName: "arrow.right")
                    .foregroundStyle(.secondary)
                    .font(.caption)

                TextField("Guest port", text: $guestPortText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                    .focused($focusedField, equals: .guest)
                    .onSubmit { addForward() }

                Button("Add") { addForward() }
                    .disabled(hostPortText.isEmpty || guestPortText.isEmpty)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
            }
        }
        .frame(maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.background)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(.separator, lineWidth: 1)
        )
    }

    private func addForward() {
        errorMessage = nil
        guard let host = UInt16(hostPortText), host > 0 else {
            errorMessage = "Invalid host port"
            return
        }
        guard let guest = UInt16(guestPortText), guest > 0 else {
            errorMessage = "Invalid guest port"
            return
        }
        if let error = onAdd(host, guest) {
            errorMessage = error
            return
        }
        clearFields()
        focusedField = .host
    }

    private func clearFields() {
        hostPortText = ""
        guestPortText = ""
        errorMessage = nil
    }
}
