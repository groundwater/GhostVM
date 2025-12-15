import Foundation
import AppKit
import UniformTypeIdentifiers

enum SavePanelAdapter {
    static func chooseVMBundleURL(suggestedName: String, completion: @MainActor @escaping (URL?) -> Void) {
        DispatchQueue.main.async {
            let panel = NSSavePanel()
            panel.canCreateDirectories = true
            if #available(macOS 12.0, *) {
                if let packageType = UTType(filenameExtension: "FixieVM") {
                    panel.allowedContentTypes = [packageType]
                }
            } else {
                panel.allowedFileTypes = ["FixieVM"]
                panel.allowsOtherFileTypes = false
            }
            panel.nameFieldStringValue = suggestedName.isEmpty ? "Virtual Machine.FixieVM" : "\(suggestedName).FixieVM"
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
