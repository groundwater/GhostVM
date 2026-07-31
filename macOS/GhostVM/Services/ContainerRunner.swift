import Foundation
import GhostVMKit

/// Serializes a short-lived image fetch helper, then submits one run to the
/// helper-scoped container runtime XPC service and bridges its standard streams.
///
/// Reader/waiter threads use blocking Darwin IO on pipe fds (kqueue-safe regular
/// pipes); callbacks therefore arrive on private threads, never on vmQueue or main.
public final class ContainerRunner: @unchecked Sendable {
    public enum Stream: String, Sendable {
        case stdout
        case stderr
    }

    public enum RunnerError: Error, LocalizedError, Equatable {
        case executableNotFound(String)
        case launchFailed(String)
        case terminatedBeforeStart

        public var errorDescription: String? {
            switch self {
            case .executableNotFound(let path):
                return "Bundled container helper not found at \(path)."
            case .launchFailed(let detail):
                return "Failed to launch container helper: \(detail)"
            case .terminatedBeforeStart:
                return "Container run was terminated before the process started."
            }
        }
    }

    private static let fetchQueue = DispatchQueue(label: "org.ghostvm.container.image-fetch", qos: .userInitiated)

    /// Bundled helpers. Fixed by policy; never taken from a guest request.
    public static var runtimeExecutablePath: String {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/XPCServices/ghostvm-container-runtime.xpc/Contents/MacOS/ghostvm-container-runtime")
            .path
    }

    public static var imageFetchExecutablePath: String {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/ghostvm-image-fetch")
            .path
    }

    public static var executablePath: String { runtimeExecutablePath }

