import SwiftUI

@main
struct GhostFileApp: App {
    var body: some Scene {
        WindowGroup("GhostFile") {
            GhostFileContentView()
                .frame(minWidth: 720, minHeight: 560)
        }
        .defaultSize(width: 820, height: 650)
    }
}
