import AppKit

/// Service that periodically scans mounted volumes for a newer GhostTools.app
/// and offers to install it via an NSAlert popup.
@MainActor
final class AutoUpdateService {
    static let shared = AutoUpdateService()
    private init() {}

    private var timer: Timer?
    private weak var appDelegate: AppDelegate?
    /// Build numbers the user has dismissed with "Not Now" (in-memory only)
    private var suppressedBuilds: Set<String> = []

    /// Check interval: 5 minutes
    private let checkInterval: TimeInterval = 300

    func start(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
        print("[AutoUpdate] Service started")

        // Check immediately (deferred to next run loop to avoid blocking launch)
        DispatchQueue.main.async { [weak self] in
            self?.checkForUpdate()
        }

        // Schedule periodic checks
        timer = Timer.scheduledTimer(withTimeInterval: checkInterval, repeats: true) { [weak self] _ in
            self?.checkForUpdate()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        print("[AutoUpdate] Service stopped")
    }

    private func checkForUpdate() {
        guard PermissionsWindow.isAutoUpdateEnabled else { return }

        let currentVersion = AppVersion(kGhostToolsBuild)
        guard currentVersion.isValid else {
            print("[AutoUpdate] Cannot parse current build version: \(kGhostToolsBuild)")
            return
        }

        // Scan all /Volumes/*/GhostTools.app
        let fm = FileManager.default
        guard let volumes = try? fm.contentsOfDirectory(atPath: "/Volumes") else { return }

        var bestCandidate: (path: String, version: String, build: String, buildVersion: AppVersion)?

        for volume in volumes {
            let candidatePath = "/Volumes/\(volume)/GhostTools.app"
            let plistPath = candidatePath + "/Contents/Info.plist"

            guard fm.fileExists(atPath: plistPath),
                  let plist = NSDictionary(contentsOfFile: plistPath),
                  let candidateBuild = plist["CFBundleVersion"] as? String else {
                continue
            }

            let candidateVersion = AppVersion(candidateBuild)
            guard candidateVersion.isValid, candidateVersion > currentVersion else {
                continue
            }

            // Also verify it has an executable
            guard fm.fileExists(atPath: candidatePath + "/Contents/MacOS/GhostTools") else {
                continue
            }

            let candidateDisplayVersion = plist["CFBundleShortVersionString"] as? String ?? "unknown"

            if let best = bestCandidate {
                if candidateVersion > best.buildVersion {
                    bestCandidate = (candidatePath, candidateDisplayVersion, candidateBuild, candidateVersion)
                }
            } else {
                bestCandidate = (candidatePath, candidateDisplayVersion, candidateBuild, candidateVersion)
            }
        }

        guard let candidate = bestCandidate else { return }

        // Check if this build was suppressed
        if suppressedBuilds.contains(candidate.build) { return }

        print("[AutoUpdate] Found newer build: v\(candidate.version) (build \(candidate.build)) at \(candidate.path)")
        showUpdateAlert(candidate: candidate)
    }

    private func showUpdateAlert(candidate: (path: String, version: String, build: String, buildVersion: AppVersion)) {
        let alert = NSAlert()
        alert.messageText = "GhostTools Update Available"
        alert.informativeText = "Version \(candidate.version) (build \(candidate.build)) is available. You are running version \(kGhostToolsVersion) (build \(kGhostToolsBuild))."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Update Now")
        alert.addButton(withTitle: "Not Now")

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()

        if response == .alertFirstButtonReturn {
            performUpdate(from: candidate.path)
        } else {
            // Suppress this build until restart
            suppressedBuilds.insert(candidate.build)
            print("[AutoUpdate] User deferred update for build \(candidate.build)")
        }
    }

    private func performUpdate(from sourcePath: String) {
        guard let ad = appDelegate else {
            print("[AutoUpdate] No app delegate, cannot install")
            return
        }

        print("[AutoUpdate] Installing from \(sourcePath)...")
        let error = ad.installFromPath(sourcePath)

        if let error = error {
            print("[AutoUpdate] Install failed: \(error)")
            let alert = NSAlert()
            alert.messageText = "Update Failed"
            alert.informativeText = error
            alert.alertStyle = .warning
            alert.runModal()
            return
        }

        print("[AutoUpdate] Install succeeded, restarting...")

        // Restart from /Applications
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = [kApplicationsPath]
        try? task.run()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApplication.shared.terminate(nil)
        }
    }
}
