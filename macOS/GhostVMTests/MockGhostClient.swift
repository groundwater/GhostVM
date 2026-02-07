import Foundation
@testable import GhostVMKit

/// Test double for GhostClientProtocol that records calls and returns canned responses.
final class MockGhostClient: GhostClientProtocol {
    var clipboardContent: String?
    var clipboardType: String?
    var setClipboardCalls: [(content: String, type: String)] = []
    var sentFiles: [(url: URL, relativePath: String?)] = []
    var healthResult: Bool = true
    var shouldThrow: Error?
    var fileList: [String] = []
    var fetchedFileData: Data = Data()
    var fetchedFilename: String = "test.txt"
    var clearFileQueueCalled = false
    var getClipboardCallCount = 0
    var checkHealthCallCount = 0

    func getClipboard() async throws -> ClipboardGetResponse {
        getClipboardCallCount += 1
        if let error = shouldThrow { throw error }
        return ClipboardGetResponse(content: clipboardContent, type: clipboardType, changeCount: nil)
    }

    func setClipboard(content: String, type: String) async throws {
        if let error = shouldThrow { throw error }
        setClipboardCalls.append((content: content, type: type))
    }

    func sendFile(fileURL: URL, relativePath: String?, progressHandler: ((Double) -> Void)?) async throws -> String {
        if let error = shouldThrow { throw error }
        sentFiles.append((url: fileURL, relativePath: relativePath))
        progressHandler?(1.0)
        return "/guest/path/\(fileURL.lastPathComponent)"
    }

    func fetchFile(at path: String) async throws -> (data: Data, filename: String) {
        if let error = shouldThrow { throw error }
        return (fetchedFileData, fetchedFilename)
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
}
