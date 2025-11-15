#if VMCTL_APP
import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - View Model & Helpers

extension VMController.VMListEntry: Identifiable {
    var id: String { bundleURL.path }
}

final class VMListViewModel: ObservableObject {
    @Published var entries: [VMController.VMListEntry] = []
    @Published var statusMessage: String = "Ready."
    @Published var busyBundlePaths: Set<String> = []
    @Published var emptyMessage: String? = "Loading…"
    @Published var selectedBundlePath: String?
}

final class VMLibrary {
    private let defaults: UserDefaults
    private let storageKey = "VMLibraryBundlePaths"
    private var storedPaths: [String]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let raw = defaults.array(forKey: storageKey) as? [String] ?? []
        var deduped: [String] = []
        var seen: Set<String> = []
        for path in raw {
            if seen.insert(path).inserted {
                deduped.append(path)
            }
        }
        storedPaths = deduped
    }

    var bundleURLs: [URL] {
        return storedPaths.map { URL(fileURLWithPath: $0).standardizedFileURL }
    }

    @discardableResult
    func addBundle(_ url: URL) -> Bool {
        let normalized = normalize(url)
        guard normalized.pathExtension.lowercased() == VMController.bundleExtensionLowercased else { return false }
        let path = normalized.path
        guard !storedPaths.contains(path) else { return false }
        storedPaths.append(path)
        persist()
        return true
    }

    func addBundles(in directory: URL) {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return
        }
        for item in contents where item.pathExtension.lowercased() == VMController.bundleExtensionLowercased {
            _ = addBundle(item)
        }
    }

    @discardableResult
    func removeBundle(_ url: URL) -> Bool {
        let path = normalize(url).path
        let originalCount = storedPaths.count
        storedPaths.removeAll { $0 == path }
        if storedPaths.count != originalCount {
            persist()
            return true
        }
        return false
    }

    func removeBundles(at urls: [URL]) {
        let paths = Set(urls.map { normalize($0).path })
        guard !paths.isEmpty else { return }
        let originalCount = storedPaths.count
        storedPaths.removeAll { paths.contains($0) }
        if storedPaths.count != originalCount {
            persist()
        }
    }

    func contains(_ url: URL) -> Bool {
        return storedPaths.contains(normalize(url).path)
    }

    func clearMissingBundles() -> [URL] {
        let fm = FileManager.default
        var removed: [URL] = []
        storedPaths.removeAll { path in
            if !fm.fileExists(atPath: path) {
                removed.append(URL(fileURLWithPath: path))
                return true
            }
            return false
        }
        if !removed.isEmpty {
            persist()
        }
        return removed
    }

    func replaceAll(with urls: [URL]) {
        var deduped: [String] = []
        var seen: Set<String> = []
        for url in urls {
            let path = normalize(url).path
            if seen.insert(path).inserted {
                deduped.append(path)
            }
        }
        storedPaths = deduped
        persist()
    }

    private func normalize(_ url: URL) -> URL {
        return url.standardizedFileURL
    }

    private func persist() {
        defaults.set(storedPaths, forKey: storageKey)
    }
}

struct IPSWFeedEntry: Hashable {
    let firmwareURL: URL
    let productVersion: String
    let buildVersion: String
    let sha1: String?
    let documentationURL: URL?

    var identifier: String { firmwareURL.absoluteString }
    var filename: String { firmwareURL.lastPathComponent }

    var displayName: String {
        return "macOS \(productVersion) (\(buildVersion))"
    }

    var detailDescription: String {
        return filename
    }
}

extension IPSWFeedEntry: Identifiable {
    var id: String {
        return "\(productVersion)|\(buildVersion)|\(firmwareURL.absoluteString)"
    }
}

struct IPSWCachedImage: Hashable {
    let fileURL: URL
    let sizeBytes: Int64?

    var displayName: String {
        if let sizeBytes {
            return "\(fileURL.lastPathComponent) (\(Self.sizeFormatter.string(fromByteCount: sizeBytes)))"
        }
        return fileURL.lastPathComponent
    }

    private static let sizeFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        return formatter
    }()
}

struct IPSWDownloadProgress {
    let bytesWritten: Int64
    let totalBytes: Int64
    let speedBytesPerSecond: Double
}

