import AppKit
import SwiftUI
import GhostVMKit

/// Delegate protocol for port forward panel actions
protocol PortForwardPanelDelegate: AnyObject {
    func portForwardPanel(_ panel: PortForwardPanel, didAddForward hostPort: UInt16, guestPort: UInt16)
    func portForwardPanel(_ panel: PortForwardPanel, didRemoveForwardWithHostPort hostPort: UInt16)
}

/// Sheet-based port forward editor (immune to FocusableVMView responder stealing)
final class PortForwardPanel: NSObject {

    weak var delegate: PortForwardPanelDelegate?

    private var sheetWindow: NSWindow?
    private var entries: [PortForwardEntry] = []
    private var model: PortForwardPanelModel?

    func show(in parentWindow: NSWindow) {
        let panelModel = PortForwardPanelModel()
        panelModel.entries = entries.map {
            PortForwardConfig(hostPort: $0.hostPort, guestPort: $0.guestPort, enabled: $0.enabled)
        }
        panelModel.onAdd = { [weak self] host, guest in
            guard let self else { return nil }
            self.delegate?.portForwardPanel(self, didAddForward: host, guestPort: guest)
            return nil  // delegate handles validation; errors come back via showError
        }
        panelModel.onRemove = { [weak self] hostPort in
            guard let self else { return }
            self.delegate?.portForwardPanel(self, didRemoveForwardWithHostPort: hostPort)
        }
        panelModel.onDone = { [weak self] in
            self?.close()
        }
        self.model = panelModel

        let rootView = PortForwardPanelView(model: panelModel)
        let hostingController = NSHostingController(rootView: rootView)
        hostingController.sizingOptions = []
        hostingController.preferredContentSize = NSSize(width: 380, height: 300)

        let sheetWindow = NSWindow(contentViewController: hostingController)
        sheetWindow.styleMask = [.titled, .closable]
        sheetWindow.title = "Port Forwards"
        self.sheetWindow = sheetWindow

        parentWindow.beginSheet(sheetWindow)
    }

    func close() {
        if let sheet = sheetWindow, let parent = sheet.sheetParent {
            parent.endSheet(sheet)
        }
        sheetWindow = nil
        model = nil
    }

    func setEntries(_ newEntries: [PortForwardEntry]) {
        entries = newEntries
        model?.entries = newEntries.map {
            PortForwardConfig(hostPort: $0.hostPort, guestPort: $0.guestPort, enabled: $0.enabled)
        }
    }

    func showError(_ message: String) {
        model?.externalError = message
    }
}

// MARK: - SwiftUI Model

private class PortForwardPanelModel: ObservableObject {
    @Published var entries: [PortForwardConfig] = []
    @Published var externalError: String?

    var onAdd: ((UInt16, UInt16) -> String?)? = nil
    var onRemove: ((UInt16) -> Void)? = nil
    var onDone: (() -> Void)? = nil
}

// MARK: - SwiftUI View

@available(macOS 13.0, *)
private struct PortForwardPanelView: View {
    @ObservedObject var model: PortForwardPanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PortForwardCallbackListView(
                forwards: model.entries,
                onAdd: { host, guest in
                    model.externalError = nil
                    return model.onAdd?(host, guest)
                },
                onRemove: { hostPort in
                    model.onRemove?(hostPort)
                }
            )
            .frame(maxHeight: .infinity, alignment: .top)

            if let error = model.externalError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    model.onDone?()
                }
                .keyboardShortcut(.cancelAction)
                Button("Done") {
                    model.onDone?()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(minWidth: 340, maxHeight: .infinity)
    }
}
