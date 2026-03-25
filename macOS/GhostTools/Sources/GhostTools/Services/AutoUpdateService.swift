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
    private var updateWindow: NSWindow?
    /// Candidate info for the pending update (used by button actions)
    private var pendingCandidate: (path: String, build: String)?

    private let kSkippedVersionKey = "org.ghostvm.ghosttools.skippedVersion"

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

        // Check if this build was suppressed (in-memory) or permanently skipped
        if suppressedBuilds.contains(candidate.build) { return }
        if let skipped = UserDefaults.standard.string(forKey: kSkippedVersionKey),
           skipped == candidate.build { return }

        print("[AutoUpdate] Found newer build: v\(candidate.version) (build \(candidate.build)) at \(candidate.path)")
        showUpdateWindow(candidate: candidate)
    }

    private func showUpdateWindow(candidate: (path: String, version: String, build: String, buildVersion: AppVersion)) {
        // Reuse existing window if already showing
        if let w = updateWindow {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        pendingCandidate = (path: candidate.path, build: candidate.build)

        // --- Layout constants matching Sparkle's Software Update window ---
        let winW: CGFloat = 660
        let topPad: CGFloat = 20
        let leftPad: CGFloat = 24
        let rightPad: CGFloat = 24
        let iconSize: CGFloat = 64
        let iconTextGap: CGFloat = 16
        let textX = leftPad + iconSize + iconTextGap
        let textW = winW - textX - rightPad

        // Title
        let titleFont = NSFont.boldSystemFont(ofSize: 16)
        let titleStr = "A new version of GhostTools is available!"

        // Subtitle
        let subtitleFont = NSFont.systemFont(ofSize: 13)
        let subtitleStr = "GhostTools \(candidate.version) is now available\u{2014}you have \(kGhostToolsVersion). Would you like to install it now?"

        // Release Notes label
        let releaseNotesLabelFont = NSFont.boldSystemFont(ofSize: 13)
        let releaseNotesLabelStr = "Release Notes:"

        // Measure text heights
        let titleH = ceil(measureTextHeight(titleStr, font: titleFont, width: textW))
        let subtitleH = ceil(measureTextHeight(subtitleStr, font: subtitleFont, width: textW))
        let releaseNotesLabelH: CGFloat = 18

        // Gaps and sizes
        let titleSubtitleGap: CGFloat = 6
        let subtitleToRNLabelGap: CGFloat = 14
        let rnLabelToScrollGap: CGFloat = 12
        let scrollViewH: CGFloat = 180
        let scrollToCheckboxGap: CGFloat = 14
        let btnH: CGFloat = 32
        let bottomPad: CGFloat = 14

        // Compute total window height (AppKit coords: origin at bottom)
        let winH = topPad + titleH + titleSubtitleGap + subtitleH
            + subtitleToRNLabelGap + releaseNotesLabelH + rnLabelToScrollGap
            + scrollViewH + scrollToCheckboxGap + btnH + bottomPad

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: winW, height: winH),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "Software Update"
        win.center()
        win.isReleasedWhenClosed = false

        let cv = NSView(frame: NSRect(x: 0, y: 0, width: winW, height: winH))

        // Build layout top-down using a cursor (AppKit y goes bottom-up, so start from top)
        var cursorY = winH - topPad

        // App icon — top-left, aligned with title top
        let iconY = cursorY - iconSize
        let icon = NSImageView(frame: NSRect(x: leftPad, y: iconY, width: iconSize, height: iconSize))
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        cv.addSubview(icon)

        // Bold title — right of icon, at top
        cursorY -= titleH
        let title = NSTextField(labelWithString: titleStr)
        title.font = titleFont
        title.lineBreakMode = .byWordWrapping
        title.maximumNumberOfLines = 0
        title.frame = NSRect(x: textX, y: cursorY, width: textW, height: titleH)
        cv.addSubview(title)

        // Subtitle — below title
        cursorY -= titleSubtitleGap + subtitleH
        let subtitle = NSTextField(labelWithString: subtitleStr)
        subtitle.font = subtitleFont
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byWordWrapping
        subtitle.maximumNumberOfLines = 0
        subtitle.frame = NSRect(x: textX, y: cursorY, width: textW, height: subtitleH)
        cv.addSubview(subtitle)

        // "Release Notes:" label
        cursorY -= subtitleToRNLabelGap + releaseNotesLabelH
        let rnLabel = NSTextField(labelWithString: releaseNotesLabelStr)
        rnLabel.font = releaseNotesLabelFont
        rnLabel.frame = NSRect(x: textX, y: cursorY, width: textW, height: releaseNotesLabelH)
        cv.addSubview(rnLabel)

        // Release notes scroll view with text view
        cursorY -= rnLabelToScrollGap + scrollViewH
        let scrollW = winW - leftPad - rightPad
        let scrollView = NSScrollView(frame: NSRect(x: leftPad, y: cursorY, width: scrollW, height: scrollViewH))
        scrollView.borderType = .bezelBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: scrollW - 16, height: scrollViewH))
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = NSFont.systemFont(ofSize: 13)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        let releaseNotesPath = candidate.path + "/Contents/Resources/ReleaseNotes.txt"
        let releaseNotes = (try? String(contentsOfFile: releaseNotesPath, encoding: .utf8))
            ?? "\u{2022} Bug fixes and improvements."
        textView.string = releaseNotes
        textView.autoresizingMask = [.width]
        scrollView.documentView = textView
        cv.addSubview(scrollView)

        // Button row
        cursorY -= scrollToCheckboxGap + btnH
        let btnSpacing: CGFloat = 12

        let installBtn = NSButton(title: "Install Update", target: self, action: #selector(updateNowClicked(_:)))
        installBtn.bezelStyle = .rounded
        installBtn.controlSize = .large
        installBtn.keyEquivalent = "\r"
        installBtn.sizeToFit()
        let installW = installBtn.frame.width + 20
        installBtn.frame = NSRect(x: winW - rightPad - installW, y: cursorY, width: installW, height: btnH)
        cv.addSubview(installBtn)

        let laterBtn = NSButton(title: "Remind Me Later", target: self, action: #selector(updateLaterClicked(_:)))
        laterBtn.bezelStyle = .rounded
        laterBtn.controlSize = .large
        laterBtn.sizeToFit()
        let laterW = laterBtn.frame.width + 20
        laterBtn.frame = NSRect(x: installBtn.frame.minX - btnSpacing - laterW, y: cursorY, width: laterW, height: btnH)
        cv.addSubview(laterBtn)

        let skipBtn = NSButton(title: "Skip This Version", target: self, action: #selector(skipThisVersionClicked(_:)))
        skipBtn.bezelStyle = .rounded
        skipBtn.controlSize = .large
        skipBtn.sizeToFit()
        let skipW = skipBtn.frame.width + 20
        skipBtn.frame = NSRect(x: leftPad, y: cursorY, width: skipW, height: btnH)
        cv.addSubview(skipBtn)

        win.contentView = cv
        updateWindow = win

        // Store build in window for suppression on "Later"
        win.representedFilename = candidate.build

        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Measure the height needed for a string at a given width.
    private func measureTextHeight(_ string: String, font: NSFont, width: CGFloat) -> CGFloat {
        let attrStr = NSAttributedString(string: string, attributes: [.font: font])
        let bounds = attrStr.boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                                          options: [.usesLineFragmentOrigin, .usesFontLeading])
        return bounds.height
    }

    @objc private func updateLaterClicked(_ sender: NSButton) {
        // Suppress this build until restart
        if let build = updateWindow?.representedFilename, !build.isEmpty {
            suppressedBuilds.insert(build)
            print("[AutoUpdate] User deferred update for build \(build)")
        }
        dismissUpdateWindow()
    }

    @objc private func updateNowClicked(_ sender: NSButton) {
        guard let candidate = pendingCandidate else { return }
        dismissUpdateWindow()
        performUpdate(from: candidate.path)
    }

    @objc private func skipThisVersionClicked(_ sender: NSButton) {
        if let candidate = pendingCandidate {
            UserDefaults.standard.set(candidate.build, forKey: kSkippedVersionKey)
            print("[AutoUpdate] User skipped version \(candidate.build)")
        }
        dismissUpdateWindow()
    }

    private func dismissUpdateWindow() {
        updateWindow?.close()
        updateWindow = nil
        pendingCandidate = nil
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