final class IPSWLibrary: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private enum LibraryError: Error {
        case feedUnavailable
        case invalidResponse
    }

    private static let feedURLDefaultsKey = "VMCTLIPSWFeedURL"
    static let defaultFeedURL = URL(string: "https://mesu.apple.com/assets/macos/com_apple_macOSIPSW/com_apple_macOSIPSW.xml")!

    private let defaults: UserDefaults
    private let fileManager = FileManager.default
    private let cacheDirectory: URL
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 0
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()
    private var downloadStartDates: [Int: Date] = [:]
    private struct DownloadHandler {
        let entry: IPSWFeedEntry
        let destination: URL
        let progress: ((IPSWDownloadProgress) -> Void)?
        let completion: (Result<IPSWCachedImage, Error>) -> Void
    }
    private var downloadHandlers: [Int: DownloadHandler] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let supportDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            cacheDirectory = supportDirectory.appendingPathComponent("VirtualMachineManager/IPSW", isDirectory: true)
        } else {
            cacheDirectory = fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/VirtualMachineManager/IPSW", isDirectory: true)
        }
        super.init()
    }

    var feedURL: URL {
        get {
            if let stored = defaults.string(forKey: Self.feedURLDefaultsKey), let url = URL(string: stored) {
                return url
            }
            return Self.defaultFeedURL
        }
        set {
            defaults.set(newValue.absoluteString, forKey: Self.feedURLDefaultsKey)
        }
    }

    func cachedImages() -> [IPSWCachedImage] {
        ensureCacheDirectoryIfNeeded()
        guard let contents = try? fileManager.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var images: [IPSWCachedImage] = []
        for url in contents where url.pathExtension.lowercased() == "ipsw" {
            if let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
               values.isRegularFile == true {
                let size = values.fileSize.map { Int64($0) }
                images.append(IPSWCachedImage(fileURL: url, sizeBytes: size))
            }
        }
        return images.sorted { $0.fileURL.lastPathComponent.localizedCaseInsensitiveCompare($1.fileURL.lastPathComponent) == .orderedAscending }
    }

    @discardableResult
    func fetchFeed(completion: @escaping (Result<[IPSWFeedEntry], Error>) -> Void) -> URLSessionDataTask {
        return performFeedRequest(url: feedURL, completion: completion)
    }

    @discardableResult
    func verifyFeed(at url: URL, completion: @escaping (Result<[IPSWFeedEntry], Error>) -> Void) -> URLSessionDataTask {
        return performFeedRequest(url: url, completion: completion)
    }

    @discardableResult
    func download(
        entry: IPSWFeedEntry,
        progress: ((IPSWDownloadProgress) -> Void)? = nil,
        completion: @escaping (Result<IPSWCachedImage, Error>) -> Void
    ) -> URLSessionDownloadTask {
        ensureCacheDirectoryIfNeeded()
        let destination = cacheDirectory.appendingPathComponent(entry.filename, isDirectory: false)
        let handler = DownloadHandler(entry: entry, destination: destination, progress: progress, completion: completion)
        let task = session.downloadTask(with: entry.firmwareURL)
        downloadHandlers[task.taskIdentifier] = handler
        downloadStartDates[task.taskIdentifier] = Date()
        task.resume()
        return task
    }

    func deleteImage(at url: URL) throws {
        try fileManager.removeItem(at: url)
    }

    private func ensureCacheDirectoryIfNeeded() {
        if !fileManager.fileExists(atPath: cacheDirectory.path) {
            try? ensureCacheDirectory()
        }
    }

    private func ensureCacheDirectory() throws {
        if !fileManager.fileExists(atPath: cacheDirectory.path) {
            try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true, attributes: nil)
        }
    }

    private func performFeedRequest(url: URL, completion: @escaping (Result<[IPSWFeedEntry], Error>) -> Void) -> URLSessionDataTask {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 60
        let task = session.dataTask(with: request) { data, response, error in
            if let error {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
                return
            }
            guard
                let http = response as? HTTPURLResponse,
                (200..<300).contains(http.statusCode),
                let data
            else {
                DispatchQueue.main.async {
                    completion(.failure(LibraryError.invalidResponse))
                }
                return
            }
            do {
                let entries = try self.parseFeedEntries(data: data)
                DispatchQueue.main.async {
                    completion(.success(entries))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
        task.resume()
        return task
    }

    private func parseFeedEntries(data: Data) throws -> [IPSWFeedEntry] {
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        let restoreDictionaries = collectRestoreDictionaries(from: plist)
        var deduped: [String: IPSWFeedEntry] = [:]
        for restore in restoreDictionaries {
            guard
                let firmwareString = restore["FirmwareURL"] as? String,
                let firmwareURL = URL(string: firmwareString),
                let productVersion = restore["ProductVersion"] as? String,
                let buildVersion = restore["BuildVersion"] as? String
            else {
                continue
            }
            let sha1 = restore["FirmwareSHA1"] as? String
            let documentationURL = (restore["DocumentationURL"] as? String).flatMap { URL(string: $0) }
            let entry = IPSWFeedEntry(
                firmwareURL: firmwareURL,
                productVersion: productVersion,
                buildVersion: buildVersion,
                sha1: sha1,
                documentationURL: documentationURL
            )
            let key = "\(productVersion)|\(buildVersion)|\(firmwareURL.absoluteString)"
            deduped[key] = entry
        }
        let sorted = deduped.values.sorted { lhs, rhs in
            let leftParts = versionComponents(lhs.productVersion)
            let rightParts = versionComponents(rhs.productVersion)
            if leftParts != rightParts {
                return compareVersionParts(leftParts, rightParts) > 0
            }
            if lhs.buildVersion != rhs.buildVersion {
                return lhs.buildVersion > rhs.buildVersion
            }
            return lhs.filename.localizedCaseInsensitiveCompare(rhs.filename) == .orderedAscending
        }
        return sorted
    }

    private func collectRestoreDictionaries(from object: Any) -> [[String: Any]] {
        var restores: [[String: Any]] = []
        if let dict = object as? [String: Any] {
            if dict["FirmwareURL"] != nil && dict["ProductVersion"] != nil && dict["BuildVersion"] != nil {
                restores.append(dict)
            }
            for value in dict.values {
                restores.append(contentsOf: collectRestoreDictionaries(from: value))
            }
        } else if let array = object as? [Any] {
            for element in array {
                restores.append(contentsOf: collectRestoreDictionaries(from: element))
            }
        }
        return restores
    }

    private func versionComponents(_ version: String) -> [Int] {
        return version.split(separator: ".").compactMap { Int($0) }
    }

    private func compareVersionParts(_ lhs: [Int], _ rhs: [Int]) -> Int {
        let maxCount = max(lhs.count, rhs.count)
        for index in 0..<maxCount {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right {
                return left - right
            }
        }
        return 0
    }
    // MARK: - URLSessionDownloadDelegate

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        Task { @MainActor in
            guard let handler = downloadHandlers[downloadTask.taskIdentifier] else { return }
            let start = downloadStartDates[downloadTask.taskIdentifier] ?? Date()
            let elapsed = max(Date().timeIntervalSince(start), 0.001)
            let speed = Double(totalBytesWritten) / elapsed
            let info = IPSWDownloadProgress(
                bytesWritten: totalBytesWritten,
                totalBytes: totalBytesExpectedToWrite,
                speedBytesPerSecond: speed
            )
            handler.progress?(info)
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        Task { @MainActor in
            guard let handler = downloadHandlers[downloadTask.taskIdentifier] else { return }
            do {
                try ensureCacheDirectory()
                if fileManager.fileExists(atPath: handler.destination.path) {
                    try fileManager.removeItem(at: handler.destination)
                }
                try fileManager.moveItem(at: location, to: handler.destination)
                let values = try handler.destination.resourceValues(forKeys: [.fileSizeKey])
                let cached = IPSWCachedImage(fileURL: handler.destination, sizeBytes: values.fileSize.map { Int64($0) })
                handler.completion(.success(cached))
            } catch {
                handler.completion(.failure(error))
            }
            downloadHandlers.removeValue(forKey: downloadTask.taskIdentifier)
            downloadStartDates.removeValue(forKey: downloadTask.taskIdentifier)
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        Task { @MainActor in
            guard let handler = downloadHandlers.removeValue(forKey: task.taskIdentifier) else { return }
            downloadStartDates.removeValue(forKey: task.taskIdentifier)
            handler.completion(.failure(error))
        }
    }
}

private func statusColor(for entry: VMController.VMListEntry) -> Color {
    if entry.isRunning {
        return Color(nsColor: .systemGreen)
    }
    if !entry.installed {
        return Color(nsColor: .systemRed)
    }
    return Color(nsColor: .labelColor)
}

private func statusColor(isRunning: Bool, installed: Bool) -> Color {
    if isRunning { return Color(nsColor: .systemGreen) }
    if !installed { return Color(nsColor: .systemRed) }
    return Color(nsColor: .labelColor)
}

// MARK: - SwiftUI Views

struct MainView: View {
    @ObservedObject var model: VMListViewModel
    let onRefresh: () -> Void
    let onCreate: () -> Void
    let onToggle: (VMController.VMListEntry) -> Void
    let onInstall: (VMController.VMListEntry) -> Void
    let onDelete: (VMController.VMListEntry) -> Void
    let onShowInFinder: (VMController.VMListEntry) -> Void
    let onEditSettings: (VMController.VMListEntry) -> Void
    let onRemove: (VMController.VMListEntry) -> Void
    let onImportBundles: ([URL]) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                VStack(alignment: .leading) {
                    Text("Virtual Machines")
                        .font(.system(size: 20, weight: .semibold))
                    if !model.statusMessage.isEmpty {
                        Text(model.statusMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer()
                Button(action: onCreate) {
                    Label("Create VM", systemImage: "plus.circle.fill")
                        .labelStyle(.titleAndIcon)
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                Button(action: onRefresh) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .labelStyle(.iconOnly)
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
            }

            List(selection: $model.selectedBundlePath) {
                if let message = model.emptyMessage, model.entries.isEmpty {
                    Section {
                        Text(message)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(model.entries) { entry in
                        VMRowView(
                            entry: entry,
                            isBusy: model.busyBundlePaths.contains(entry.bundleURL.path),
                            isSelected: model.selectedBundlePath == entry.bundleURL.path,
                            onToggle: {
                                model.selectedBundlePath = entry.bundleURL.path
                                onToggle(entry)
                            },
                            onInstall: {
                                model.selectedBundlePath = entry.bundleURL.path
                                onInstall(entry)
                            },
                            onDelete: {
                                model.selectedBundlePath = entry.bundleURL.path
                                onDelete(entry)
                            },
                            onShowInFinder: {
                                model.selectedBundlePath = entry.bundleURL.path
                                onShowInFinder(entry)
                            },
                            onEditSettings: {
                                model.selectedBundlePath = entry.bundleURL.path
                                onEditSettings(entry)
                            },
                            onRemove: {
                                model.selectedBundlePath = entry.bundleURL.path
                                onRemove(entry)
                            }
                        )
                        .tag(entry.bundleURL.path)
                        .listRowInsets(.init())
                        // Let the system draw selection; do NOT override listRowBackground
                    }
                }
            }
            .listStyle(.plain)
            .padding(.horizontal, -16)
            .onDrop(of: [UTType.fileURL], isTargeted: nil, perform: handleDrop)
        }
        .padding(16)
        .frame(minWidth: 560, minHeight: 440)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }
        let identifier = UTType.fileURL.identifier
        var accepted = false
        var collected: [URL] = []
        let lock = NSLock()
        let group = DispatchGroup()

        for provider in providers where provider.hasItemConformingToTypeIdentifier(identifier) {
            accepted = true
            group.enter()
            provider.loadItem(forTypeIdentifier: identifier, options: nil) { item, _ in
                defer { group.leave() }
                var resolvedURL: URL?
                if let url = item as? URL {
                    resolvedURL = url
                } else if let nsurl = item as? NSURL {
                    resolvedURL = nsurl as URL
                } else if let data = item as? Data {
                    resolvedURL = URL(dataRepresentation: data, relativeTo: nil, isAbsolute: true)
                }

                if let url = resolvedURL {
                    lock.lock()
                    collected.append(url)
                    lock.unlock()
                }
            }
        }

        guard accepted else { return false }

        group.notify(queue: .main) {
            let bundles = collected.filter { $0.pathExtension.lowercased() == VMController.bundleExtensionLowercased }
            if !bundles.isEmpty {
                onImportBundles(bundles)
            }
        }

        return true
    }
}

struct VMRowView: View {
    let entry: VMController.VMListEntry
    let isBusy: Bool
    let isSelected: Bool
    let onToggle: () -> Void
    let onInstall: () -> Void
    let onDelete: () -> Void
    let onShowInFinder: () -> Void
    let onEditSettings: () -> Void
    let onRemove: () -> Void

    @State private var isPlayHovered = false
    private let menuIconSize: CGFloat = 18

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(statusColor(for: entry))
                .frame(width: 12, height: 12)

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.name)
                    .font(.headline)
                Text(entry.statusDescription)
                    .font(.subheadline)
                    .foregroundStyle(statusColor(for: entry))
                Text(statsDescription)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text(entry.bundleURL.path)
                    .font(.caption)
                    .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
            }

            Spacer()

            HStack(spacing: 8) {
                if entry.installed {
                    Button(action: {
                        onToggle()
                    }) {
                        Image(systemName: entry.isRunning ? "stop.fill" : "play.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.borderless) // important: don't steal first-click focus from the List
                    .foregroundStyle(isBusy ? Color.secondary : Color.primary)
                    .background(
                        Circle()
                            .fill(isPlayHovered ? Color.accentColor.opacity(0.15) : Color.clear)
                    )
                    .overlay(
                        Circle()
                            .stroke(isPlayHovered ? Color.accentColor.opacity(0.35) : Color.secondary.opacity(0.2), lineWidth: 1)
                    )
                    .contentShape(Circle())
                    .disabled(isBusy)
                    .help(primaryActionHelpText)
                    .onHover { hovering in
                        isPlayHovered = hovering && !isBusy
                    }
                } else {
                    Button(action: onInstall) {
                        Label("Install", systemImage: "arrow.down.circle")
                            .labelStyle(.titleAndIcon)
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .disabled(isBusy)
                    .help("Install macOS into this VM bundle")
                }

                Menu {
                    actionMenuItems()
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: menuIconSize, weight: .semibold))
                        .frame(width: 28, height: 28)
                }
                .fixedSize()
                .menuStyle(.borderlessButton) // prevents stealing row focus
                .menuIndicator(.hidden)
                .help("More actions")
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Let the system draw selected row highlight (blue/gray). Do not override background.
        .contextMenu { actionMenuItems() }
    }

    private var statsDescription: String {
        let memory = formattedBytes(entry.memoryBytes, style: .memory)
        let disk = formattedBytes(entry.diskBytes, style: .file)
        return "CPUs: \(entry.cpuCount) · Memory: \(memory) · Disk: \(disk)"
    }

    private var primaryActionHelpText: String {
        if !entry.installed {
            return "Install macOS before starting"
        }
        return entry.isRunning ? "Pause VM" : "Start VM"
    }

    private func formattedBytes(_ bytes: UInt64, style: ByteCountFormatter.CountStyle) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = style
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: Int64(bytes))
    }

    @ViewBuilder
    private func actionMenuItems() -> some View {
        Button(entry.isRunning ? "Pause" : "Start") {
            onToggle()
        }
        .disabled(isBusy || !entry.installed)

        if !entry.installed {
            Button("Install…") {
                onInstall()
            }
            .disabled(isBusy)
        }

        if !entry.isRunning {
            Button("Edit Settings…") {
                onEditSettings()
            }
            .disabled(isBusy)
        }

        Divider()

        Button("Show in Finder") {
            onShowInFinder()
        }

        Button("Remove from List") {
            onRemove()
        }
        .disabled(isBusy || entry.isRunning)

        Divider()

        Button("Delete", role: .destructive) {
            onDelete()
        }
        .disabled(entry.isRunning || isBusy)
    }
}

// MARK: - App Delegate

@main
final class VMCTLApp: NSObject, NSApplicationDelegate {
    private static let vmRootDefaultsKey = "VMCTLRootDirectoryPath"
    private static let defaultVMRootDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("VMs", isDirectory: true)

    private let cliURL: URL
    private let commandQueue = DispatchQueue(label: "vmctl.app.command")
    private let userDefaults = UserDefaults.standard
    private var vmRootDirectory: URL
    private let controller: VMController
    private let library: VMLibrary
    private let ipswLibrary: IPSWLibrary
    private let viewModel = VMListViewModel()
    private let recognizedBundleExtension = "virtualmachine"
    private let restoreManageMenuTag = -9000
    private var cachedRestoreImages: [IPSWCachedImage] = []

    private var window: NSWindow!
    private var statusTimer: Timer?
    private weak var createSheet: NSPanel?
    private weak var editSheet: NSPanel?
    private weak var settingsSheet: NSPanel?
    private var createForm: CreateForm?
    private var editForm: EditForm?
    private var settingsForm: SettingsForm?
    private var installSessions: [String: InstallProgressSession] = [:]
    private var runningProcesses: [RunningProcess] = []
    private var managedSessions: [String: EmbeddedVMSession] = [:]
    private var pendingLaunchPaths: Set<String> = []
    private var awaitingQuitConfirmation = false
    private var pendingFeedVerificationTask: URLSessionDataTask?
    private var ipswManagerController: IPSWManagerWindowController?

    private struct RunningProcess {
        let process: Process
        let pipe: Pipe
    }

    private struct CreateForm {
        let panel: NSPanel
        let nameField: NSTextField
        let cpuField: NSTextField
        let memoryField: NSTextField
        let diskField: NSTextField
        let restoreSelectionPopUp: NSPopUpButton
        let sharedFolderField: NSTextField
        let sharedWritableCheckbox: NSButton
        let createButton: NSButton
        var customRestoreURL: URL?
        var selectedRestorePath: String?
    }

    private struct EditForm {
        let name: String
        let bundleURL: URL
        let panel: NSPanel
        let cpuField: NSTextField
        let memoryField: NSTextField
        let diskField: NSTextField
        let sharedFolderField: NSTextField
        let sharedWritableCheckbox: NSButton
        let saveButton: NSButton
    }

    private struct SettingsForm {
        let panel: NSPanel
        let pathField: NSTextField
        let feedField: NSTextField
        let verifyButton: NSButton
        let verifyIndicator: NSImageView
    }

    private struct InstallProgressSession {
        let bundleURL: URL
        let name: String
        let window: NSWindow
        let progressIndicator: NSProgressIndicator
        let logTextView: NSTextView
        let logAttributes: [NSAttributedString.Key: Any]
    }

    override init() {
        if let override = ProcessInfo.processInfo.environment["VMCTL_CLI_PATH"] {
            cliURL = URL(fileURLWithPath: override)
        } else {
            let executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
            cliURL = executableURL.deletingLastPathComponent().appendingPathComponent("vmctl")
        }

        let storedPath = userDefaults.string(forKey: VMCTLApp.vmRootDefaultsKey)
        if let path = storedPath, !path.isEmpty {
            vmRootDirectory = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        } else {
            vmRootDirectory = VMCTLApp.defaultVMRootDirectory
        }
        controller = VMController(rootDirectory: vmRootDirectory)
        library = VMLibrary(defaults: userDefaults)
        ipswLibrary = IPSWLibrary(defaults: userDefaults)
        cachedRestoreImages = ipswLibrary.cachedImages()
        library.addBundles(in: vmRootDirectory)
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

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if awaitingQuitConfirmation {
            return .terminateLater
        }

        let activeSessions = managedSessions
        guard !activeSessions.isEmpty else {
            return .terminateNow
        }

        let names = activeSessions.values.map { $0.name }.sorted().joined(separator: ", ")
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Suspend running virtual machines before quitting?"
        alert.informativeText = "The following VMs are still running:\n\(names)\nThey need to be suspended before the app quits."
        alert.addButton(withTitle: "Suspend & Quit")
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\u{1b}"

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            awaitingQuitConfirmation = true
            suspendSessionsBeforeQuit(Array(activeSessions.values))
            return .terminateLater
        }
        return .terminateCancel
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let window = window {
            window.makeKeyAndOrderFront(nil)
        } else {
            buildInterface()
            window?.center()
            window?.makeKeyAndOrderFront(nil)
        }
        return true
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        handleOpenRequests([URL(fileURLWithPath: filename)])
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        handleOpenRequests(urls)
    }

    // MARK: - Menu & Interface

    private func handleOpenRequests(_ urls: [URL]) {
        registerBundles(urls, autoLaunch: true)
    }

    private func isRecognizedVMBundle(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == recognizedBundleExtension
    }

    private func registerBundles(_ urls: [URL], autoLaunch: Bool) {
        var recognized = false
        var added = false
        for rawURL in urls {
            let standardized = rawURL.standardizedFileURL
            guard isRecognizedVMBundle(standardized) else { continue }
            recognized = true
            if library.addBundle(standardized) {
                added = true
            }
            if autoLaunch {
                pendingLaunchPaths.insert(standardized.path)
            }
        }

        guard recognized else { return }

        if added {
            refreshVMs()
        } else if autoLaunch {
            startPendingLaunchesIfNeeded()
        }
    }

    private func startPendingLaunchesIfNeeded() {
        guard !pendingLaunchPaths.isEmpty else { return }
        let entries = viewModel.entries
        var handled: [String] = []

        for path in pendingLaunchPaths {
            guard let entry = entries.first(where: { $0.bundleURL.path == path }) else {
                continue
            }
            handled.append(path)

            if let session = managedSessions[path] {
                session.bringToFront()
                continue
            }

            guard entry.installed else {
                viewModel.statusMessage = "\(entry.name) is not installed."
                presentErrorAlert(message: "Cannot Start VM", informative: "\(entry.name) is not installed. Install macOS before launching.")
                continue
            }

            startEmbeddedVM(entry: entry)
        }

        handled.forEach { pendingLaunchPaths.remove($0) }
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
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings(_:)), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
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
        let newItem = NSMenuItem(title: "New VM…", action: #selector(createMenuItem(_:)), keyEquivalent: "n")
        newItem.target = self
        fileMenu.addItem(newItem)
        fileMenu.addItem(NSMenuItem.separator())
        let refreshItem = NSMenuItem(title: "Refresh", action: #selector(refreshMenuItem(_:)), keyEquivalent: "r")
        refreshItem.target = self
        fileMenu.addItem(refreshItem)

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenuItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        let ipswManagerItem = NSMenuItem(title: "Manage Restore Images", action: #selector(showIPSWManagerFromMenu(_:)), keyEquivalent: "")
        ipswManagerItem.target = self
        windowMenu.addItem(NSMenuItem.separator())
        windowMenu.addItem(ipswManagerItem)
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
        window.isReleasedWhenClosed = false
        window.title = "Virtual Machine Manager"

        let content = MainView(
            model: viewModel,
            onRefresh: { [weak self] in self?.refreshVMs() },
            onCreate: { [weak self] in self?.presentCreateSheet() },
            onToggle: { [weak self] entry in self?.toggleVM(entry: entry) },
            onInstall: { [weak self] entry in self?.installVM(entry: entry) },
            onDelete: { [weak self] entry in self?.confirmDelete(entry: entry) },
            onShowInFinder: { [weak self] entry in self?.showInFinder(entry: entry) },
            onEditSettings: { [weak self] entry in self?.presentEditSettings(for: entry) },
            onRemove: { [weak self] entry in self?.removeFromList(entry: entry) },
            onImportBundles: { [weak self] urls in self?.registerBundles(urls, autoLaunch: false) }
        )

        let hostingView = NSHostingView(rootView: content)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = hostingView
    }

    // MARK: - Actions

    @objc private func refreshMenuItem(_ sender: Any?) {
        refreshVMs()
    }

    @objc private func createMenuItem(_ sender: Any?) {
        presentCreateSheet()
    }

    private func refreshVMs() {
        let trackedBundles = library.bundleURLs
        guard !trackedBundles.isEmpty else {
            viewModel.entries = []
            viewModel.emptyMessage = "No virtual machines tracked. Create one or open an existing bundle."
            viewModel.statusMessage = "Ready."
            return
        }

        viewModel.statusMessage = "Refreshing…"
        commandQueue.async { [weak self] in
            guard let self else { return }
            let entries = self.controller.listVMs(at: trackedBundles)
            let validPaths = Set(entries.map { $0.bundleURL.standardizedFileURL.path })
            let trackedPaths = trackedBundles.map { $0.standardizedFileURL.path }
            let missingPaths = trackedPaths.filter { !validPaths.contains($0) }

            DispatchQueue.main.async {
                if entries.isEmpty {
                    self.viewModel.emptyMessage = "No virtual machines found. They may have been moved or deleted."
                } else {
                    self.viewModel.emptyMessage = nil
                }
                self.viewModel.entries = entries
                self.viewModel.statusMessage = "Ready."
                if !missingPaths.isEmpty {
                    let urls = missingPaths.map { URL(fileURLWithPath: $0) }
                    self.library.removeBundles(at: urls)
                }
                self.startPendingLaunchesIfNeeded()
            }
        }
    }

    private func toggleVM(entry: VMController.VMListEntry) {
        let bundlePath = entry.bundleURL.path
        if viewModel.busyBundlePaths.contains(bundlePath) { return }

        if let session = managedSessions[bundlePath] {
            viewModel.statusMessage = "Stopping \(entry.name)…"
            session.requestStop()
            return
        }

        if entry.isRunning {
            viewModel.busyBundlePaths.insert(bundlePath)
            viewModel.statusMessage = "Stopping \(entry.name)…"
            runCommand(["stop", bundlePath], waitForTermination: true, completion: { [weak self] in
                self?.viewModel.busyBundlePaths.remove(bundlePath)
                self?.refreshVMs()
            })
            return
        }

        startEmbeddedVM(entry: entry)
    }

    private func confirmDelete(entry: VMController.VMListEntry) {
        guard let window = self.window else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Move \(entry.name) to Trash?"
        alert.informativeText = "The VM bundle will be moved to the Trash. You can restore it later from Finder."
        alert.addButton(withTitle: "Move to Trash")
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\u{1b}"

        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            if response == .alertFirstButtonReturn {
                self.deleteVM(entry: entry)
            } else {
                self.refreshVMs()
            }
        }
    }

    private func showInFinder(entry: VMController.VMListEntry) {
        NSWorkspace.shared.activateFileViewerSelecting([entry.bundleURL])
        viewModel.statusMessage = "Revealed \(entry.name) in Finder."
    }

    private func removeFromList(entry: VMController.VMListEntry) {
        let bundlePath = entry.bundleURL.path
        if entry.isRunning || managedSessions[bundlePath] != nil {
            presentErrorAlert(message: "VM Running", informative: "Stop \(entry.name) before removing it from the list.")
            return
        }
        if library.removeBundle(entry.bundleURL) {
            viewModel.statusMessage = "Removed \(entry.name) from list."
        }
        refreshVMs()
    }

    // MARK: - Install Workflow

    private func installVM(entry: VMController.VMListEntry) {
        let name = entry.name
        let bundleURL = entry.bundleURL
        let bundlePath = bundleURL.path

        if entry.installed {
            presentErrorAlert(message: "Already Installed", informative: "\(name) already has macOS installed.")
            return
        }
        if entry.isRunning || managedSessions[bundlePath] != nil {
            presentErrorAlert(message: "VM Running", informative: "Stop \(name) before running the installer.")
            return
        }
        if let session = installSessions[bundlePath] {
            session.window.makeKeyAndOrderFront(nil)
            return
        }

        let session = makeInstallProgressSession(name: name, bundleURL: bundleURL)
        installSessions[bundlePath] = session
        session.window.makeKeyAndOrderFront(nil)

        viewModel.busyBundlePaths.insert(bundlePath)
        viewModel.statusMessage = "Installing \(name)…"

        runCommand(
            ["install", bundlePath],
            waitForTermination: false,
            outputHandler: { [weak self] chunk in
                self?.appendInstallLog(for: bundlePath, chunk: chunk)
            },
            terminationHandler: { [weak self] status in
                guard let self else { return }
                let success = (status == 0)
                let finalLine = success ? "Installation completed successfully." : "Installation failed (exit status \(status))."
                self.appendInstallLog(for: bundlePath, chunk: "\n\(finalLine)\n")
                self.finishInstallSession(bundlePath: bundlePath, succeeded: success)
                if success {
                    self.viewModel.statusMessage = "\(name) installed."
                } else {
                    self.viewModel.statusMessage = "Install failed for \(name)."
                    self.presentErrorAlert(message: "Install Failed", informative: finalLine)
                }
            },
            completion: { [weak self] in
                guard let self else { return }
                self.viewModel.busyBundlePaths.remove(bundlePath)
                self.refreshVMs()
            }
        )
    }

    private func makeInstallProgressSession(name: String, bundleURL: URL) -> InstallProgressSession {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 360),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = "Installing \(name)"
        window.center()

        let contentView = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = contentView

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)

        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])

        let header = NSTextField(labelWithString: "Running macOS installer via vmctl. Leave this window open to monitor progress.")
        header.lineBreakMode = .byWordWrapping
        header.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(header)

        let progressIndicator = NSProgressIndicator()
        progressIndicator.style = .spinning
        progressIndicator.controlSize = .regular
        progressIndicator.isIndeterminate = true
        progressIndicator.startAnimation(nil)
        stack.addArrangedSubview(progressIndicator)

        let logLabel = NSTextField(labelWithString: "Installer Output")
        logLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        stack.addArrangedSubview(logLabel)

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true

        let textView = NSTextView()
        textView.isEditable = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width]
        let logFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.font = logFont
        textView.textColor = NSColor.labelColor
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.usesAdaptiveColorMappingForDarkAppearance = true
        let logAttributes: [NSAttributedString.Key: Any] = [
            .font: logFont,
            .foregroundColor: NSColor.labelColor
        ]
        scrollView.documentView = textView
        stack.addArrangedSubview(scrollView)

        return InstallProgressSession(
            bundleURL: bundleURL,
            name: name,
            window: window,
            progressIndicator: progressIndicator,
            logTextView: textView,
            logAttributes: logAttributes
        )
    }

    private func appendInstallLog(for bundlePath: String, chunk: String) {
        guard let session = installSessions[bundlePath] else { return }
        let sanitized = chunk.replacingOccurrences(of: "\r", with: "\n")
        if let storage = session.logTextView.textStorage {
            storage.append(NSAttributedString(string: sanitized, attributes: session.logAttributes))
        } else {
            session.logTextView.string += sanitized
        }
        session.logTextView.scrollToEndOfDocument(nil)
    }

    private func finishInstallSession(bundlePath: String, succeeded: Bool) {
        guard let session = installSessions[bundlePath] else { return }
        session.progressIndicator.stopAnimation(nil)
        session.progressIndicator.isHidden = true
        session.window.title = succeeded ? "Installed \(session.name)" : "Install Failed – \(session.name)"
        installSessions.removeValue(forKey: bundlePath)
    }

    private func deleteVM(entry: VMController.VMListEntry) {
        let name = entry.name
        let bundleURL = entry.bundleURL
        let bundlePath = bundleURL.path
        viewModel.busyBundlePaths.insert(bundlePath)
        viewModel.statusMessage = "Moving \(name) to Trash…"
        commandQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.controller.moveVMToTrash(bundleURL: bundleURL)
                DispatchQueue.main.async {
                    self.library.removeBundle(bundleURL)
                    self.viewModel.statusMessage = "\(name) moved to Trash."
                    self.viewModel.busyBundlePaths.remove(bundlePath)
                    self.refreshVMs()
                }
            } catch {
                DispatchQueue.main.async {
                    self.viewModel.statusMessage = "Delete failed: \(error.localizedDescription)"
                    self.viewModel.busyBundlePaths.remove(bundlePath)
                    self.presentErrorAlert(message: "Failed to Delete VM", informative: error.localizedDescription)
                    self.refreshVMs()
                }
            }
        }
    }

    // MARK: - Embedded VM Management

    private func startEmbeddedVM(entry: VMController.VMListEntry) {
        startEmbeddedVM(bundleURL: entry.bundleURL, displayName: entry.name)
    }

    private func startEmbeddedVM(bundleURL: URL, displayName name: String) {
        let bundlePath = bundleURL.path
        if let existing = managedSessions[bundlePath] {
            existing.bringToFront()
            return
        }

        viewModel.busyBundlePaths.insert(bundlePath)
        viewModel.statusMessage = "Starting \(name)…"

        commandQueue.async { [weak self] in
            guard let self else { return }
            do {
                let session = try self.controller.makeEmbeddedSession(bundleURL: bundleURL, runtimeSharedFolder: nil)
                DispatchQueue.main.async {
                    self.register(session: session, for: bundlePath)
                    session.start { [weak self] result in
                        guard let self else { return }
                        switch result {
                        case .success:
                            self.viewModel.statusMessage = "\(name) started."
                            self.refreshVMs()
                        case .failure(let error):
                            self.managedSessions.removeValue(forKey: bundlePath)
                            self.viewModel.statusMessage = "Failed to start \(name): \(error.localizedDescription)"
                            self.viewModel.busyBundlePaths.remove(bundlePath)
                            self.presentErrorAlert(message: "Failed to Start VM", informative: error.localizedDescription)
                            self.refreshVMs()
                        }
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.viewModel.busyBundlePaths.remove(bundlePath)
                    self.viewModel.statusMessage = "Failed to start \(name): \(error.localizedDescription)"
                    self.presentErrorAlert(message: "Failed to Start VM", informative: error.localizedDescription)
                    self.refreshVMs()
                }
            }
        }
    }

    private func register(session: EmbeddedVMSession, for bundlePath: String) {
        managedSessions[bundlePath] = session
        let displayName = session.name

        session.stateDidChange = { [weak self] state in
            DispatchQueue.main.async {
                guard let self else { return }
                switch state {
                case .starting, .stopping:
                    self.viewModel.busyBundlePaths.insert(bundlePath)
                default:
                    self.viewModel.busyBundlePaths.remove(bundlePath)
                }
            }
        }

        session.statusChanged = { [weak self] message in
            DispatchQueue.main.async {
                self?.viewModel.statusMessage = message
            }
        }

        session.terminationHandler = { [weak self] result in
            guard let self else { return }
            self.managedSessions.removeValue(forKey: bundlePath)
            switch result {
            case .success:
                self.viewModel.statusMessage = "\(displayName) stopped."
            case .failure(let error):
                self.viewModel.statusMessage = "\(displayName) stopped with error: \(error.localizedDescription)"
                self.presentErrorAlert(message: "Virtual Machine Error", informative: error.localizedDescription)
            }
            self.viewModel.busyBundlePaths.remove(bundlePath)
            self.refreshVMs()
        }
    }

    private func suspendSessionsBeforeQuit(_ sessions: [EmbeddedVMSession]) {
        if sessions.isEmpty {
            awaitingQuitConfirmation = false
            NSApp.reply(toApplicationShouldTerminate: true)
            return
        }

        var remaining = sessions.count
        for session in sessions {
            session.requestStop { [weak self] _ in
                guard let self else { return }
                remaining -= 1
                if remaining == 0 {
                    self.awaitingQuitConfirmation = false
                    NSApp.reply(toApplicationShouldTerminate: true)
                }
            }
        }
    }

    // MARK: - Create VM Sheet

    private func presentCreateSheet() {
        guard let window = self.window else { return }

        if let sheet = createSheet {
            window.makeKeyAndOrderFront(sheet)
            return
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 380),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Create Virtual Machine"
        panel.isFloatingPanel = false
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.center()

        let contentView = NSView(frame: panel.contentRect(forFrameRect: panel.frame))
        panel.contentView = contentView

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 24, bottom: 18, right: 24)

        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])

        let descriptionLabel = NSTextField(labelWithString: "Provide a name and required .ipsw restore image. Adjust CPU, memory, and disk as needed. Shared folder is optional.")
        descriptionLabel.lineBreakMode = .byWordWrapping
        descriptionLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(descriptionLabel)

        func labeledRow(_ title: String, control: NSView, trailing: NSView? = nil) -> NSView {
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 12, weight: .semibold)

            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 8
            row.distribution = .fill

            control.translatesAutoresizingMaskIntoConstraints = false
            control.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true

            row.addArrangedSubview(label)
            row.addArrangedSubview(control)
            if let trailing = trailing {
                row.addArrangedSubview(trailing)
            }

            return row
        }

        let nameField = NSTextField(string: "")
        nameField.placeholderString = "sandbox"
        stack.addArrangedSubview(labeledRow("Name", control: nameField))

        let cpuField = NSTextField(string: "4")
        cpuField.placeholderString = "Number of vCPUs"
        stack.addArrangedSubview(labeledRow("CPUs", control: cpuField))

        let memoryField = NSTextField(string: "8")
        memoryField.placeholderString = "GiB"
        stack.addArrangedSubview(labeledRow("Memory", control: memoryField))

        let diskField = NSTextField(string: "64")
        diskField.placeholderString = "GiB (minimum 20)"
        stack.addArrangedSubview(labeledRow("Disk", control: diskField))

        let restoreMenu = NSPopUpButton(frame: .zero, pullsDown: false)
        restoreMenu.autoenablesItems = false
        restoreMenu.target = self
        restoreMenu.action = #selector(restoreSelectionChanged(_:))
        let restoreBrowse = NSButton(title: "Browse…", target: self, action: #selector(browseRestoreImage))
        stack.addArrangedSubview(labeledRow("Restore Image*", control: restoreMenu, trailing: restoreBrowse))

        let sharedField = NSTextField(string: "")
        sharedField.placeholderString = "Optional shared folder path"
        let sharedBrowse = NSButton(title: "Browse…", target: self, action: #selector(browseSharedFolder))
        stack.addArrangedSubview(labeledRow("Shared Folder", control: sharedField, trailing: sharedBrowse))

        let sharedWritable = NSButton(checkboxWithTitle: "Allow writes to shared folder", target: nil, action: nil)
        stack.addArrangedSubview(sharedWritable)

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 8
        buttonRow.distribution = .fillProportionally

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelCreateSheet))
        cancelButton.bezelStyle = .rounded

        let createButton = NSButton(title: "Create", target: self, action: #selector(confirmCreateSheet))
        createButton.bezelStyle = .rounded
        createButton.keyEquivalent = "\r"

        buttonRow.addArrangedSubview(spacer)
        buttonRow.addArrangedSubview(cancelButton)
        buttonRow.addArrangedSubview(createButton)

        stack.addArrangedSubview(buttonRow)

        createForm = CreateForm(
            panel: panel,
            nameField: nameField,
            cpuField: cpuField,
            memoryField: memoryField,
            diskField: diskField,
            restoreSelectionPopUp: restoreMenu,
            sharedFolderField: sharedField,
            sharedWritableCheckbox: sharedWritable,
            createButton: createButton,
            customRestoreURL: nil,
            selectedRestorePath: nil
        )
        createSheet = panel

        refreshRestoreSelections()

        window.beginSheet(panel) { [weak self] _ in
            self?.createSheet = nil
            self?.createForm = nil
        }
    }

    private func refreshRestoreSelections(selecting path: String? = nil) {
        guard let form = createForm else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false

        var firstSelectableItem: NSMenuItem?
        var placeholderItem: NSMenuItem?

        if let customURL = form.customRestoreURL {
            let customItem = NSMenuItem(title: "Custom: \(customURL.lastPathComponent)", action: nil, keyEquivalent: "")
            customItem.representedObject = customURL.path
            customItem.toolTip = customURL.path
            menu.addItem(customItem)
            firstSelectableItem = customItem
        }

        for image in cachedRestoreImages {
            let item = NSMenuItem(title: image.displayName, action: nil, keyEquivalent: "")
            item.representedObject = image.fileURL.path
            item.toolTip = image.fileURL.path
            menu.addItem(item)
            if firstSelectableItem == nil {
                firstSelectableItem = item
            }
        }

        if firstSelectableItem == nil {
            let placeholder = NSMenuItem(title: "No cached restore images", action: nil, keyEquivalent: "")
            placeholder.isEnabled = false
            menu.addItem(placeholder)
            placeholderItem = placeholder
        }

        menu.addItem(NSMenuItem.separator())
        let manageItem = NSMenuItem(title: "Manage…", action: nil, keyEquivalent: "")
        manageItem.tag = restoreManageMenuTag
        menu.addItem(manageItem)

        form.restoreSelectionPopUp.menu = menu
        form.restoreSelectionPopUp.target = self
        form.restoreSelectionPopUp.action = #selector(restoreSelectionChanged(_:))

        let desiredPath = path ?? form.selectedRestorePath
        if let desiredPath,
           let targetItem = menu.items.first(where: { ($0.representedObject as? String) == desiredPath }) {
            let index = menu.index(of: targetItem)
            form.restoreSelectionPopUp.selectItem(at: index)
            createForm?.selectedRestorePath = desiredPath
        } else if let first = firstSelectableItem {
            let index = menu.index(of: first)
            form.restoreSelectionPopUp.selectItem(at: index)
            createForm?.selectedRestorePath = first.representedObject as? String
        } else if let placeholder = placeholderItem {
            let index = menu.index(of: placeholder)
            form.restoreSelectionPopUp.selectItem(at: index)
            createForm?.selectedRestorePath = nil
        } else {
            form.restoreSelectionPopUp.select(nil)
            createForm?.selectedRestorePath = nil
        }
    }

    @objc private func restoreSelectionChanged(_ sender: NSPopUpButton) {
        guard let item = sender.selectedItem else {
            createForm?.selectedRestorePath = nil
            return
        }
        if item.tag == restoreManageMenuTag {
            let previousPath = createForm?.selectedRestorePath
            presentIPSWManager()
            refreshRestoreSelections(selecting: previousPath)
            return
        }
        if let path = item.representedObject as? String {
            createForm?.selectedRestorePath = path
        } else {
            createForm?.selectedRestorePath = nil
        }
    }

    @objc private func cancelCreateSheet(_ sender: Any?) {
        guard let panel = createForm?.panel else { return }
        window?.endSheet(panel)
    }

    @objc private func confirmCreateSheet(_ sender: Any?) {
        guard let form = createForm else { return }

        let name = form.nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            presentErrorAlert(message: "Name Required", informative: "Please provide a name for the new virtual machine.")
            return
        }

        guard let cpus = Int(form.cpuField.stringValue), cpus > 0 else {
            presentErrorAlert(message: "Invalid CPU Count", informative: "Enter a positive integer for vCPU count.")
            return
        }

        guard let memory = Int(form.memoryField.stringValue), memory > 0 else {
            presentErrorAlert(message: "Invalid Memory", informative: "Enter memory in GiB (positive integer).")
            return
        }

        guard let disk = Int(form.diskField.stringValue), disk >= 20 else {
            presentErrorAlert(message: "Invalid Disk Size", informative: "Disk size must be at least 20 GiB.")
            return
        }

        guard let selectedRestorePath = form.selectedRestorePath else {
            presentErrorAlert(message: "Restore Image Required", informative: "Select or browse for a macOS .ipsw restore image before creating the VM.")
            return
        }
        let normalizedRestorePath = (selectedRestorePath as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: normalizedRestorePath) else {
            presentErrorAlert(message: "Restore Image Missing", informative: "The selected restore image could not be found at \(normalizedRestorePath).")
            refreshRestoreSelections()
            return
        }

        var options = InitOptions()
        options.cpus = cpus
        options.memoryGiB = UInt64(memory)
        options.diskGiB = UInt64(disk)
        options.restoreImagePath = normalizedRestorePath

        let sharedPath = form.sharedFolderField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !sharedPath.isEmpty {
            options.sharedFolderPath = sharedPath
            options.sharedFolderWritable = (form.sharedWritableCheckbox.state == .on)
        }

        let savePanel = NSSavePanel()
        savePanel.directoryURL = vmRootDirectory
        savePanel.canCreateDirectories = true
        savePanel.prompt = "Create"
        savePanel.nameFieldStringValue = "\(name).\(VMController.bundleExtension)"
        if #available(macOS 11.0, *) {
            if let bundleType = UTType(filenameExtension: VMController.bundleExtension.lowercased()) {
                savePanel.allowedContentTypes = [bundleType]
            }
        } else {
            savePanel.allowedFileTypes = [VMController.bundleExtension]
        }

        savePanel.beginSheetModal(for: form.panel) { [weak self] response in
            guard let self else { return }
            guard response == .OK, var destination = savePanel.url else { return }
            if destination.pathExtension.lowercased() != VMController.bundleExtensionLowercased {
                destination.deletePathExtension()
                destination.appendPathExtension(VMController.bundleExtension)
            }
            self.window?.endSheet(form.panel)
            self.createForm = nil
            self.createSheet = nil
            self.createVM(at: destination, name: name, options: options)
        }
    }

    private func createVM(at bundleURL: URL, name: String, options: InitOptions) {
        viewModel.statusMessage = "Creating \(name)…"
        commandQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.controller.initVM(at: bundleURL, preferredName: name, options: options)
                DispatchQueue.main.async {
                    self.library.addBundle(bundleURL)
                    self.viewModel.statusMessage = "Created VM '\(name)'."
                    self.refreshVMs()
                }
            } catch {
                DispatchQueue.main.async {
                    self.viewModel.statusMessage = "Create failed: \(error.localizedDescription)"
                    self.presentErrorAlert(message: "Failed to Create VM", informative: error.localizedDescription)
                    self.refreshVMs()
                }
            }
        }
    }

    private func presentEditSettings(for entry: VMController.VMListEntry) {
        guard let window = self.window else { return }

        if entry.isRunning {
            presentErrorAlert(message: "VM Running", informative: "Stop \(entry.name) before editing its settings.")
            return
        }

        if let sheet = editSheet {
            window.makeKeyAndOrderFront(sheet)
            return
        }

        viewModel.statusMessage = "Loading settings for \(entry.name)…"
        commandQueue.async { [weak self] in
            guard let self else { return }
            do {
                let config = try self.controller.storedConfig(at: entry.bundleURL)
                DispatchQueue.main.async {
                    self.viewModel.statusMessage = "Ready."
                    self.showEditSheet(for: entry.name, bundleURL: entry.bundleURL, config: config)
                }
            } catch {
                DispatchQueue.main.async {
                    self.viewModel.statusMessage = "Failed to load settings."
                    self.presentErrorAlert(message: "Failed to Load Settings", informative: error.localizedDescription)
                }
            }
        }
    }

    private func showEditSheet(for name: String, bundleURL: URL, config: VMStoredConfig) {
        guard let window = self.window else { return }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 340),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "VM Settings"
        panel.isFloatingPanel = false
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.center()

        let contentView = NSView(frame: panel.contentRect(forFrameRect: panel.frame))
        panel.contentView = contentView

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 24, bottom: 18, right: 24)

        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])

        let descriptionLabel = NSTextField(labelWithString: "Adjust CPU, memory, and shared folder settings. Changes apply the next time the VM starts.")
        descriptionLabel.lineBreakMode = .byWordWrapping
        descriptionLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(descriptionLabel)

        func labeledRow(_ title: String, control: NSView, trailing: NSView? = nil) -> NSView {
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 12, weight: .semibold)

            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 8
            row.distribution = .fill

            control.translatesAutoresizingMaskIntoConstraints = false
            control.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true

            row.addArrangedSubview(label)
            row.addArrangedSubview(control)
            if let trailing = trailing {
                row.addArrangedSubview(trailing)
            }

            return row
        }

        let nameField = NSTextField(string: name)
        nameField.isEnabled = false
        stack.addArrangedSubview(labeledRow("Name", control: nameField))

        let cpuField = NSTextField(string: "\(config.cpus)")
        cpuField.placeholderString = "Number of vCPUs"
        stack.addArrangedSubview(labeledRow("CPUs", control: cpuField))

        let memoryGiB = max(1, Int((config.memoryBytes + ((1 << 30) - 1)) >> 30))
        let memoryField = NSTextField(string: "\(memoryGiB)")
        memoryField.placeholderString = "GiB"
        stack.addArrangedSubview(labeledRow("Memory", control: memoryField))

        let diskFormatter = ByteCountFormatter()
        diskFormatter.allowedUnits = [.useGB]
        diskFormatter.countStyle = .file
        diskFormatter.includesUnit = true
        let diskDisplay = diskFormatter.string(fromByteCount: Int64(config.diskBytes))
        let diskField = NSTextField(string: diskDisplay)
        diskField.isEnabled = false
        stack.addArrangedSubview(labeledRow("Disk", control: diskField))

        let sharedField = NSTextField(string: config.sharedFolderPath ?? "")
        sharedField.placeholderString = "Optional shared folder path"
        let sharedBrowse = NSButton(title: "Browse…", target: self, action: #selector(browseSharedFolder))
        stack.addArrangedSubview(labeledRow("Shared Folder", control: sharedField, trailing: sharedBrowse))

        let sharedWritable = NSButton(checkboxWithTitle: "Allow writes to shared folder", target: nil, action: nil)
        if let sharedPath = config.sharedFolderPath, !sharedPath.isEmpty {
            sharedWritable.state = config.sharedFolderReadOnly ? .off : .on
        } else {
            sharedWritable.state = .off
        }
        stack.addArrangedSubview(sharedWritable)

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 8
        buttonRow.distribution = .fillProportionally

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelEditSheet))
        cancelButton.bezelStyle = .rounded

        let saveButton = NSButton(title: "Save", target: self, action: #selector(confirmEditSheet))
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"

        buttonRow.addArrangedSubview(spacer)
        buttonRow.addArrangedSubview(cancelButton)
        buttonRow.addArrangedSubview(saveButton)
        stack.addArrangedSubview(buttonRow)

        editForm = EditForm(
            name: name,
            bundleURL: bundleURL,
            panel: panel,
            cpuField: cpuField,
            memoryField: memoryField,
            diskField: diskField,
            sharedFolderField: sharedField,
            sharedWritableCheckbox: sharedWritable,
            saveButton: saveButton
        )

        editSheet = panel
        window.beginSheet(panel) { [weak self] _ in
            self?.editSheet = nil
            self?.editForm = nil
        }
    }

    @objc private func cancelEditSheet(_ sender: Any?) {
        guard let panel = editForm?.panel else { return }
        window?.endSheet(panel)
    }

    @objc private func confirmEditSheet(_ sender: Any?) {
        guard let form = editForm else { return }

        guard let cpus = Int(form.cpuField.stringValue), cpus > 0 else {
            presentErrorAlert(message: "Invalid CPU Count", informative: "Enter a positive integer for vCPU count.")
            return
        }

        guard let memoryValue = UInt64(form.memoryField.stringValue), memoryValue > 0 else {
            presentErrorAlert(message: "Invalid Memory", informative: "Enter memory in GiB (positive number).")
            return
        }

        let sharedPathValue = form.sharedFolderField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !sharedPathValue.isEmpty {
            var isDirectory: ObjCBool = false
            if !FileManager.default.fileExists(atPath: sharedPathValue, isDirectory: &isDirectory) || !isDirectory.boolValue {
                presentErrorAlert(message: "Invalid Shared Folder", informative: "Select a folder that exists before saving.")
                return
            }
        }

        window?.endSheet(form.panel)

        let name = form.name
        let bundleURL = form.bundleURL
        let bundlePath = bundleURL.path
        let sharedPath = sharedPathValue.isEmpty ? nil : sharedPathValue
        let writable = (form.sharedWritableCheckbox.state == .on)

        viewModel.busyBundlePaths.insert(bundlePath)
        viewModel.statusMessage = "Updating \(name)…"

        commandQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.controller.updateVMSettings(
                    bundleURL: bundleURL,
                    cpus: cpus,
                    memoryGiB: memoryValue,
                    sharedFolderPath: sharedPath,
                    sharedFolderWritable: writable
                )
                DispatchQueue.main.async {
                    self.viewModel.busyBundlePaths.remove(bundlePath)
                    self.viewModel.statusMessage = "Updated \(name)."
                    self.refreshVMs()
                }
            } catch {
                DispatchQueue.main.async {
                    self.viewModel.busyBundlePaths.remove(bundlePath)
                    self.viewModel.statusMessage = "Update failed: \(error.localizedDescription)"
                    self.presentErrorAlert(message: "Failed to Update VM", informative: error.localizedDescription)
                    self.refreshVMs()
                }
            }
        }
    }

    // MARK: - Settings

    @objc private func openSettings(_ sender: Any?) {
        presentSettingsSheet()
    }

    private func presentSettingsSheet() {
        guard let window = self.window else { return }

        if let sheet = settingsSheet {
            window.makeKeyAndOrderFront(sheet)
            return
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 220),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Settings"
        panel.isFloatingPanel = false
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.center()

        let contentView = NSView(frame: panel.contentRect(forFrameRect: panel.frame))
        panel.contentView = contentView

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 24, bottom: 18, right: 24)

        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])

        let descriptionLabel = NSTextField(labelWithString: "Choose where Virtual Machine Manager stores .VirtualMachine bundles and configure the IPSW feed used for restore image downloads. Changes take effect immediately.")
        descriptionLabel.lineBreakMode = .byWordWrapping
        descriptionLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(descriptionLabel)

        func labeledRow(_ title: String, control: NSView, trailing: NSView? = nil) -> NSView {
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 12, weight: .semibold)

            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 8
            row.distribution = .fill

            control.translatesAutoresizingMaskIntoConstraints = false
            control.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true

            row.addArrangedSubview(label)
            row.addArrangedSubview(control)
            if let trailing = trailing {
                row.addArrangedSubview(trailing)
            }
            return row
        }

        let pathField = NSTextField(string: vmRootDirectory.path)
        pathField.placeholderString = VMCTLApp.defaultVMRootDirectory.path
        let browseButton = NSButton(title: "Browse…", target: self, action: #selector(browseVMFolder(_:)))
        stack.addArrangedSubview(labeledRow("VMs Folder", control: pathField, trailing: browseButton))

        let feedField = NSTextField(string: ipswLibrary.feedURL.absoluteString)
        feedField.placeholderString = IPSWLibrary.defaultFeedURL.absoluteString

        let verifyButton = NSButton(title: "Verify", target: self, action: #selector(verifyFeedURL(_:)))
        verifyButton.bezelStyle = .rounded

        let verifyIndicator = NSImageView()
        verifyIndicator.translatesAutoresizingMaskIntoConstraints = false
        verifyIndicator.imageScaling = .scaleProportionallyDown
        verifyIndicator.isHidden = true
        verifyIndicator.widthAnchor.constraint(equalToConstant: 18).isActive = true
        verifyIndicator.heightAnchor.constraint(equalToConstant: 18).isActive = true

        let feedStack = NSStackView()
        feedStack.orientation = .horizontal
        feedStack.alignment = .centerY
        feedStack.spacing = 6
        feedField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        feedStack.addArrangedSubview(feedField)
        feedStack.addArrangedSubview(verifyButton)
        feedStack.addArrangedSubview(verifyIndicator)

        stack.addArrangedSubview(labeledRow("IPSW Feed URL", control: feedStack))

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 8
        buttonRow.distribution = .fillProportionally

        let resetButton = NSButton(title: "Reset to Default", target: self, action: #selector(resetVMFolderToDefault(_:)))
        resetButton.bezelStyle = .rounded

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelSettingsSheet(_:)))
        cancelButton.bezelStyle = .rounded

        let saveButton = NSButton(title: "Save", target: self, action: #selector(confirmSettingsSheet(_:)))
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"

        buttonRow.addArrangedSubview(resetButton)
        buttonRow.addArrangedSubview(spacer)
        buttonRow.addArrangedSubview(cancelButton)
        buttonRow.addArrangedSubview(saveButton)
        stack.addArrangedSubview(buttonRow)

        settingsForm = SettingsForm(
            panel: panel,
            pathField: pathField,
            feedField: feedField,
            verifyButton: verifyButton,
            verifyIndicator: verifyIndicator
        )
        settingsSheet = panel

        window.beginSheet(panel) { [weak self] _ in
            self?.settingsSheet = nil
            self?.settingsForm = nil
        }
    }

    @objc private func cancelSettingsSheet(_ sender: Any?) {
        guard let panel = settingsForm?.panel else { return }
        window?.endSheet(panel)
    }

    @objc private func confirmSettingsSheet(_ sender: Any?) {
        guard let form = settingsForm else { return }

        let rawPath = form.pathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawPath.isEmpty else {
            presentErrorAlert(message: "Folder Required", informative: "Enter or choose a folder to store your virtual machines.")
            return
        }

        let expandedPath = (rawPath as NSString).expandingTildeInPath
        let resolvedPath = expandedPath.isEmpty ? rawPath : expandedPath
        let selectedURL = URL(fileURLWithPath: resolvedPath, isDirectory: true).standardizedFileURL
        let fm = FileManager.default
        var isDirectory: ObjCBool = false

        if fm.fileExists(atPath: selectedURL.path, isDirectory: &isDirectory) {
            if !isDirectory.boolValue {
                presentErrorAlert(message: "Not a Folder", informative: "\(selectedURL.path) exists but is not a directory.")
                return
            }
        } else {
            do {
                try fm.createDirectory(at: selectedURL, withIntermediateDirectories: true, attributes: nil)
            } catch {
                presentErrorAlert(message: "Failed to Create Folder", informative: error.localizedDescription)
                return
            }
        }

        let trimmedFeed = form.feedField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let chosenFeedURL: URL
        if trimmedFeed.isEmpty {
            chosenFeedURL = IPSWLibrary.defaultFeedURL
        } else if let parsed = URL(string: trimmedFeed), let scheme = parsed.scheme?.lowercased(), ["http", "https"].contains(scheme) {
            chosenFeedURL = parsed
        } else {
            presentErrorAlert(message: "Invalid Feed URL", informative: "Enter a valid HTTP or HTTPS URL for the IPSW feed.")
            return
        }

        window?.endSheet(form.panel)
        applyVMRootDirectory(selectedURL)
        ipswLibrary.feedURL = chosenFeedURL
        ipswManagerController?.feedURLDidChange()
    }

    @objc private func browseVMFolder(_ sender: Any?) {
        guard let form = settingsForm else { return }
        presentSharedFolderPicker(attachedTo: form.panel) { path in
            form.pathField.stringValue = path
        }
    }

    @objc private func resetVMFolderToDefault(_ sender: Any?) {
        settingsForm?.pathField.stringValue = VMCTLApp.defaultVMRootDirectory.path
    }

    @objc private func verifyFeedURL(_ sender: Any?) {
        guard let form = settingsForm else { return }
        let rawValue = form.feedField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawValue.isEmpty else {
            presentErrorAlert(message: "Feed URL Required", informative: "Enter an IPSW feed URL before verifying.")
            return
        }
        guard let parsed = URL(string: rawValue), let scheme = parsed.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            presentErrorAlert(message: "Invalid Feed URL", informative: "Enter a valid HTTP or HTTPS URL for the IPSW feed.")
            return
        }

        pendingFeedVerificationTask?.cancel()
        form.verifyIndicator.isHidden = true
        let previousTitle = form.verifyButton.title
        form.verifyButton.title = "Verifying…"
        form.verifyButton.isEnabled = false

        pendingFeedVerificationTask = ipswLibrary.verifyFeed(at: parsed) { [weak self] result in
            guard let self else { return }
            self.pendingFeedVerificationTask = nil
            guard let currentForm = self.settingsForm else { return }
            currentForm.verifyButton.title = previousTitle
            currentForm.verifyButton.isEnabled = true

            switch result {
            case .success(let entries):
                if let indicator = self.settingsForm?.verifyIndicator {
                    indicator.image = self.verificationSymbol(success: true)
                    if #available(macOS 10.14, *) {
                        indicator.contentTintColor = .systemGreen
                    }
                    indicator.toolTip = "Feed verified (\(entries.count) versions)."
                    indicator.isHidden = false
                }
            case .failure(let error):
                self.settingsForm?.verifyIndicator.isHidden = true
                self.presentErrorAlert(message: "Failed to Verify Feed", informative: error.localizedDescription)
            }
        }
    }

    private func applyVMRootDirectory(_ url: URL) {
        vmRootDirectory = url
        controller.updateRootDirectory(url)
        library.addBundles(in: url)
        userDefaults.set(url.path, forKey: VMCTLApp.vmRootDefaultsKey)
        viewModel.statusMessage = "Using VMs folder at \(url.path)"
        refreshVMs()
    }

    private func refreshCachedRestoreImages() {
        cachedRestoreImages = ipswLibrary.cachedImages()
        if createForm != nil {
            refreshRestoreSelections()
        }
    }

    @objc private func browseRestoreImage(_ sender: Any?) {
        guard let form = createForm else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let ipswType = UTType(filenameExtension: "ipsw") {
            panel.allowedContentTypes = [ipswType]
        }
        panel.title = "Select Restore Image"
        panel.prompt = "Choose"
        panel.beginSheetModal(for: form.panel) { [weak self] response in
            guard let self else { return }
            if response == .OK, let url = panel.url {
                self.createForm?.customRestoreURL = url
                self.createForm?.selectedRestorePath = url.path
                self.refreshRestoreSelections(selecting: url.path)
            }
        }
    }

    @objc private func browseSharedFolder(_ sender: Any?) {
        if let form = createForm {
            presentSharedFolderPicker(attachedTo: form.panel) { path in
                form.sharedFolderField.stringValue = path
            }
        } else if let form = editForm {
            presentSharedFolderPicker(attachedTo: form.panel) { path in
                form.sharedFolderField.stringValue = path
            }
        }
    }

    private func presentSharedFolderPicker(attachedTo panel: NSPanel, update: @escaping (String) -> Void) {
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = false
        openPanel.canChooseDirectories = true
        openPanel.allowsMultipleSelection = false
        openPanel.prompt = "Choose"
        openPanel.beginSheetModal(for: panel) { response in
            if response == .OK, let url = openPanel.url {
                update(url.path)
            }
        }
    }

    private func presentIPSWManager() {
        if ipswManagerController == nil {
            ipswManagerController = IPSWManagerWindowController(library: ipswLibrary) { [weak self] in
                self?.refreshCachedRestoreImages()
            }
        }
        if let window = ipswManagerController?.window {
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    @objc private func showIPSWManagerFromMenu(_ sender: Any?) {
        presentIPSWManager()
    }

    private func verificationSymbol(success: Bool) -> NSImage? {
        if #available(macOS 11.0, *) {
            let name = success ? "checkmark.circle.fill" : "xmark.octagon.fill"
            return NSImage(systemSymbolName: name, accessibilityDescription: nil)
        }
        return NSImage(named: success ? NSImage.statusAvailableName : NSImage.statusUnavailableName)
    }

    // MARK: - IPSW Manager Window

    @MainActor
    private final class IPSWManagerViewModel: ObservableObject {
        struct DownloadStatus {
            let bytesWritten: Int64
            let totalBytes: Int64
            let speedBytesPerSecond: Double
        }

        @Published var entries: [IPSWFeedEntry] = []
        @Published var statusMessage: String = ""
        @Published var loading: Bool = false
        @Published var downloadStatuses: [String: DownloadStatus] = [:]
        @Published var cachedByFilename: [String: IPSWCachedImage] = [:]

        private let library: IPSWLibrary
        private let onCacheChanged: () -> Void
        private var feedTask: URLSessionDataTask?
        private var downloadTasks: [String: URLSessionDownloadTask] = [:]

        init(library: IPSWLibrary, onCacheChanged: @escaping () -> Void) {
            self.library = library
            self.onCacheChanged = onCacheChanged
            reloadCachedImages()
            refreshFeed()
        }

        func refreshFeed() {
            feedTask?.cancel()
            reloadCachedImages()
            loading = true
            statusMessage = "Loading restore images…"
            feedTask = library.fetchFeed { [weak self] result in
                guard let self else { return }
                self.loading = false
                switch result {
                case .success(let entries):
                    self.entries = entries
                    self.statusMessage = "Showing \(entries.count) restore images from \(self.library.feedURL.host ?? self.library.feedURL.absoluteString)."
                case .failure(let error):
                    self.entries = []
                    self.statusMessage = "Failed to load restore images: \(error.localizedDescription)"
                }
            }
        }

        func reloadCachedImages() {
            let cached = library.cachedImages()
            cachedByFilename = Dictionary(uniqueKeysWithValues: cached.map { ($0.fileURL.lastPathComponent, $0) })
        }

        func isCached(_ entry: IPSWFeedEntry) -> Bool {
            return cachedByFilename[entry.filename] != nil
        }

        func progress(for entry: IPSWFeedEntry) -> DownloadStatus? {
            return downloadStatuses[entry.id]
        }

        func download(entry: IPSWFeedEntry) {
            guard downloadStatuses[entry.id] == nil else { return }
            downloadStatuses[entry.id] = DownloadStatus(bytesWritten: 0, totalBytes: 0, speedBytesPerSecond: 0)
            statusMessage = "Downloading \(entry.filename)…"
            let task = library.download(entry: entry, progress: { [weak self] progress in
                guard let self else { return }
                self.downloadStatuses[entry.id] = DownloadStatus(
                    bytesWritten: progress.bytesWritten,
                    totalBytes: progress.totalBytes,
                    speedBytesPerSecond: progress.speedBytesPerSecond
                )
            }, completion: { [weak self] result in
                guard let self else { return }
                self.downloadTasks.removeValue(forKey: entry.id)
                self.downloadStatuses.removeValue(forKey: entry.id)
                switch result {
                case .success:
                    self.reloadCachedImages()
                    self.statusMessage = "Downloaded \(entry.filename)."
                    self.onCacheChanged()
                case .failure(let error):
                    if (error as NSError).code == NSURLErrorCancelled {
                        self.statusMessage = "Cancelled download for \(entry.filename)."
                    } else {
                        self.statusMessage = "Failed to download \(entry.filename): \(error.localizedDescription)"
                    }
                }
            })
            downloadTasks[entry.id] = task
        }

        func delete(entry: IPSWFeedEntry) {
            guard let cached = cachedByFilename[entry.filename] else { return }
            do {
                try library.deleteImage(at: cached.fileURL)
                reloadCachedImages()
                statusMessage = "Deleted \(cached.fileURL.lastPathComponent)."
                onCacheChanged()
            } catch {
                statusMessage = "Failed to delete \(cached.fileURL.lastPathComponent): \(error.localizedDescription)"
            }
        }

        func showInFinder(entry: IPSWFeedEntry) {
            guard let cached = cachedByFilename[entry.filename] else { return }
            NSWorkspace.shared.activateFileViewerSelecting([cached.fileURL])
        }

        func cancel(entry: IPSWFeedEntry) {
            if let task = downloadTasks.removeValue(forKey: entry.id) {
                task.cancel()
                downloadStatuses.removeValue(forKey: entry.id)
                statusMessage = "Cancelled download for \(entry.filename)."
            }
        }
    }

    private struct IPSWManagerView: View {
        @ObservedObject var model: IPSWManagerViewModel

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 8) {
                    Text("Browse available macOS restore images from your configured feed. Download images for offline creation or delete cached copies.")
                        .lineLimit(2)
                    Spacer(minLength: 12)
                    if model.loading {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Button("Reload") {
                        model.refreshFeed()
                    }
                    .disabled(model.loading)
                }

                if model.entries.isEmpty {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(nsColor: .textBackgroundColor))
                            .opacity(0.2)
                        Text(model.loading ? "Loading restore images…" : "No restore images available.")
                            .foregroundStyle(.secondary)
                            .padding()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(model.entries) { entry in
                            IPSWEntryRow(
                                entry: entry,
                                isCached: model.isCached(entry),
                                progress: model.progress(for: entry),
                                downloadAction: { model.download(entry: entry) },
                                deleteAction: { model.delete(entry: entry) },
                                cancelAction: { model.cancel(entry: entry) }
                            )
                            .contextMenu {
                                if model.isCached(entry) {
                                    Button("Delete") {
                                        model.delete(entry: entry)
                                    }
                                }
                                Button("Show in Finder") {
                                    model.showInFinder(entry: entry)
                                }
                            }
                        }
                    }
                    .listStyle(.inset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                Text(model.statusMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(EdgeInsets(top: 18, leading: 24, bottom: 18, trailing: 24))
            .frame(minWidth: 520, minHeight: 360)
        }
    }

    private struct IPSWEntryRow: View {
        let entry: IPSWFeedEntry
        let isCached: Bool
        let progress: IPSWManagerViewModel.DownloadStatus?
        let downloadAction: () -> Void
        let deleteAction: () -> Void
        let cancelAction: () -> Void

        var body: some View {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.displayName)
                        .font(.system(size: 14, weight: .semibold))
                    Text(entry.detailDescription + (isCached ? " · Cached" : ""))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if let progress {
                    VStack(alignment: .trailing, spacing: 4) {
                        if progress.totalBytes > 0 {
                            ProgressView(
                                value: Double(progress.bytesWritten),
                                total: Double(progress.totalBytes)
                            )
                            .frame(width: 160)
                        } else {
                            ProgressView()
                                .frame(width: 160)
                        }
                        Text("\(Self.byteFormatter.string(fromByteCount: progress.bytesWritten)) / \(progress.totalBytes > 0 ? Self.byteFormatter.string(fromByteCount: progress.totalBytes) : "Unknown") · \(Self.speedFormatter(progress.speedBytesPerSecond))")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                let buttonLabel = progress != nil ? "Cancel" : (isCached ? "Delete" : "Download")
                Button(buttonLabel) {
                    if progress != nil {
                        cancelAction()
                    } else if isCached {
                        deleteAction()
                    } else {
                        downloadAction()
                    }
                }
                .buttonStyle(.bordered)
            }
            .padding(.vertical, 4)
        }

        private static let byteFormatter: ByteCountFormatter = {
            let formatter = ByteCountFormatter()
            formatter.allowedUnits = [.useGB, .useMB, .useKB]
            formatter.countStyle = .file
            formatter.includesUnit = true
            return formatter
        }()

        private static func speedFormatter(_ speed: Double) -> String {
            guard speed > 0 else { return "0 B/s" }
            let formatter = ByteCountFormatter()
            formatter.allowedUnits = [.useGB, .useMB, .useKB]
            formatter.countStyle = .file
            formatter.includesUnit = true
            formatter.includesActualByteCount = false
            return formatter.string(fromByteCount: Int64(speed)) + "/s"
        }
    }

    private final class IPSWManagerWindowController: NSWindowController {
        private let viewModel: IPSWManagerViewModel

        init(library: IPSWLibrary, onCacheChanged: @escaping () -> Void) {
            self.viewModel = IPSWManagerViewModel(library: library, onCacheChanged: onCacheChanged)
            let hosting = NSHostingController(rootView: IPSWManagerView(model: viewModel))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 620, height: 420),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Manage Restore Images"
            window.minSize = NSSize(width: 520, height: 360)
            window.contentViewController = hosting
            super.init(window: window)
        }

        required init?(coder: NSCoder) {
            return nil
        }

        func feedURLDidChange() {
            viewModel.refreshFeed()
        }
    }

    // MARK: - Command Runner

    private func runCommand(
        _ arguments: [String],
        waitForTermination: Bool,
        outputHandler: ((String) -> Void)? = nil,
        terminationHandler: ((Int32) -> Void)? = nil,
        completion: (() -> Void)? = nil
    ) {
        commandQueue.async { [weak self] in
            guard let self else { return }

            let process = Process()
            process.executableURL = self.cliURL
            process.arguments = arguments
            var environment = ProcessInfo.processInfo.environment
            if arguments.first == "start" {
                environment["VMCTL_SUPPRESS_DOCK_ICON"] = "1"
            }
            environment["NSUnbufferedIO"] = "YES"
            process.environment = environment

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            do {
                try process.run()
            } catch {
                DispatchQueue.main.async {
                    self.viewModel.statusMessage = "Failed to launch vmctl: \(error.localizedDescription)"
                    completion?()
                }
                return
            }

            if waitForTermination {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let output = String(data: data, encoding: .utf8) ?? ""
                DispatchQueue.main.async {
                    if let handler = outputHandler {
                        handler(output)
                    } else {
                        self.viewModel.statusMessage = output.isEmpty ? "Complete." : output.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
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
                            if let handler = outputHandler {
                                handler(chunk)
                            } else {
                                self?.viewModel.statusMessage = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
                            }
                        }
                    }
                }

                process.terminationHandler = { [weak self] proc in
                    guard let self else { return }
                    DispatchQueue.main.async {
                        if let handler = terminationHandler {
                            handler(proc.terminationStatus)
                        } else {
                            self.viewModel.statusMessage = "vmctl exited with status \(proc.terminationStatus)"
                        }
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

    private func presentErrorAlert(message: String, informative: String) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = message
        alert.informativeText = informative
        if let window = self.window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }
}
#endif
