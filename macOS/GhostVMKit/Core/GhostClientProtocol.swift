import Foundation

/// Protocol for communicating with GhostTools running in the guest VM.
/// Enables mock injection for testing services that depend on guest communication.
public protocol GhostClientProtocol {
    func getClipboard() async throws -> ClipboardGetResponse
    func setClipboard(data: Data, type: String) async throws
    func sendFile(fileURL: URL, relativePath: String?, batchID: String?, isLastInBatch: Bool, permissions: Int?, progressHandler: ((Double) -> Void)?) async throws -> String
    func fetchFile(at path: String) async throws -> (data: Data, filename: String, permissions: Int?)
    func listFiles() async throws -> [String]
    func clearFileQueue() async throws
    func checkHealth() async -> Bool

    // App management
    func listApps() async throws -> AppListResponse
    func launchApp(bundleId: String) async throws
    func activateApp(bundleId: String) async throws
    func quitApp(bundleId: String) async throws

    // File system
    func listDirectory(path: String) async throws -> FSListResponse
    func mkdir(path: String) async throws
    func deleteFile(path: String) async throws
    func moveFile(from: String, to: String) async throws

    // Accessibility
    func getAccessibilityTree(depth: Int, target: AXTarget) async throws -> AXTreeResponse
    func getAccessibilityTrees(depth: Int, target: AXTarget) async throws -> [AXTreeResponse]
    func performAccessibilityAction(label: String?, role: String?, action: String, target: AXTarget, wait: Bool) async throws
    func triggerMenuItem(path: [String], target: AXTarget, wait: Bool) async throws
    func setAccessibilityValue(_ value: String, label: String?, role: String?, target: AXTarget) async throws
    func getFocusedElement(target: AXTarget) async throws -> [String: Any]

    // Pointer
    func sendPointerEvent(action: String, x: Double?, y: Double?, button: String?, label: String?, endX: Double?, endY: Double?, deltaX: Double?, deltaY: Double?, wait: Bool) async throws -> Data?

    // Keyboard
    func sendKeyboardInput(text: String?, keys: [String]?, modifiers: [String]?, rate: Int?, wait: Bool) async throws

    // Shell exec
    func exec(command: String, args: [String]?, timeout: Int?) async throws -> ExecResponse

    // Elements (a11y overlay + JSON, no screenshot)
    func getElements() async throws -> Data
    func showWaitIndicator() async throws
    func hideWaitIndicator() async throws
    func getFrontmostApp() async throws -> String?
}
