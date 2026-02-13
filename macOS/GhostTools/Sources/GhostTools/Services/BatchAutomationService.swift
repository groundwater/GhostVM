import AppKit
import Foundation

// MARK: - Batch Codable Types (guest-side mirror of GhostVMKit)

struct GuestBatchAction: Codable {
    let type: String
    let bundleId: String?
    let x: Double?
    let y: Double?
    let label: String?
    let role: String?
    let button: String?
    let endX: Double?
    let endY: Double?
    let text: String?
    let keys: [String]?
    let modifiers: [String]?
    let rate: Int?
    let value: String?
    let action: String?
    let path: [String]?
    let ms: Int?
    let full: Bool?  // deprecated, ignored — screenshots are always full-screen
    let command: String?
    let args: [String]?
    let timeout: Int?
    let app: String?
    let timeoutMs: Int?
    let threshold: Double?
}

struct GuestBatchOptions: Codable {
    let stabilityTimeoutMs: Int?
    let stabilityThreshold: Double?
    let screenshotScale: Double?
    let maxBatchTimeoutMs: Int?
}

struct GuestBatchRequest: Codable {
    let actions: [GuestBatchAction]
    let options: GuestBatchOptions?
}

struct GuestBatchStepResult: Codable {
    let index: Int
    let type: String
    let success: Bool
    let durationMs: Int
    let heuristic: String?
    let error: String?
    let screenshot: String?
}

struct GuestBatchElementFrame: Codable {
    let x: Int
    let y: Int
    let w: Int
    let h: Int
}

struct GuestBatchElement: Codable {
    let id: Int
    let role: String
    let label: String?
    let title: String?
    let value: String?
    let frame: GuestBatchElementFrame
    let changeAge: Int?
}

struct GuestBatchDisplayInfo: Codable {
    let screenshotWidth: Int
    let screenshotHeight: Int
    let backingScaleFactor: Double
}

struct GuestBatchResponse: Codable {
    let success: Bool
    let stepsCompleted: Int
    let stepsTotal: Int
    let steps: [GuestBatchStepResult]
    let screenshot: String?
    let elements: [GuestBatchElement]?
    let display: GuestBatchDisplayInfo?
}

// MARK: - Stability Detection

final class GuestStabilityDetector {
    private let screenshotService: ScreenshotService

    init(screenshotService: ScreenshotService) {
        self.screenshotService = screenshotService
    }

    enum ChangeStabilityResult: String {
        case changedAndStable
        case changeOnly
        case noChange
    }

    func waitForStability(
        timeoutMs: Int = 3000,
        threshold: Double = 0.005,
        pollIntervalMs: Int = 150
    ) async -> (stable: Bool, elapsedMs: Int) {
        let start = DispatchTime.now()
        let deadline = start.uptimeNanoseconds + UInt64(timeoutMs) * 1_000_000

        guard let firstImage = try? screenshotService.captureRawCGImage() else {
            return (false, 0)
        }

        var previousImage = firstImage
        var stableFrames = 0
        let requiredStableFrames = 2

        while DispatchTime.now().uptimeNanoseconds < deadline {
            try? await Task.sleep(nanoseconds: UInt64(pollIntervalMs) * 1_000_000)
            guard let currentImage = try? screenshotService.captureRawCGImage() else {
                continue
            }

            let diff = pixelDifference(previousImage, currentImage)
            previousImage = currentImage

            if diff < threshold {
                stableFrames += 1
                if stableFrames >= requiredStableFrames {
                    let elapsed = Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
                    return (true, elapsed)
                }
            } else {
                stableFrames = 0
            }
        }

        let elapsed = Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
        return (false, elapsed)
    }

