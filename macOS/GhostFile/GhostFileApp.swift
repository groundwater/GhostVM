import AppKit
import SwiftUI

@main
struct GhostFileApp: App {
    @StateObject private var library = GhostFileLibrary()
    @StateObject private var mountLibrary = GhostFileMountLibrary()

    init() {
        // SwiftUI does not consistently publish Icon Composer app icons to the
        // live Dock process. Resolve the compiled bundle icon through macOS so
        // the Dock uses the same platform-rendered asset as Finder.
        NSApplication.shared.applicationIconImage = NSWorkspace.shared.icon(
            forFile: Bundle.main.bundlePath
        )
    }

    var body: some Scene {
        WindowGroup("GhostFile") {
            GhostFileContentView()
                .environmentObject(library)
                .environmentObject(mountLibrary)
                .frame(minWidth: 760, minHeight: 420)
        }
        .defaultSize(width: 940, height: 560)

        WindowGroup("GhostFile Details", for: GhostFileItemID.self) { $itemID in
            if let itemID {
                GhostFileDetailView(itemID: itemID)
                    .environmentObject(library)
                    .environmentObject(mountLibrary)
                    .frame(minWidth: 560, minHeight: 520)
            }
        }
        .defaultSize(width: 620, height: 650)

        WindowGroup("Discovered Share", for: DiscoveredGhostFileShare.self) { $share in
            if let share {
                GhostFileDiscoveredDetailView(share: share)
                    .environmentObject(mountLibrary)
                    .frame(minWidth: 520, minHeight: 420)
            }
        }
        .defaultSize(width: 580, height: 500)

        Settings {
            GhostFileSettingsView()
        }
    }
}
