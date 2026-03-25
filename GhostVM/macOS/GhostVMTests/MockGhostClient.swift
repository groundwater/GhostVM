import Foundation
@testable import GhostVMKit

/// Test double for GhostClientProtocol that records calls and returns canned responses.
final class MockGhostClient: GhostClientProtocol {
    var clipboardData: Data?
    var clipboardType: String?
    var setClipboardCalls: [(data: Data, type: String)] = []
    var sentFiles: [(url: URL, relativePath: String?, batchID: String?, isLastInBatch: Bool, permissions: Int?)] = []
    var healthResult: Bool = true
    var shouldThrow: Error?
    var fileList: [String] = []
    var fetchedFileData: Data = Data()
    var fetchedFilename: String = "test.txt"
    var fetchedPermissions: Int? = nil
    var clearFileQueueCalled = false
    var getClipboardCallCount = 0
    var checkHealthCallCount = 0

    func getClipboard() async throws -> ClipboardGetResponse {
        getClipboardCallCount += 1
        if let error = shouldThrow { throw error }
        return ClipboardGetResponse(data: clipboardData, type: clipboardType)
    }

    func setClipboard(data: Data, type: String) async throws {
        if let error = shouldThrow { throw error }
        setClipboardCalls.append((data: data, type: type))
    }

    func sendFile(fileURL: URL, relativePath: String?, batchID: String?, isLastInBatch: Bool, permissions: Int?, progressHandler: ((Double) -> Void)?) async throws -> String {
        if let error = shouldThrow { throw error }
        sentFiles.append((url: fileURL, relativePath: relativePath, batchID: batchID, isLastInBatch: isLastInBatch, permissions: permissions))
        progressHandler?(1.0)
        return "/guest/path/\(fileURL.lastPathComponent)"
    }

    func fetchFile(at path: String) async throws -> (data: Data, filename: String, permissions: Int?) {
        if let error = shouldThrow { throw error }
        return (fetchedFileData, fetchedFilename, fetchedPermissions)
    }

    func listFiles() async throws -> [String] {
        if let error = shouldThrow { throw error }
        return fileList
    }

    func clearFileQueue() async throws {
        if let error = shouldThrow { throw error }
        clearFileQueueCalled = true
    }

    func checkHealth() async -> Bool {
        checkHealthCallCount += 1
        return healthResult
    }

    // MARK: - App management stubs
    func listApps() async throws -> AppListResponse { throw MockError.notImplemented }
    func launchApp(bundleId: String) async throws {}
    func activateApp(bundleId: String) async throws {}
    func quitApp(bundleId: String) async throws {}

    // MARK: - File system stubs
    func listDirectory(path: String) async throws -> FSListResponse { throw MockError.notImplemented }
    func mkdir(path: String) async throws {}
    func deleteFile(path: String) async throws {}
    func moveFile(from: String, to: String) async throws {}

    // MARK: - Accessibility stubs
    func getAccessibilityTree(depth: Int, target: AXTarget) async throws -> AXTreeResponse { throw MockError.notImplemented }
    func getAccessibilityTrees(depth: Int, target: AXTarget) async throws -> [AXTreeResponse] { throw MockError.notImplemented }
    func performAccessibilityAction(label: String?, role: String?, action: String, target: AXTarget, wait: Bool) async throws {}
    func triggerMenuItem(path: [String], target: AXTarget, wait: Bool) async throws {}
    func setAccessibilityValue(_ value: String, label: String?, role: String?, target: AXTarget) async throws {}
    func getFocusedElement(target: AXTarget) async throws -> [String: Any] { [:] }

    // MARK: - Pointer & keyboard stubs
    func sendPointerEvent(action: String, x: Double?, y: Double?, button: String?, label: String?, endX: Double?, endY: Double?, deltaX: Double?, deltaY: Double?, wait: Bool) async throws -> Data? { nil }
    func sendKeyboardInput(text: String?, keys: [String]?, modifiers: [String]?, rate: Int?, wait: Bool) async throws {}

    // MARK: - Shell exec stub
    func exec(command: String, args: [String]?, timeout: Int?) async throws -> ExecResponse { throw MockError.notImplemented }

    // MARK: - Elements stubs
    func getElements() async throws -> Data { Data() }
    func showWaitIndicator() async throws {}
    func hideWaitIndicator() async throws {}
    func getFrontmostApp() async throws -> String? { nil }

    private enum MockError: Error { case notImplemented }
}