    func waitForChangeAndStability(
        changeTimeoutMs: Int = 2000,
        stabilityTimeoutMs: Int = 3000,
        threshold: Double = 0.005,
        pollIntervalMs: Int = 150
    ) async -> (result: ChangeStabilityResult, elapsedMs: Int) {
        let start = DispatchTime.now()

        guard let baseImage = try? screenshotService.captureRawCGImage() else {
            return (.noChange, 0)
        }

        let changeDeadline = start.uptimeNanoseconds + UInt64(changeTimeoutMs) * 1_000_000
        var changeDetected = false
        var latestImage = baseImage

        while DispatchTime.now().uptimeNanoseconds < changeDeadline {
            try? await Task.sleep(nanoseconds: UInt64(pollIntervalMs) * 1_000_000)
            guard let currentImage = try? screenshotService.captureRawCGImage() else {
                continue
            }

            let diff = pixelDifference(baseImage, currentImage)
            latestImage = currentImage
            if diff >= threshold {
                changeDetected = true
                break
            }
        }

        if !changeDetected {
            let elapsed = Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
            return (.noChange, elapsed)
        }

        let stabilityDeadline = DispatchTime.now().uptimeNanoseconds + UInt64(stabilityTimeoutMs) * 1_000_000
        var previousImage = latestImage
        var stableFrames = 0
        let requiredStableFrames = 2

        while DispatchTime.now().uptimeNanoseconds < stabilityDeadline {
            try? await Task.sleep(nanoseconds: UInt64(pollIntervalMs) * 1_000_000)
            guard let currentImage = try? screenshotService.captureRawCGImage() else {
                continue
            }

            let diff = pixelDifference(previousImage, currentImage)
            previousImage = currentImage

            if diff < threshold {
                stableFrames += 1
                if stableFrames >= requiredStableFrames {
                    let elapsed = Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
                    return (.changedAndStable, elapsed)
                }
            } else {
                stableFrames = 0
            }
        }

        let elapsed = Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
        return (.changeOnly, elapsed)
    }

    private func pixelDifference(_ img1: CGImage, _ img2: CGImage) -> Double {
        guard img1.width == img2.width, img1.height == img2.height else { return 1.0 }

        let width = img1.width
        let height = img1.height
        let bytesPerRow = width * 4
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        var buf1 = [UInt8](repeating: 0, count: height * bytesPerRow)
        var buf2 = [UInt8](repeating: 0, count: height * bytesPerRow)

        guard let ctx1 = CGContext(
            data: &buf1, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: colorSpace, bitmapInfo: bitmapInfo
        ), let ctx2 = CGContext(
            data: &buf2, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: colorSpace, bitmapInfo: bitmapInfo
        ) else {
            return 1.0
        }

        ctx1.draw(img1, in: CGRect(x: 0, y: 0, width: width, height: height))
        ctx2.draw(img2, in: CGRect(x: 0, y: 0, width: width, height: height))

        let threshold: UInt8 = 5
        let step = 4
        var diffCount = 0
        var sampleCount = 0

        for y in stride(from: 0, to: height, by: step) {
            for x in stride(from: 0, to: width, by: step) {
                let offset = y * bytesPerRow + x * 4
                sampleCount += 1
                for c in 0..<3 {
                    let diff = Int(buf1[offset + c]) - Int(buf2[offset + c])
                    if abs(diff) > Int(threshold) {
                        diffCount += 1
                        break
                    }
                }
            }
        }

        return sampleCount > 0 ? Double(diffCount) / Double(sampleCount) : 0.0
    }
}

// MARK: - Batch Service

@MainActor
final class BatchAutomationService {
    static let shared = BatchAutomationService()

    private let screenshotService = ScreenshotService.shared
    private lazy var stabilityDetector = GuestStabilityDetector(screenshotService: screenshotService)

    private init() {}

    struct AnnotatedResult {
        let imageBase64: String?
        let elements: [[String: Any]]
        let display: [String: Any]
    }

