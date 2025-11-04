#if VMCTL_APP
import AppKit

@main
final class VMCTLApp: NSObject, NSApplicationDelegate {
    private let cliURL: URL
    private let commandQueue = DispatchQueue(label: "vmctl.app.command")
    private let controller = VMController()

    private var window: NSWindow!
    private var vmListStack: NSStackView!
    private let outputView = NSTextView()
    private var statusTimer: Timer?
    private var vmRowControls: [String: VMRowControls] = [:]
    private var runningProcesses: [RunningProcess] = []

    private struct VMRowControls {
        let statusLabel: NSTextField
        let actionButton: NSButton
    }

    private struct RunningProcess {
        let process: Process
        let pipe: Pipe
    }

    override init() {
        if let override = ProcessInfo.processInfo.environment["VMCTL_CLI_PATH"] {
            cliURL = URL(fileURLWithPath: override)
        } else {
            let executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
            cliURL = executableURL.deletingLastPathComponent().appendingPathComponent("vmctl")
        }
        super.init()
    }

    static func main() {
        let app = NSApplication.shared
        let delegate = VMCTLApp()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenus()
        buildInterface()
        window.center()
        window.makeKeyAndOrderFront(nil)
        if let iconURL = Bundle.main.url(forResource: "icon", withExtension: "png"),
           let image = NSImage(contentsOf: iconURL) {
            NSApplication.shared.applicationIconImage = image
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        setOutput("Ready.")
        renderVMList(message: "Loading...")
        refreshVMs()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.refreshVMs()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusTimer?.invalidate()
        statusTimer = nil
        runningProcesses.forEach { $0.pipe.fileHandleForReading.readabilityHandler = nil }
        runningProcesses.removeAll()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    private func setupMenus() {
        let mainMenu = NSMenu()
        let appName = ProcessInfo.processInfo.processName

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu(title: appName)
        appMenuItem.submenu = appMenu
        let aboutItem = NSMenuItem(title: "About \(appName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        aboutItem.target = NSApp
        appMenu.addItem(aboutItem)
        appMenu.addItem(NSMenuItem.separator())
        let hideItem = NSMenuItem(title: "Hide \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        hideItem.target = NSApp
        appMenu.addItem(hideItem)
        let hideOthersItem = NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        hideOthersItem.target = NSApp
        appMenu.addItem(hideOthersItem)
        let showAllItem = NSMenuItem(title: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        showAllItem.target = NSApp
        appMenu.addItem(showAllItem)
        appMenu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApp
        appMenu.addItem(quitItem)

        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        fileMenuItem.submenu = fileMenu
        let refreshItem = NSMenuItem(title: "Refresh", action: #selector(refreshMenuItem(_:)), keyEquivalent: "r")
        refreshItem.target = self
        fileMenu.addItem(refreshItem)

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu
        let copyItem = NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        copyItem.target = nil
        editMenu.addItem(copyItem)
        let pasteItem = NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        pasteItem.target = nil
        editMenu.addItem(pasteItem)
        let selectAllItem = NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        selectAllItem.target = nil
        editMenu.addItem(selectAllItem)

        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenuItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    private func buildInterface() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 440),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "vmctl GUI"

        guard let contentView = window.contentView else { return }

        let rootStack = NSStackView()
        rootStack.orientation = .vertical
        rootStack.alignment = .leading
        rootStack.spacing = 12
        rootStack.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(rootStack)

        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            rootStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            rootStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            rootStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16)
        ])

        let headerRow = NSStackView()
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = 8

        let titleLabel = NSTextField(labelWithString: "Virtual Machines")
        titleLabel.font = .boldSystemFont(ofSize: 14)
        titleLabel.setContentHuggingPriority(.required, for: .horizontal)

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let refreshButton = NSButton(title: "Refresh", target: self, action: #selector(refreshButtonTapped))
        refreshButton.bezelStyle = .rounded

        headerRow.addArrangedSubview(titleLabel)
        headerRow.addArrangedSubview(spacer)
        headerRow.addArrangedSubview(refreshButton)

        rootStack.addArrangedSubview(headerRow)

        vmListStack = NSStackView()
        vmListStack.orientation = .vertical
        vmListStack.alignment = .leading
        vmListStack.spacing = 6
        vmListStack.translatesAutoresizingMaskIntoConstraints = false

        rootStack.addArrangedSubview(vmListStack)

        let outputLabel = NSTextField(labelWithString: "Output")
        rootStack.addArrangedSubview(outputLabel)

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true

        outputView.isEditable = false
        outputView.isSelectable = true
        outputView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        scrollView.documentView = outputView

        rootStack.addArrangedSubview(scrollView)
    }

    @objc private func refreshButtonTapped() {
        refreshVMs()
    }

    @objc private func refreshMenuItem(_ sender: Any?) {
        refreshVMs()
    }

    private func refreshVMs() {
        DispatchQueue.main.async {
            if self.vmListStack.arrangedSubviews.isEmpty {
                self.renderVMList(message: "Loading...")
            }
        }

        commandQueue.async { [weak self] in
            guard let self else { return }
            do {
                let listings = try self.controller.listVMs()
                DispatchQueue.main.async {
                    self.renderVMList(listings: listings)
                }
            } catch {
                DispatchQueue.main.async {
                    self.renderVMList(message: "Failed to load VMs: \(error.localizedDescription)")
                    self.appendOutputChunk("Failed to list VMs: \(error.localizedDescription)")
                }
            }
        }
    }

    private func renderVMList(listings: [VMController.VMListEntry]? = nil, message: String? = nil) {
        vmRowControls.removeAll()
        for view in vmListStack.arrangedSubviews {
            vmListStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        if let message = message {
            let label = NSTextField(labelWithString: message)
            label.textColor = .secondaryLabelColor
            vmListStack.addArrangedSubview(label)
            return
        }

        guard let listings = listings else {
            return
        }

        if listings.isEmpty {
            let emptyLabel = NSTextField(labelWithString: "No virtual machines found under ~/VMs.")
            emptyLabel.textColor = .secondaryLabelColor
            vmListStack.addArrangedSubview(emptyLabel)
            return
        }

        for entry in listings {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 12

            let nameLabel = NSTextField(labelWithString: entry.name)
            nameLabel.font = .boldSystemFont(ofSize: 13)
            nameLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)

            let statusLabel = NSTextField(labelWithString: entry.statusDescription)
            let statusColor: NSColor
            if entry.isRunning {
                statusColor = .systemGreen
            } else if !entry.installed {
                statusColor = .systemRed
            } else {
                statusColor = .labelColor
            }
            statusLabel.textColor = statusColor
            statusLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)

            let spacer = NSView()
            spacer.translatesAutoresizingMaskIntoConstraints = false
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            let actionTitle = entry.isRunning ? "Stop" : "Start"
            let actionButton = NSButton(title: actionTitle, target: self, action: #selector(handleRowAction(_:)))
            actionButton.identifier = NSUserInterfaceItemIdentifier(entry.name)
            actionButton.tag = entry.isRunning ? 1 : 0
            actionButton.bezelStyle = .rounded

            row.addArrangedSubview(nameLabel)
            row.addArrangedSubview(statusLabel)
            row.addArrangedSubview(spacer)
            row.addArrangedSubview(actionButton)

            vmListStack.addArrangedSubview(row)
            vmRowControls[entry.name] = VMRowControls(statusLabel: statusLabel, actionButton: actionButton)
        }
    }

    @objc private func handleRowAction(_ sender: NSButton) {
        guard let name = sender.identifier?.rawValue else {
            return
        }
        let shouldStop = sender.tag == 1
        sender.isEnabled = false

        if shouldStop {
            updateRow(name: name, status: "Stopping...", textColor: .systemOrange, buttonEnabled: false)
            runCommand(["stop", name], waitForTermination: true) { [weak self] in
                self?.refreshVMs()
            }
        } else {
            updateRow(name: name, status: "Starting...", forceButtonState: true, textColor: .systemOrange, buttonEnabled: true)
            runCommand(["start", name], waitForTermination: false) { [weak self] in
                self?.refreshVMs()
            }
            scheduleRefresh(after: 2)
        }
    }

    private func scheduleRefresh(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.refreshVMs()
        }
    }

    private func updateRow(name: String, status: String, forceButtonState runningState: Bool? = nil, textColor: NSColor? = nil, buttonEnabled: Bool? = nil) {
        guard let controls = vmRowControls[name] else {
            return
        }
        controls.statusLabel.stringValue = status
        if let running = runningState {
            controls.actionButton.title = running ? "Stop" : "Start"
            controls.actionButton.tag = running ? 1 : 0
        }
        if let color = textColor {
            controls.statusLabel.textColor = color
        }
        if let enabled = buttonEnabled {
            controls.actionButton.isEnabled = enabled
        }
    }

    private func runCommand(_ arguments: [String], waitForTermination: Bool, completion: (() -> Void)? = nil) {
        let joined = arguments.joined(separator: " ")
        let cliPath = cliURL.path

        DispatchQueue.main.async {
            self.setOutput("Running: vmctl \(joined)")
        }

        commandQueue.async { [weak self] in
            guard let self else { return }

            let process = Process()
            process.executableURL = self.cliURL
            process.arguments = arguments

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            do {
                try process.run()
            } catch {
                DispatchQueue.main.async {
                    self.setOutput("Failed to launch vmctl at \(cliPath): \(error.localizedDescription)")
                    completion?()
                }
                return
            }

            if waitForTermination {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                var output = String(data: data, encoding: .utf8) ?? ""
                let status = process.terminationStatus
                if status != 0 {
                    output += output.isEmpty ? "(exit code \(status))" : "\n(exit code \(status))"
                }
                if output.isEmpty {
                    output = "(no output)"
                }
                DispatchQueue.main.async {
                    self.setOutput(output)
                    completion?()
                }
            } else {
                DispatchQueue.main.async {
                    self.addRunningProcess(process, pipe: pipe)
                }

                pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                    let data = handle.availableData
                    guard !data.isEmpty else {
                        handle.readabilityHandler = nil
                        return
                    }
                    if let chunk = String(data: data, encoding: .utf8), !chunk.isEmpty {
                        DispatchQueue.main.async {
                            self?.appendOutputChunk(chunk)
                        }
                    }
                }

                process.terminationHandler = { [weak self] proc in
                    guard let self else { return }
                    DispatchQueue.main.async {
                        self.appendOutputChunk("vmctl exited with status \(proc.terminationStatus)")
                        self.removeRunningProcess(proc)
                        completion?()
                    }
                }
            }
        }
    }

    private func addRunningProcess(_ process: Process, pipe: Pipe) {
        runningProcesses.append(RunningProcess(process: process, pipe: pipe))
    }

    private func removeRunningProcess(_ process: Process) {
        for (index, entry) in runningProcesses.enumerated() {
            if entry.process === process {
                entry.pipe.fileHandleForReading.readabilityHandler = nil
                runningProcesses.remove(at: index)
                break
            }
        }
    }

    private func setOutput(_ text: String) {
        outputView.string = text
        outputView.scrollToEndOfDocument(nil)
    }

    private func appendOutputChunk(_ text: String) {
        guard !text.isEmpty else { return }
        if outputView.string.isEmpty {
            outputView.string = text
        } else {
            outputView.string += outputView.string.hasSuffix("\n") ? text : "\n" + text
        }
        outputView.scrollToEndOfDocument(nil)
    }
}
#endif
