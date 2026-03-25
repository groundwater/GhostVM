import Foundation
import AppKit

@MainActor
final class AppIconAdapter {
    static let shared = AppIconAdapter()

    var iconMode: DemoIconMode {
        didSet {
            UserDefaults.standard.set(iconMode.rawValue, forKey: "appIconMode")
            configureObservation()
            applyIcon()
        }
    }

    private var kvoObservation: NSKeyValueObservation?

    private init() {
        let stored = UserDefaults.standard.string(forKey: "appIconMode")
            .flatMap(DemoIconMode.init(rawValue:)) ?? .system
        self.iconMode = stored
    }

    /// Set the initial icon and begin observing system appearance if needed.
    func start() {
        configureObservation()
        applyIcon()
    }

    private func configureObservation() {
        kvoObservation?.invalidate()
        kvoObservation = nil

        guard iconMode == .system else { return }

        kvoObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor in
                self?.applyIcon()
            }
        }
    }

    private func applyIcon() {
        let name: String
        switch iconMode {
        case .system:
            let isDark = NSApp.effectiveAppearance
                .bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            name = isDark ? "ghostvm-dark" : "ghostvm"
        case .light:
            name = "ghostvm"
        case .dark:
            name = "ghostvm-dark"
        }

        if let image = NSImage(named: name) {
            NSApp.applicationIconImage = image
        }
    }
}
