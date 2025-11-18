import Foundation
import AppKit
import UniformTypeIdentifiers

enum SavePanelAdapter {
    static func chooseVMBundleURL(suggestedName: String, completion: @escaping (URL?) -> Void) {
        DispatchQueue.main.async {
            let panel = NSSavePanel()
            panel.canCreateDirectories = true
            if #available(macOS 12.0, *) {
                if let packageType = UTType(filenameExtension: "GhostVM") {
                    panel.allowedContentTypes = [packageType]
                }
            } else {
                panel.allowedFileTypes = ["GhostVM"]
                panel.allowsOtherFileTypes = false
            }
            panel.nameFieldStringValue = suggestedName.isEmpty ? "Virtual Machine.GhostVM" : "\(suggestedName).GhostVM"
            panel.prompt = "Create"
            panel.title = "Create Virtual Machine"

            panel.begin { response in
                guard response == .OK, let url = panel.url else {
                    completion(nil)
                    return
                }
                completion(url)
            }
        }
    }
}

