import Foundation
import Virtualization

enum AsyncVsockConnectorError: Error, LocalizedError {
    case noSocketDevice
    case timeout(seconds: UInt64)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .noSocketDevice:
            return "No virtio socket device is configured on the VM"
        case .timeout(let seconds):
            return "Timed out connecting to guest vsock after \(seconds)s"
        case .cancelled:
            return "Vsock connect operation was cancelled"
        }
    }
}

private final class ConnectContinuationBox {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<VZVirtioSocketConnection, Error>?
    private var isDone = false

    init(_ continuation: CheckedContinuation<VZVirtioSocketConnection, Error>) {
        self.continuation = continuation
    }

    func resume(with result: Result<VZVirtioSocketConnection, Error>) {
        lock.lock()
        guard !isDone else {
            lock.unlock()
            return
        }
        isDone = true
        let cont = continuation
        continuation = nil
        lock.unlock()

        cont?.resume(with: result)
    }
}

private final class ConnectContinuationHolder {
    private let lock = NSLock()
    private var box: ConnectContinuationBox?

    func set(_ box: ConnectContinuationBox?) {
        lock.lock()
        self.box = box
        lock.unlock()
    }

    func cancelCurrent() {
        lock.lock()
        let current = box
        lock.unlock()
        current?.resume(with: .failure(AsyncVsockConnectorError.cancelled))
    }
}

public final class AsyncVsockConnector {
    private let connectOperation: (@escaping (Result<VZVirtioSocketConnection, Error>) -> Void) -> Void
    private let timeoutNanoseconds: UInt64

    public init(vm: VZVirtualMachine, vmQueue: DispatchQueue, port: UInt32, timeoutSeconds: UInt64 = 5) {
        self.timeoutNanoseconds = timeoutSeconds * 1_000_000_000
        self.connectOperation = { completion in
            vmQueue.async {
                guard let socketDevice = vm.socketDevices.first as? VZVirtioSocketDevice else {
                    completion(.failure(AsyncVsockConnectorError.noSocketDevice))
                    return
                }

                socketDevice.connect(toPort: port) { result in
                    completion(result)
                }
            }
        }
    }

    public init(
        timeoutNanoseconds: UInt64 = 5_000_000_000,
        connectOperation: @escaping (@escaping (Result<VZVirtioSocketConnection, Error>) -> Void) -> Void
    ) {
        self.timeoutNanoseconds = timeoutNanoseconds
        self.connectOperation = connectOperation
    }

    public func connect() async throws -> VZVirtioSocketConnection {
        if Task.isCancelled {
            throw AsyncVsockConnectorError.cancelled
        }

        let timeoutSeconds = timeoutNanoseconds / 1_000_000_000
        let holder = ConnectContinuationHolder()

        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<VZVirtioSocketConnection, Error>) in
                let box = ConnectContinuationBox(continuation)
                holder.set(box)
                let timeoutTask = Task {
                    try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                    box.resume(with: .failure(AsyncVsockConnectorError.timeout(seconds: timeoutSeconds)))
                }

                connectOperation { result in
                    timeoutTask.cancel()
                    box.resume(with: result)
                }
            }
        }, onCancel: {
            holder.cancelCurrent()
        })
    }
}