    func captureAnnotatedScreenshot(scale: Double = 0.5) async -> AnnotatedResult {
        let interactive = await waitForA11yStabilization()

        // Track element changes for recency coloring
        let changeAges = ElementChangeTracker.shared.track(interactive.elements)

        // Show live overlay for visual feedback
        if !interactive.elements.isEmpty {
            A11yElementOverlay.shared.showElements(interactive.elements, changeAges: changeAges)
        }

        // Capture full-screen screenshot
        guard let baseImage = try? screenshotService.captureRawCGImage() else {
            return AnnotatedResult(imageBase64: nil, elements: [], display: [:])
        }

        let backingScaleFactor = NSScreen.main?.backingScaleFactor ?? 2.0

        // Annotate the image with overlays if we have elements
        let finalImage: CGImage
        if !interactive.elements.isEmpty,
           let annotated = screenshotService.annotateWithElements(
               baseImage,
               elements: interactive.elements,
               changeAges: changeAges
           ) {
            finalImage = annotated
        } else {
            finalImage = baseImage
        }

        // Encode the final image to JPEG with scaling
        let imageBase64: String?
        if scale < 1.0 {
            let width = max(1, Int(Double(finalImage.width) * scale))
            let height = max(1, Int(Double(finalImage.height) * scale))

            guard let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ) else {
                imageBase64 = nil
                return AnnotatedResult(imageBase64: nil, elements: [], display: [:])
            }

            context.interpolationQuality = .high
            context.draw(finalImage, in: CGRect(x: 0, y: 0, width: width, height: height))

            if let scaled = context.makeImage() {
                let rep = NSBitmapImageRep(cgImage: scaled)
                if let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7]) {
                    imageBase64 = data.base64EncodedString()
                } else {
                    imageBase64 = nil
                }
            } else {
                imageBase64 = nil
            }
        } else {
            let rep = NSBitmapImageRep(cgImage: finalImage)
            if let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7]) {
                imageBase64 = data.base64EncodedString()
            } else {
                imageBase64 = nil
            }
        }

        // Build display metadata
        let display: [String: Any] = [
            "scroll": [
                "up": interactive.scrollState.canScrollUp,
                "down": interactive.scrollState.canScrollDown,
                "left": interactive.scrollState.canScrollLeft,
                "right": interactive.scrollState.canScrollRight
            ],
            "screenshotWidth": finalImage.width,
            "screenshotHeight": finalImage.height,
            "backingScaleFactor": backingScaleFactor
        ]

        // Build elements JSON
        let elementsJSON: [[String: Any]] = interactive.elements.map { elem in
            var dict: [String: Any] = [
                "id": elem.id,
                "role": elem.role,
                "frame": [
                    "x": Int(elem.frame.x),
                    "y": Int(elem.frame.y),
                    "w": Int(elem.frame.width),
                    "h": Int(elem.frame.height)
                ],
                "changeAge": changeAges[elem.id] ?? 0
            ]
            if let label = elem.label { dict["label"] = label }
            if let title = elem.title { dict["title"] = title }
            if let value = elem.value { dict["value"] = value }
            return dict
        }

        return AnnotatedResult(imageBase64: imageBase64, elements: elementsJSON, display: display)
    }

    func execute(request: GuestBatchRequest) async -> GuestBatchResponse {
        let actions = request.actions
        let options = request.options
        let stabilityTimeoutMs = options?.stabilityTimeoutMs ?? 3000
        let stabilityThreshold = options?.stabilityThreshold ?? 0.005
        let scale = options?.screenshotScale ?? 0.5

        WaitIndicatorOverlay.shared.show()

        var stepResults: [GuestBatchStepResult] = []
        var allSuccess = true

        for (index, action) in actions.enumerated() {
            let stepStart = DispatchTime.now()
            var heuristic: String?

            do {
                switch action.type {
                case "click", "doubleClick", "rightClick":
                    _ = try PointerService.shared.sendEvent(
                        action: action.type,
                        x: action.x, y: action.y,
                        button: action.button, label: action.label,
                        endX: nil, endY: nil
                    )
                    let (stable, ms) = await stabilityDetector.waitForStability(
                        timeoutMs: stabilityTimeoutMs, threshold: stabilityThreshold
                    )
                    heuristic = stable ? "stable_\(ms)ms" : "timeout_\(ms)ms"

                case "drag":
                    _ = try PointerService.shared.sendEvent(
                        action: "drag",
                        x: action.x, y: action.y,
                        button: nil, label: action.label,
                        endX: action.endX, endY: action.endY
                    )
                    let (stable, ms) = await stabilityDetector.waitForStability(
                        timeoutMs: stabilityTimeoutMs, threshold: stabilityThreshold
                    )
                    heuristic = stable ? "stable_\(ms)ms" : "timeout_\(ms)ms"

                case "scroll":
                    _ = try PointerService.shared.sendEvent(
                        action: "scroll",
                        x: action.x, y: action.y,
                        button: nil, label: nil,
                        endX: nil, endY: nil,
                        deltaX: action.endX, deltaY: action.endY
                    )
                    let (stable, ms) = await stabilityDetector.waitForStability(
                        timeoutMs: stabilityTimeoutMs, threshold: stabilityThreshold
                    )
                    heuristic = stable ? "stable_\(ms)ms" : "timeout_\(ms)ms"

                case "type":
                    try KeyboardService.shared.sendInput(
                        text: action.text, keys: nil, modifiers: action.modifiers, rate: action.rate
                    )
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    heuristic = "delay_50ms"

                case "keys":
                    try KeyboardService.shared.sendInput(
                        text: nil, keys: action.keys, modifiers: action.modifiers, rate: action.rate
                    )
                    if isNavigationOrModifierKeys(action.keys) {
                        let (result, ms) = await stabilityDetector.waitForChangeAndStability(
                            changeTimeoutMs: 1000,
                            stabilityTimeoutMs: stabilityTimeoutMs,
                            threshold: stabilityThreshold
                        )
                        heuristic = "\(result.rawValue)_\(ms)ms"
                    } else {
                        try? await Task.sleep(nanoseconds: 50_000_000)
                        heuristic = "delay_50ms"
                    }

                case "ax_action":
                    try AccessibilityService.shared.performAction(
                        label: action.label,
                        role: action.role,
                        action: action.action ?? "AXPress",
                        target: .front
                    )
                    let (stable, ms) = await stabilityDetector.waitForStability(
                        timeoutMs: stabilityTimeoutMs, threshold: stabilityThreshold
                    )
                    heuristic = stable ? "stable_\(ms)ms" : "timeout_\(ms)ms"

                case "ax_menu":
                    guard let path = action.path else { throw BatchError.missingParam("path") }
                    try AccessibilityService.shared.triggerMenuItem(path: path, target: .front)
                    let (stable, ms) = await stabilityDetector.waitForStability(
                        timeoutMs: stabilityTimeoutMs, threshold: stabilityThreshold
                    )
                    heuristic = stable ? "stable_\(ms)ms" : "timeout_\(ms)ms"

                case "ax_type":
                    guard let value = action.value else { throw BatchError.missingParam("value") }
                    try AccessibilityService.shared.setValue(
                        value,
                        label: action.label,
                        role: action.role,
                        target: .front
                    )
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    heuristic = "delay_100ms"

                case "launch":
                    guard let bundleId = action.bundleId else { throw BatchError.missingParam("bundleId") }
                    guard AppManagementService.shared.launchApp(bundleId: bundleId) else {
                        throw BatchError.actionFailed("Failed to launch app: \(bundleId)")
                    }
                    let launched = await pollFrontmostApp(bundleId: bundleId, timeoutMs: action.timeoutMs ?? 5000)
                    heuristic = launched ? "launched" : "launch_timeout"

                case "activate":
                    guard let bundleId = action.bundleId else { throw BatchError.missingParam("bundleId") }
                    guard AppManagementService.shared.activateApp(bundleId: bundleId) else {
                        throw BatchError.actionFailed("Failed to activate app: \(bundleId)")
                    }
                    let activated = await pollFrontmostApp(bundleId: bundleId, timeoutMs: 2000)
                    if activated { try? await Task.sleep(nanoseconds: 200_000_000) }
                    heuristic = activated ? "activated" : "activate_timeout"

                case "open":
                    guard let path = action.path?.first ?? action.text else {
                        throw BatchError.missingParam("path or text")
                    }
                    try openPath(path, app: action.app)
                    let (stable, ms) = await stabilityDetector.waitForStability(
                        timeoutMs: action.timeoutMs ?? 3000, threshold: stabilityThreshold
                    )
                    heuristic = stable ? "stable_\(ms)ms" : "timeout_\(ms)ms"

                case "exec":
                    guard let command = action.command else { throw BatchError.missingParam("command") }
                    _ = try runCommand(command: command, args: action.args ?? [], timeout: action.timeout ?? 30)
                    heuristic = "exec_done"

                case "wait":
                    let ms = action.ms ?? 1000
                    try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
                    heuristic = "waited_\(ms)ms"

                case "wait_stable":
                    let timeout = action.timeoutMs ?? stabilityTimeoutMs
                    let threshold = action.threshold ?? stabilityThreshold
                    let (stable, ms) = await stabilityDetector.waitForStability(
                        timeoutMs: timeout, threshold: threshold
                    )
                    heuristic = stable ? "stable_\(ms)ms" : "timeout_\(ms)ms"

                case "screenshot":
                    let imageBase64 = screenshotService.captureJPEGBase64(scale: scale, quality: 0.7)
                    stepResults.append(GuestBatchStepResult(
                        index: index,
                        type: action.type,
                        success: true,
                        durationMs: elapsedMs(since: stepStart),
                        heuristic: "captured",
                        error: nil,
                        screenshot: imageBase64
                    ))
                    continue

                default:
                    throw BatchError.actionFailed("Unknown action type: \(action.type)")
                }

                stepResults.append(GuestBatchStepResult(
                    index: index,
                    type: action.type,
                    success: true,
                    durationMs: elapsedMs(since: stepStart),
                    heuristic: heuristic,
                    error: nil,
                    screenshot: nil
                ))
            } catch {
                allSuccess = false
                let desc = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                stepResults.append(GuestBatchStepResult(
                    index: index,
                    type: action.type,
                    success: false,
                    durationMs: elapsedMs(since: stepStart),
                    heuristic: heuristic,
                    error: desc,
                    screenshot: nil
                ))
            }
        }

        WaitIndicatorOverlay.shared.hide()

        let annotated = await captureAnnotatedScreenshot(scale: scale)
        let batchElements = mapBatchElements(annotated.elements)
        let displayInfo = mapDisplayInfo(annotated.display)

        return GuestBatchResponse(
            success: allSuccess,
            stepsCompleted: stepResults.filter(\.success).count,
            stepsTotal: actions.count,
            steps: stepResults,
            screenshot: annotated.imageBase64,
            elements: batchElements,
            display: displayInfo
        )
    }

    private enum BatchError: Error, LocalizedError {
        case missingParam(String)
        case actionFailed(String)

        var errorDescription: String? {
            switch self {
            case .missingParam(let name): return "Missing required parameter: \(name)"
            case .actionFailed(let detail): return detail
            }
        }
    }

    private func isNavigationOrModifierKeys(_ keys: [String]?) -> Bool {
        guard let keys else { return false }
        let navKeys: Set<String> = [
            "return", "enter", "tab", "escape", "esc",
            "left", "right", "up", "down",
            "home", "end", "pageup", "pagedown",
            "f1", "f2", "f3", "f4", "f5", "f6",
            "f7", "f8", "f9", "f10", "f11", "f12"
        ]
        return keys.contains { navKeys.contains($0.lowercased()) }
    }

    private func pollFrontmostApp(bundleId: String, timeoutMs: Int) async -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeoutMs) * 1_000_000
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleId {
                return true
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return false
    }

    private func openPath(_ path: String, app: String?) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        if let app {
            process.arguments = ["-b", app, path]
        } else {
            process.arguments = [path]
        }
        try process.run()
    }

    private func runCommand(command: String, args: [String], timeout: Int) throws -> (Int32, String, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = args
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()

        let deadline = DispatchTime.now() + .seconds(timeout)
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            process.waitUntilExit()
            group.leave()
        }
        if group.wait(timeout: deadline) == .timedOut {
            process.terminate()
            throw BatchError.actionFailed("Process timed out after \(timeout)s")
        }

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (process.terminationStatus, stdout, stderr)
    }

    private func mapBatchElements(_ elements: [[String: Any]]) -> [GuestBatchElement]? {
        if elements.isEmpty { return nil }
        return elements.compactMap { dict in
            guard let id = dict["id"] as? Int,
                  let role = dict["role"] as? String,
                  let frameDict = dict["frame"] as? [String: Any],
                  let x = frameDict["x"] as? Int,
                  let y = frameDict["y"] as? Int,
                  let w = frameDict["w"] as? Int,
                  let h = frameDict["h"] as? Int else {
                return nil
            }
            return GuestBatchElement(
                id: id,
                role: role,
                label: dict["label"] as? String,
                title: dict["title"] as? String,
                value: dict["value"] as? String,
                frame: GuestBatchElementFrame(x: x, y: y, w: w, h: h),
                changeAge: dict["changeAge"] as? Int
            )
        }
    }

    private func mapDisplayInfo(_ display: [String: Any]) -> GuestBatchDisplayInfo? {
        let sw = display["screenshotWidth"] as? Int ?? 0
        let sh = display["screenshotHeight"] as? Int ?? 0
        guard sw > 0, sh > 0 else { return nil }

        return GuestBatchDisplayInfo(
            screenshotWidth: sw,
            screenshotHeight: sh,
            backingScaleFactor: (display["backingScaleFactor"] as? Double) ?? 2.0
        )
    }

    private func elapsedMs(since start: DispatchTime) -> Int {
        Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
    }

    // MARK: - A11y Stabilization

    /// Wait for the a11y tree to stabilize by comparing element fingerprints across polls.
    /// Returns as soon as two consecutive snapshots match, or after maxWaitMs.
    private func waitForA11yStabilization(
        maxWaitMs: Int = 500,
        pollIntervalMs: Int = 100
    ) async -> AccessibilityService.InteractiveElementsResult {
        let first = AccessibilityService.shared.getInteractiveElements()
        var previousFingerprint = a11yFingerprint(first.elements)
        var bestResult = first

        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(maxWaitMs) * 1_000_000

        while DispatchTime.now().uptimeNanoseconds < deadline {
            try? await Task.sleep(nanoseconds: UInt64(pollIntervalMs) * 1_000_000)

            let current = AccessibilityService.shared.getInteractiveElements()
            let currentFingerprint = a11yFingerprint(current.elements)

            if currentFingerprint == previousFingerprint {
                return current
            }

            previousFingerprint = currentFingerprint
            bestResult = current
        }

        return bestResult
    }

    /// Produce a set of fingerprint strings for a11y stability comparison.
    /// Uses the same 4px-rounded grid as ElementChangeTracker, plus label/title/value.
    private func a11yFingerprint(_ elements: [AccessibilityService.InteractiveElement]) -> Set<String> {
        Set(elements.map { elem in
            let x = Int((elem.frame.x / 4.0).rounded()) * 4
            let y = Int((elem.frame.y / 4.0).rounded()) * 4
            let w = Int((elem.frame.width / 4.0).rounded()) * 4
            let h = Int((elem.frame.height / 4.0).rounded()) * 4
            return "\(elem.role)|\(x)|\(y)|\(w)|\(h)|\(elem.label ?? "")|\(elem.title ?? "")|\(elem.value ?? "")"
        })
    }
}
