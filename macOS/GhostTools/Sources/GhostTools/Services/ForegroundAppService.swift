import AppKit

/// Observes the frontmost application and pushes foreground-app events to the host.
/// Events include the app name, bundle ID, and a 128x128 PNG icon (base64-encoded).
/// A 500ms debounce prevents rapid Cmd+Tab from flooding the channel.
final class ForegroundAppService {
    static let shared = ForegroundAppService()

    private var observer: NSObjectProtocol?
    private var debounceTimer: Timer?
    private var previousBundleId: String?
    private let ownBundleId = Bundle.main.bundleIdentifier ?? ""

    private init() {}

    func start() {
        guard observer == nil else { return }
        print("[ForegroundAppService] Starting")

        // Push the current frontmost app immediately
        pushCurrentApp()

        // Re-push when a new host client connects (they missed the initial push)
        EventPushServer.shared.onClientConnected = { [weak self] in
            self?.pushCurrentApp()
        }

        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.scheduleDebounce(app)
        }
    }

    func stop() {
        EventPushServer.shared.onClientConnected = nil
        if let obs = observer {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            observer = nil
        }
        debounceTimer?.invalidate()
        debounceTimer = nil
        previousBundleId = nil
    }

    private func pushCurrentApp() {
        previousBundleId = nil  // Force re-push even if same app
        if let app = NSWorkspace.shared.frontmostApplication {
            pushApp(app)
        }
    }

    private func scheduleDebounce(_ app: NSRunningApplication) {
        debounceTimer?.invalidate()
        debounceTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            self?.pushApp(app)
        }
    }

    private func pushApp(_ app: NSRunningApplication) {
        let bundleId = app.bundleIdentifier ?? ""

        // Skip our own app and duplicates
        if bundleId == ownBundleId || bundleId == previousBundleId { return }
        previousBundleId = bundleId

        let name = app.localizedName ?? bundleId

        // Extract icon as 128x128 PNG, base64 encode
        var iconBase64: String? = nil
        if let icon = app.icon {
            let size = NSSize(width: 128, height: 128)
            let resized = NSImage(size: size)
            resized.lockFocus()
            icon.draw(in: NSRect(origin: .zero, size: size),
                      from: NSRect(origin: .zero, size: icon.size),
                      operation: .copy,
                      fraction: 1.0)
            resized.unlockFocus()

            if let tiff = resized.tiffRepresentation,
               let bitmap = NSBitmapImageRep(data: tiff),
               let pngData = bitmap.representation(using: .png, properties: [:]) {
                iconBase64 = pngData.base64EncodedString()
            }
        }

        EventPushServer.shared.pushEvent(.app(name: name, bundleId: bundleId, iconBase64: iconBase64))
    }
}
