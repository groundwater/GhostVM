import Foundation

/// Errors that can occur when communicating with the guest
public enum GhostClientError: Error, LocalizedError {
    case notConnected
    case noContent
    case invalidResponse(Int)
    case encodingError
    case decodingError
    case connectionFailed(String)
    case guestError(String)
    case timeout

    public var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Not connected to guest"
        case .noContent:
            return "No content available"
        case .invalidResponse(let code):
            return "Invalid response from guest (status \(code))"
        case .encodingError:
            return "Failed to encode request"
        case .decodingError:
            return "Failed to decode response"
        case .connectionFailed(let reason):
            return "Connection failed: \(reason)"
        case .guestError(let msg):
            return msg
        case .timeout:
            return "Connection timed out"
        }
    }
}

/// Response from GET /clipboard endpoint
public struct ClipboardGetResponse: Codable {
    public let content: String?
    public let type: String?
    public let changeCount: Int?

    public init(content: String?, type: String? = nil, changeCount: Int? = nil) {
        self.content = content
        self.type = type
        self.changeCount = changeCount
    }
}

/// Response from POST /files/receive endpoint
public struct FileReceiveResponse: Codable {
    public let path: String

    public init(path: String) {
        self.path = path
    }
}

/// Response from GET /files endpoint
public struct FileListResponse: Codable {
    public let files: [String]

    public init(files: [String]) {
        self.files = files
    }
}

/// Response from GET /urls endpoint
public struct URLListResponse: Codable {
    public let urls: [String]

    public init(urls: [String]) {
        self.urls = urls
    }
}

/// Response from GET /logs endpoint
public struct LogListResponse: Codable {
    public let logs: [String]

    public init(logs: [String]) {
        self.logs = logs
    }
}

/// Request body for POST /clipboard endpoint
public struct ClipboardPostRequest: Codable {
    public let content: String
    public let type: String

    public init(content: String, type: String = "public.utf8-plain-text") {
        self.content = content
        self.type = type
    }
}

// MARK: - App Management Types

/// Info about a running GUI application
public struct AppInfo: Codable {
    public let name: String
    public let bundleId: String
    public let pid: Int32
    public let isActive: Bool

    public init(name: String, bundleId: String, pid: Int32, isActive: Bool) {
        self.name = name
        self.bundleId = bundleId
        self.pid = pid
        self.isActive = isActive
    }
}

/// Response from GET /apps endpoint
public struct AppListResponse: Codable {
    public let apps: [AppInfo]

    public init(apps: [AppInfo]) {
        self.apps = apps
    }
}

// MARK: - File System Types

/// Entry in a directory listing
public struct FSEntry: Codable {
    public let name: String
    public let isDir: Bool
    public let size: Int64
    public let modified: Double

    public init(name: String, isDir: Bool, size: Int64, modified: Double) {
        self.name = name
        self.isDir = isDir
        self.size = size
        self.modified = modified
    }
}

/// Response from GET /fs endpoint
public struct FSListResponse: Codable {
    public let path: String
    public let entries: [FSEntry]

    public init(path: String, entries: [FSEntry]) {
        self.path = path
        self.entries = entries
    }
}

// MARK: - Accessibility Types

/// Frame rectangle for accessibility elements
public struct AXFrame: Codable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// A node in the accessibility tree
public struct AXNode: Codable {
    public let role: String?
    public let title: String?
    public let label: String?
    public let value: String?
    public let frame: AXFrame?
    public let children: [AXNode]?

    public init(role: String?, title: String?, label: String?, value: String?, frame: AXFrame?, children: [AXNode]?) {
        self.role = role
        self.title = title
        self.label = label
        self.value = value
        self.frame = frame
        self.children = children
    }
}

// MARK: - Exec Types

/// Response from POST /exec endpoint
public struct ExecResponse: Codable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

// MARK: - Batch Action Types

/// A single action in a batch request
public struct BatchAction: Codable {
    public let type: String
    // Common params
    public let bundleId: String?
    public let x: Double?
    public let y: Double?
    public let label: String?
    public let role: String?
    public let button: String?
    public let endX: Double?
    public let endY: Double?
    public let text: String?
    public let keys: [String]?
    public let modifiers: [String]?
    public let rate: Int?
    public let value: String?
    public let action: String?
    public let path: [String]?
    public let ms: Int?
    public let full: Bool?
    public let command: String?
    public let args: [String]?
    public let timeout: Int?
    public let app: String?
    public let timeoutMs: Int?
    public let threshold: Double?

    public init(
        type: String,
        bundleId: String? = nil,
        x: Double? = nil, y: Double? = nil,
        label: String? = nil, role: String? = nil,
        button: String? = nil,
        endX: Double? = nil, endY: Double? = nil,
        text: String? = nil,
        keys: [String]? = nil, modifiers: [String]? = nil, rate: Int? = nil,
        value: String? = nil, action: String? = nil,
        path: [String]? = nil,
        ms: Int? = nil, full: Bool? = nil,
        command: String? = nil, args: [String]? = nil, timeout: Int? = nil,
        app: String? = nil,
        timeoutMs: Int? = nil, threshold: Double? = nil
    ) {
        self.type = type
        self.bundleId = bundleId
        self.x = x; self.y = y
        self.label = label; self.role = role
        self.button = button
        self.endX = endX; self.endY = endY
        self.text = text
        self.keys = keys; self.modifiers = modifiers; self.rate = rate
        self.value = value; self.action = action
        self.path = path
        self.ms = ms; self.full = full
        self.command = command; self.args = args; self.timeout = timeout
        self.app = app
        self.timeoutMs = timeoutMs; self.threshold = threshold
    }
}

