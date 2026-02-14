import Foundation
import AppKit
import Sparkle

@MainActor
final class App2AppDelegate: NSObject, NSApplicationDelegate {
    let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    static weak var sharedStore: App2VMStore? {
        didSet {
            NSLog("[App2AppDelegate] sharedStore set: \(sharedStore != nil)")
            if let store = sharedStore {
                flushPending(to: store)
            }
        }
    }

    private static var pendingURLs: [URL] = []

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        NSLog("[App2AppDelegate] openFiles called with \(filenames.count) files: \(filenames)")
        let urls = filenames.map { URL(fileURLWithPath: $0) }
        if let store = Self.sharedStore {
            NSLog("[App2AppDelegate] store available, dispatching immediately")
            DispatchQueue.main.async {
                store.addBundles(from: urls)
                Self.launchOrFocusVMs(urls, store)
            }
        } else {
            NSLog("[App2AppDelegate] store nil, queuing \(urls.count) pending URLs")
            Self.pendingURLs.append(contentsOf: urls)
        }
        sender.reply(toOpenOrPrint: .success)
    }

    private static func flushPending(to store: App2VMStore) {
        guard !pendingURLs.isEmpty else { return }
        let urls = pendingURLs
        NSLog("[App2AppDelegate] flushPending: \(urls.count) URLs")
        pendingURLs.removeAll()
        DispatchQueue.main.async {
            store.addBundles(from: urls)
            launchOrFocusVMs(urls, store)
        }
    }

    /// Called from SwiftUI .onOpenURL and from the NSApplicationDelegate openFiles path.
    static func handleOpenURLs(_ urls: [URL], store: App2VMStore) {
        launchOrFocusVMs(urls, store)
    }

    private static func launchOrFocusVMs(_ urls: [URL], _ store: App2VMStore) {
        let registry = App2VMSessionRegistry.shared
        for url in urls {
            guard url.pathExtension.lowercased() == "ghostvm" else {
                NSLog("[App2AppDelegate] skipping non-ghostvm: \(url.lastPathComponent)")
                continue
            }
            guard let vm = store.vm(for: url.path) else {
                NSLog("[App2AppDelegate] vm(for:) returned nil for: \(url.path)")
                continue
            }
            guard !vm.needsInstall else {
                NSLog("[App2AppDelegate] skipping, needsInstall: \(vm.name)")
                continue
            }

            let s = vm.status.lowercased()
            NSLog("[App2AppDelegate] VM '\(vm.name)' status='\(vm.status)'")
            if s.contains("running") || s.contains("starting") {
                NSLog("[App2AppDelegate] activating helper for '\(vm.name)'")
                registry.session(for: vm.bundleURL.standardizedFileURL.path)?.activateHelper()
            } else {
                NSLog("[App2AppDelegate] launching VM '\(vm.name)'")
                registry.startVM(bundleURL: vm.bundleURL, store: store, vmID: vm.id)
            }
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
