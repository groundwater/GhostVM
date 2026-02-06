import Foundation
import AppKit

@MainActor
final class App2AppDelegate: NSObject, NSApplicationDelegate {
    static weak var sharedStore: App2VMStore? {
        didSet {
            if let store = sharedStore {
                flushPending(to: store)
            }
        }
    }

    private static var pendingURLs: [URL] = []

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let urls = filenames.map { URL(fileURLWithPath: $0) }
        if let store = Self.sharedStore {
            DispatchQueue.main.async {
                store.addBundles(from: urls)
            }
        } else {
            Self.pendingURLs.append(contentsOf: urls)
        }
        sender.reply(toOpenOrPrint: .success)
    }

    private static func flushPending(to store: App2VMStore) {
        guard !pendingURLs.isEmpty else { return }
        let urls = pendingURLs
        pendingURLs.removeAll()
        DispatchQueue.main.async {
            store.addBundles(from: urls)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppIconAdapter.shared.start()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // VMs run in independent helper processes — let the main app quit immediately.
        return .terminateNow
    }
}
