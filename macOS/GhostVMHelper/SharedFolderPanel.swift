import AppKit
import SwiftUI
import GhostVMKit

/// Delegate protocol for shared folder panel actions
protocol SharedFolderPanelDelegate: AnyObject {
    func sharedFolderPanel(_ panel: SharedFolderPanel, didAddFolder path: String, readOnly: Bool)
    func sharedFolderPanel(_ panel: SharedFolderPanel, didRemoveFolderWithID id: UUID)
    func sharedFolderPanel(_ panel: SharedFolderPanel, didSetReadOnly readOnly: Bool, forFolderWithID id: UUID)
}

/// Sheet-based shared folder editor (immune to FocusableVMView responder stealing)
final class SharedFolderPanel: NSObject {

    weak var delegate: SharedFolderPanelDelegate?

    private var sheetWindow: NSWindow?
    private var entries: [SharedFolderEntry] = []
    private var model: SharedFolderPanelModel?

    func show(in parentWindow: NSWindow) {
        let panelModel = SharedFolderPanelModel()
        panelModel.entries = entries
        panelModel.onAdd = { [weak self] path, readOnly in
            guard let self else { return }
            self.delegate?.sharedFolderPanel(self, didAddFolder: path, readOnly: readOnly)
        }
        panelModel.onRemove = { [weak self] id in
            guard let self else { return }
            self.delegate?.sharedFolderPanel(self, didRemoveFolderWithID: id)
        }
        panelModel.onToggleReadOnly = { [weak self] id, readOnly in
            guard let self else { return }
            self.delegate?.sharedFolderPanel(self, didSetReadOnly: readOnly, forFolderWithID: id)
        }
        panelModel.onDone = { [weak self] in
            self?.close()
        }
        self.model = panelModel

        let rootView = SharedFolderPanelView(model: panelModel)
        let hostingController = NSHostingController(rootView: rootView)
        hostingController.sizingOptions = []
        hostingController.preferredContentSize = NSSize(width: 480, height: 300)

        let sheetWindow = NSWindow(contentViewController: hostingController)
        sheetWindow.styleMask = [.titled, .closable]
        sheetWindow.title = "Shared Folders"
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

    func setEntries(_ newEntries: [SharedFolderEntry]) {
        entries = newEntries
        model?.entries = newEntries
    }
}

// MARK: - SwiftUI Model

private class SharedFolderPanelModel: ObservableObject {
    @Published var entries: [SharedFolderEntry] = []

    var onAdd: ((String, Bool) -> Void)? = nil
    var onRemove: ((UUID) -> Void)? = nil
    var onToggleReadOnly: ((UUID, Bool) -> Void)? = nil
    var onDone: (() -> Void)? = nil
}

// MARK: - SwiftUI View

@available(macOS 13.0, *)
private struct SharedFolderPanelView: View {
    @ObservedObject var model: SharedFolderPanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SharedFolderCallbackListView(
                folders: model.entries,
                onAdd: { path, readOnly in
                    model.onAdd?(path, readOnly)
                },
                onRemove: { id in
                    model.onRemove?(id)
                },
                onToggleReadOnly: { id, readOnly in
                    model.onToggleReadOnly?(id, readOnly)
                }
            )
            .frame(maxHeight: .infinity, alignment: .top)

            HStack {
                Spacer()
                Button("Done") {
                    model.onDone?()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(minWidth: 440, maxHeight: .infinity)
    }
}
