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

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // If there are active VM sessions, suspend them all before quitting
        guard App2VMSessionRegistry.shared.hasActiveSessions else {
            return .terminateNow
        }

        // Suspend all running VMs, then quit
        App2VMSessionRegistry.shared.suspendAllSessions {
            DispatchQueue.main.async {
                NSApplication.shared.reply(toApplicationShouldTerminate: true)
            }
        }

        return .terminateLater
    }
}