    public static var runtimeRootURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GhostVM/container-runtime", isDirectory: true)
    }

    public static var kernelURL: URL {
        runtimeRootURL.appendingPathComponent("kernel/vmlinux")
    }

    private let image: String
    private let arguments: [String]
    private let rootURL: URL
    private let runtimeKernelURL: URL
    private let runtimeClient: ContainerRuntimeXPCClient
    private let sharedNetwork: SharedVmnetNetwork
    private let lock = NSLock()
    private let stdinQueue = DispatchQueue(label: "org.ghostvm.container.stdin", qos: .userInitiated)
    private var process: Process?
    private var runtimeRunIdentifier: String?
    private var networkLease: SharedVmnetEndpointLease?
    private var stdinWriteHandle: FileHandle?
    private var terminateRequested = false

    init(
        runtimeIdentifier: String,
        image: String,
        arguments: [String],
        runtimeClient: ContainerRuntimeXPCClient,
        sharedNetwork: SharedVmnetNetwork
    ) {
        self.image = image
        self.arguments = arguments
        self.rootURL = Self.runtimeRootURL.appendingPathComponent(runtimeIdentifier, isDirectory: true)
        self.runtimeKernelURL = rootURL.appendingPathComponent("kernel/vmlinux")
        self.runtimeClient = runtimeClient
        self.sharedNetwork = sharedNetwork
    }

    /// Whether both bundled container helpers are present and executable.
    public static var isExecutableAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: runtimeExecutablePath)
            && FileManager.default.isExecutableFile(atPath: imageFetchExecutablePath)
    }

    /// Launches the process and returns immediately.
    ///
    /// - Parameters:
    ///   - onOutput: Called from private reader threads, in pipe order, once per
    ///     read chunk until the pipe reaches EOF.
    ///   - onExit: Called exactly once, only after the process exited AND both
    ///     pipes were drained to EOF, so no output is lost to a termination race.
    ///     Exit codes of signal-killed processes are reported as 128+signal.
    public func start(
        onReady: @escaping () -> Void,
        onOutput: @escaping (Stream, Data) -> Void,
        onExit: @escaping (Int32) -> Void
    ) throws {
        guard FileManager.default.isExecutableFile(atPath: Self.imageFetchExecutablePath) else {
            throw RunnerError.executableNotFound(Self.imageFetchExecutablePath)
        }
        guard FileManager.default.isExecutableFile(atPath: Self.runtimeExecutablePath) else {
            throw RunnerError.executableNotFound(Self.runtimeExecutablePath)
        }

        // terminate() before start() is remembered: do not launch at all.
        lock.lock()
        let cancelledBeforeLaunch = terminateRequested
        lock.unlock()
        guard !cancelledBeforeLaunch else {
            throw RunnerError.terminatedBeforeStart
        }

        Self.fetchQueue.async { [self] in
            fetchThenRun(onReady: onReady, onOutput: onOutput, onExit: onExit)
        }
    }

    /// Writes one raw stdin chunk to the running container worker.
    @discardableResult
    public func writeStdin(_ data: Data) -> Bool {
        if data.isEmpty { return true }
        return stdinQueue.sync {
            lock.lock()
            let handle = stdinWriteHandle
            lock.unlock()
            guard let handle else { return false }
            let fd = handle.fileDescriptor
            return data.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return true }
                var offset = 0
                while offset < data.count {
                    let written = Darwin.write(fd, base.advanced(by: offset), data.count - offset)
                    if written > 0 {
                        offset += written
                        continue
                    }
                    if written < 0, errno == EINTR { continue }
                    return false
                }
                return true
            }
        }
    }

    /// Half-closes the worker's stdin socket, which Containerization forwards as EOF.
    public func closeStdin() {
        lock.lock()
        let handle = stdinWriteHandle
        stdinWriteHandle = nil
        lock.unlock()
        guard let handle else { return }
        // A socket half-close wakes a blocked writer without closing/reusing its
        // fd. The serialized close runs after that writer has returned.
        _ = Darwin.shutdown(handle.fileDescriptor, SHUT_WR)
        stdinQueue.async {
            try? handle.close()
        }
    }

    public func resize(columns: UInt16, rows: UInt16) {
        lock.lock()
        let runIdentifier = runtimeRunIdentifier
        lock.unlock()
        if let runIdentifier {
            runtimeClient.resize(runIdentifier: runIdentifier, columns: columns, rows: rows)
        }
    }

    private func fetchThenRun(
        onReady: @escaping () -> Void,
        onOutput: @escaping (Stream, Data) -> Void,
        onExit: @escaping (Int32) -> Void
    ) {
        lock.lock()
        let cancelled = terminateRequested
        lock.unlock()
        guard !cancelled else {
            onExit(143)
            return
        }

        let fetch = Process()
        fetch.executableURL = URL(fileURLWithPath: Self.imageFetchExecutablePath)
        fetch.arguments = [
            "fetch",
            "--root", rootURL.path,
            "--kernel", runtimeKernelURL.path,
            "--image", image,
        ]
        fetch.standardInput = FileHandle.nullDevice
        fetch.standardOutput = FileHandle.nullDevice
        let stderrPipe = Pipe()
        fetch.standardError = stderrPipe

        do {
            try fetch.run()
        } catch {
            onOutput(.stderr, Data("ghostvm-image-fetch: \(error.localizedDescription)\n".utf8))
            onExit(125)
            return
        }
        register(fetch)

        let drainGroup = DispatchGroup()
        drainGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            Self.readLoop(fd: stderrPipe.fileHandleForReading.fileDescriptor, stream: .stderr, keepingAlive: stderrPipe, onOutput: onOutput)
            drainGroup.leave()
        }
        fetch.waitUntilExit()
        drainGroup.wait()
        clearProcess(fetch)

        let fetchStatus = Self.exitStatus(fetch)
        guard fetchStatus == 0 else {
            onExit(fetchStatus)
            return
        }

        lock.lock()
        let shouldRun = !terminateRequested
        lock.unlock()
        guard shouldRun else {
            onExit(143)
            return
        }

        launchRuntime(onReady: onReady, onOutput: onOutput, onExit: onExit)
    }

    private func launchRuntime(
        onReady: @escaping () -> Void,
        onOutput: @escaping (Stream, Data) -> Void,
        onExit: @escaping (Int32) -> Void
    ) {
        var workerArguments = arguments
        workerArguments.insert(contentsOf: ["--root", rootURL.path, "--kernel", runtimeKernelURL.path], at: 1)
        let runIdentifier = UUID().uuidString
        let lease: SharedVmnetEndpointLease
        do {
            lease = try sharedNetwork.acquireEndpoint(identifier: runIdentifier)
        } catch {
            onOutput(.stderr, Data("ghostvm-container-runtime: \(error.localizedDescription)\n".utf8))
            onExit(125)
            return
        }
        var stdinSockets = [Int32](repeating: -1, count: 2)
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &stdinSockets) == 0 else {
            lease.close()
            onOutput(.stderr, Data("ghostvm-container-runtime: failed to create stdin socket (errno \(errno))\n".utf8))
            onExit(125)
            return
        }
        let parentStdin = FileHandle(fileDescriptor: stdinSockets[0], closeOnDealloc: true)
        let childStdin = FileHandle(fileDescriptor: stdinSockets[1], closeOnDealloc: true)
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        lock.lock()
        self.runtimeRunIdentifier = runIdentifier
        self.networkLease = lease
        self.stdinWriteHandle = parentStdin
        let terminateImmediately = terminateRequested
        lock.unlock()

        let drainGroup = DispatchGroup()
        drainGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            Self.readLoop(fd: stdoutPipe.fileHandleForReading.fileDescriptor, stream: .stdout, keepingAlive: stdoutPipe, onOutput: onOutput)
            drainGroup.leave()
        }
        drainGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            Self.readLoop(fd: stderrPipe.fileHandleForReading.fileDescriptor, stream: .stderr, keepingAlive: stderrPipe, onOutput: onOutput)
            drainGroup.leave()
        }

        do {
            try runtimeClient.startRun(
                runIdentifier: runIdentifier,
                arguments: workerArguments,
                network: lease,
                stdinFD: childStdin.fileDescriptor,
                stdoutFD: stdoutPipe.fileHandleForWriting.fileDescriptor,
                stderrFD: stderrPipe.fileHandleForWriting.fileDescriptor,
                onReady: {
                    onReady()
                },
                onExit: { status in
                    DispatchQueue.global(qos: .userInitiated).async {
                        // The service closes its output descriptors before the
                        // exit event; drain all buffered bytes before reporting.
                        drainGroup.wait()
                        self.closeStdin()
                        self.clearRuntime(runIdentifier: runIdentifier)
                        onExit(status)
                    }
                }
            )
            // XPC duplicates descriptors when they are inserted into the request.
            try? childStdin.close()
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()
            if terminateImmediately {
                runtimeClient.cancel(runIdentifier: runIdentifier)
            }
        } catch {
            try? childStdin.close()
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()
            onOutput(.stderr, Data("ghostvm-container-runtime: \(error.localizedDescription)\n".utf8))
            DispatchQueue.global(qos: .userInitiated).async {
                drainGroup.wait()
                self.closeStdin()
                self.clearRuntime(runIdentifier: runIdentifier)
                onExit(125)
            }
        }
    }

    /// Cancels image preparation or the active runtime-service run. Safe to call
    /// multiple times and remembered before start so a late run cannot survive.
    public func terminate() {
        lock.lock()
        terminateRequested = true
        let process = self.process
        let runtimeRunIdentifier = self.runtimeRunIdentifier
        lock.unlock()
        closeStdin()
        if let process, process.isRunning {
            Self.terminateWithEscalation(process)
        }
        if let runtimeRunIdentifier {
            runtimeClient.cancel(runIdentifier: runtimeRunIdentifier)
        }
    }

    private func register(_ process: Process) {
        lock.lock()
        self.process = process
        let terminateImmediately = terminateRequested
        lock.unlock()
        if terminateImmediately {
            Self.terminateWithEscalation(process)
        }
    }

    private func clearProcess(_ process: Process) {
        lock.lock()
        if self.process === process {
            self.process = nil
        }
        lock.unlock()
    }

    private func clearRuntime(runIdentifier: String) {
        lock.lock()
        guard runtimeRunIdentifier == runIdentifier else {
            lock.unlock()
            return
        }
        runtimeRunIdentifier = nil
        let lease = networkLease
        networkLease = nil
        lock.unlock()
        lease?.close()
    }

    private static func exitStatus(_ process: Process) -> Int32 {
        process.terminationReason == .uncaughtSignal
            ? 128 + process.terminationStatus
            : process.terminationStatus
    }

    private static func terminateWithEscalation(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 2) {
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
    }

    private static func readLoop(fd: Int32, stream: Stream, keepingAlive: Pipe, onOutput: (Stream, Data) -> Void) {
        var buffer = [UInt8](repeating: 0, count: 32 * 1024)
        while true {
            let n = Darwin.read(fd, &buffer, buffer.count)
            if n > 0 {
                onOutput(stream, Data(buffer[0..<n]))
                continue
            }
            if n < 0, errno == EINTR { continue }
            break // EOF or unreadable fd
        }
        _ = keepingAlive
    }
}