/// Options for batch execution
public struct BatchOptions: Codable {
    public let stabilityTimeoutMs: Int?
    public let stabilityThreshold: Double?
    public let screenshotScale: Double?
    public let maxBatchTimeoutMs: Int?

    public init(
        stabilityTimeoutMs: Int? = nil,
        stabilityThreshold: Double? = nil,
        screenshotScale: Double? = nil,
        maxBatchTimeoutMs: Int? = nil
    ) {
        self.stabilityTimeoutMs = stabilityTimeoutMs
        self.stabilityThreshold = stabilityThreshold
        self.screenshotScale = screenshotScale
        self.maxBatchTimeoutMs = maxBatchTimeoutMs
    }
}

/// Request body for POST /api/v1/batch
public struct BatchRequest: Codable {
    public let actions: [BatchAction]
    public let options: BatchOptions?

    public init(actions: [BatchAction], options: BatchOptions? = nil) {
        self.actions = actions
        self.options = options
    }
}

/// Result of a single step in the batch
public struct BatchStepResult: Codable {
    public let index: Int
    public let type: String
    public let success: Bool
    public let durationMs: Int
    public let heuristic: String?
    public let error: String?
    public let screenshot: String?

    public init(index: Int, type: String, success: Bool, durationMs: Int, heuristic: String? = nil, error: String? = nil, screenshot: String? = nil) {
        self.index = index
        self.type = type
        self.success = success
        self.durationMs = durationMs
        self.heuristic = heuristic
        self.error = error
        self.screenshot = screenshot
    }
}

/// Response from POST /api/v1/batch
public struct BatchResponse: Codable {
    public let success: Bool
    public let stepsCompleted: Int
    public let stepsTotal: Int
    public let steps: [BatchStepResult]
    public let screenshot: String?
    public let elements: [BatchElement]?
    public let display: BatchDisplayInfo?

    public init(success: Bool, stepsCompleted: Int, stepsTotal: Int, steps: [BatchStepResult], screenshot: String? = nil, elements: [BatchElement]? = nil, display: BatchDisplayInfo? = nil) {
        self.success = success
        self.stepsCompleted = stepsCompleted
        self.stepsTotal = stepsTotal
        self.steps = steps
        self.screenshot = screenshot
        self.elements = elements
        self.display = display
    }
}

/// An interactive UI element found via accessibility, annotated on the screenshot
public struct BatchElement: Codable {
    public let id: Int
    public let role: String
    public let label: String?
    public let title: String?
    public let value: String?
    public let frame: BatchElementFrame

    public init(id: Int, role: String, label: String?, title: String?, value: String?, frame: BatchElementFrame) {
        self.id = id
        self.role = role
        self.label = label
        self.title = title
        self.value = value
        self.frame = frame
    }
}

/// Frame of an interactive element (window-relative points)
public struct BatchElementFrame: Codable {
    public let x: Int
    public let y: Int
    public let w: Int
    public let h: Int

    public init(x: Int, y: Int, w: Int, h: Int) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }
}

/// Display metadata for coordinate mapping
public struct BatchDisplayInfo: Codable {
    public let screenshotWidth: Int
    public let screenshotHeight: Int
    public let windowFrame: BatchElementFrame?
    public let backingScaleFactor: Double

    public init(screenshotWidth: Int, screenshotHeight: Int, windowFrame: BatchElementFrame?, backingScaleFactor: Double) {
        self.screenshotWidth = screenshotWidth
        self.screenshotHeight = screenshotHeight
        self.windowFrame = windowFrame
        self.backingScaleFactor = backingScaleFactor
    }
}

/// Response from GET /accessibility endpoint
public struct AXTreeResponse: Codable {
    public let app: String
    public let bundleId: String
    public let pid: Int32?
    public let window: String?
    public let frame: AXFrame?
    public let tree: AXNode?

    public init(app: String, bundleId: String, pid: Int32? = nil, window: String?, frame: AXFrame?, tree: AXNode?) {
        self.app = app
        self.bundleId = bundleId
        self.pid = pid
        self.window = window
        self.frame = frame
        self.tree = tree
    }
}

/// Specifies which process(es) to target for accessibility queries/actions.
public enum AXTarget: Equatable {
    case front
    case visible
    case all
    case pid(Int32)
    case app(String)

    public init?(queryValue: String) {
        switch queryValue {
        case "front": self = .front
        case "visible": self = .visible
        case "all": self = .all
        default:
            if queryValue.hasPrefix("pid:"), let p = Int32(queryValue.dropFirst(4)) {
                self = .pid(p)
            } else if queryValue.hasPrefix("app:") {
                self = .app(String(queryValue.dropFirst(4)))
            } else {
                return nil
            }
        }
    }

    public var queryValue: String {
        switch self {
        case .front: return "front"
        case .visible: return "visible"
        case .all: return "all"
        case .pid(let p): return "pid:\(p)"
        case .app(let id): return "app:\(id)"
        }
    }

    public var isMulti: Bool { self == .visible || self == .all }
}
