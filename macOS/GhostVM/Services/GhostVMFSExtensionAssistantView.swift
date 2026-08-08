import AppKit
import SwiftUI

struct GhostVMFSExtensionAssistantView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var manager: GhostVMFSExtensionManager

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 14) {
                statusSymbol
                Text(title)
                    .font(.title2.weight(.semibold))
                Text(detail)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 440)
            }
            .padding(.horizontal, 32)
            .padding(.top, 30)
            .padding(.bottom, 24)

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                helperRow(
                    symbol: "shippingbox.fill",
                    title: "Embedded with GhostVM",
                    detail: "GhostVMFS is installed and repaired as part of the GhostVM app."
                )
                helperRow(
                    symbol: "checkmark.shield.fill",
                    title: "Your approval",
                    detail: "Install / Repair registers GhostVMFS, then opens the File System Extensions switch."
                )
            }
            .padding(24)

            Divider()

            HStack {
                if manager.health.requiresAttention {
                    Button("Later") { dismiss() }
                }
                Spacer()
                Button("Scan Again") {
                    Task { await manager.refresh() }
                }
                .disabled(manager.isWorking || manager.health == .checking)

                primaryAction
            }
            .padding(18)
        }
        .frame(width: 540)
        .interactiveDismissDisabled(manager.isWorking)
    }

    @ViewBuilder
    private var statusSymbol: some View {
        if manager.isWorking || manager.health == .checking {
            ProgressView()
                .controlSize(.large)
                .frame(width: 52, height: 52)
        } else {
            Image(systemName: symbolName)
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(manager.health == .ready ? Color.green : Color.orange)
                .frame(width: 52, height: 52)
        }
    }

    @ViewBuilder
    private var primaryAction: some View {
        switch manager.health {
        case .ready:
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
        case .needsApplicationInstall, .missingEmbeddedExtension:
            Button("Open Applications") {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications", isDirectory: true))
            }
            .buttonStyle(.borderedProminent)
        case .notRegistered, .duplicateRegistrations, .disabled:
            if manager.repairAvailable {
                Button(manager.isWorking ? "Repairing..." : "Install / Repair Extension") {
                    Task { await manager.repairRegistration() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(manager.isWorking)
            } else {
                Button("Open File System Settings") { manager.openSettings() }
                    .buttonStyle(.borderedProminent)
            }
        case .scanFailed:
            Button("Open File System Settings") { manager.openSettings() }
                .buttonStyle(.borderedProminent)
        case .checking:
            EmptyView()
        }
    }

    private var title: String {
        if manager.isWorking { return "Repairing GhostVMFS..." }
        switch manager.health {
        case .checking: return "Checking GhostVMFS..."
        case .ready: return "GhostVMFS Is Ready"
        case .needsApplicationInstall: return "Move GhostVM to Applications"
        case .missingEmbeddedExtension: return "GhostVMFS Is Missing"
        case .notRegistered: return "Install GhostVMFS"
        case .duplicateRegistrations: return "Repair GhostVMFS"
        case .disabled: return "Enable GhostVMFS"
        case .scanFailed: return "Unable to Check GhostVMFS"
        }
    }

    private var detail: String {
        if manager.isWorking {
            return "GhostVM is rebuilding the extension registration used by System Settings."
        }
        if let statusDetail = manager.statusDetail { return statusDetail }
        if let errorMessage = manager.errorMessage { return errorMessage }
        switch manager.health {
        case .checking: return "Scanning macOS file system extension registration."
        case .ready: return "The embedded extension is registered, enabled, and ready for guest directory mounts."
        case .needsApplicationInstall: return "Drag GhostVM into Applications, then open that installed copy."
        case .missingEmbeddedExtension: return "Reinstall GhostVM from the disk image to restore its embedded extension."
        case .notRegistered: return "macOS has not registered the extension bundled with this app."
        case .duplicateRegistrations: return "More than one copy is registered, so macOS may launch the wrong one."
        case .disabled: return "Install / Repair refreshes GhostVMFS so you can enable it in System Settings."
        case .scanFailed(let message): return message
        }
    }

    private var symbolName: String {
        switch manager.health {
        case .ready: return "checkmark.circle.fill"
        case .needsApplicationInstall: return "arrow.down.app.fill"
        case .missingEmbeddedExtension: return "xmark.app.fill"
        case .notRegistered: return "externaldrive.badge.plus"
        case .duplicateRegistrations: return "wrench.and.screwdriver.fill"
        case .disabled: return "externaldrive.fill.badge.exclamationmark"
        case .scanFailed: return "exclamationmark.triangle.fill"
        case .checking: return "externaldrive.fill"
        }
    }

    private func helperRow(symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
