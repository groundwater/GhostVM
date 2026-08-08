import Foundation

final class GhostboxAttachmentReadiness: @unchecked Sendable {
    private let lock = NSLock()
    private var ready = false
    private var closed = false
    private var waiters: [CheckedContinuation<Void, any Error>] = []

    func wait() async throws {
        try await withCheckedThrowingContinuation { continuation in
            let result = lock.withLock { () -> Bool? in
                if ready { return true }
                if closed { return false }
                waiters.append(continuation)
                return nil
            }
            if result == true {
                continuation.resume()
            } else if result == false {
                continuation.resume(throwing: DirectDispatchError(
                    .failedPrecondition,
                    "terminal proxy was closed before attachment"
                ))
            }
        }
    }

    func markReady() {
        let continuations = lock.withLock {
            guard !ready, !closed else { return [CheckedContinuation<Void, any Error>]() }
            ready = true
            let continuations = waiters
            waiters.removeAll()
            return continuations
        }
        continuations.forEach { $0.resume() }
    }

    func close() {
        let continuations = lock.withLock {
            guard !closed else { return [CheckedContinuation<Void, any Error>]() }
            closed = true
            let continuations = waiters
            waiters.removeAll()
            return continuations
        }
        for continuation in continuations {
            continuation.resume(throwing: DirectDispatchError(
                .failedPrecondition,
                "terminal proxy was closed before attachment"
            ))
        }
    }
}
