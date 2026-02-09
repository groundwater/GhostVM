import Foundation

/// Protocol for communicating with GhostTools running in the guest VM.
/// Enables mock injection for testing services that depend on guest communication.
public protocol GhostClientProtocol {
    func getClipboard() async throws -> ClipboardGetResponse
    func setClipboard(content: String, type: String) async throws
    func sendFile(fileURL: URL, relativePath: String?, batchID: String?, isLastInBatch: Bool, permissions: Int?, progressHandler: ((Double) -> Void)?) async throws -> String
    func fetchFile(at path: String) async throws -> (data: Data, filename: String, permissions: Int?)
    func listFiles() async throws -> [String]
    func clearFileQueue() async throws
    func checkHealth() async -> Bool
}
