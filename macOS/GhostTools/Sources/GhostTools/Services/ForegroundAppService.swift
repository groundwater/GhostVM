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

        // Also try again after a short delay (in case workspace isn't ready yet)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.pushCurrentApp()
        }

        // Re-push when a new host client connects (they missed the initial push)
        EventPushServer.shared.onClientConnected = { [weak self] in
            print("[ForegroundAppService] Client connected, pushing current app")
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

        var app = NSWorkspace.shared.frontmostApplication

        // If no frontmost app or it's GhostTools itself, try to find Finder
        if app == nil || app?.bundleIdentifier == ownBundleId {
            app = NSWorkspace.shared.runningApplications.first {
                $0.bundleIdentifier == "com.apple.finder"
            }
        }

        if let app = app {
            print("[ForegroundAppService] Pushing app: \(app.localizedName ?? "unknown") (\(app.bundleIdentifier ?? ""))")

            // If foreground app is NOT Finder, send Finder first (as background)
            if app.bundleIdentifier != "com.apple.finder" {
                if let finder = NSWorkspace.shared.runningApplications.first(where: {
                    $0.bundleIdentifier == "com.apple.finder"
                }) {
                    // Temporarily clear previousBundleId to allow Finder push
                    let savedPrevious = previousBundleId
                    previousBundleId = nil
                    pushApp(finder)
                    previousBundleId = savedPrevious
                }
            }

            // Push the actual foreground app (will become index 0)
            pushApp(app)
        } else {
            print("[ForegroundAppService] No frontmost app found")
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
