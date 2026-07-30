import Foundation

/// Runs the Apple `container` CLI as a child process (no shell) and streams its
/// stdout/stderr to callbacks until the process exits and both pipes are drained.
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
                return "Apple container CLI not found at \(path). Install the container tool (https://github.com/apple/container) on this Mac, then retry."
            case .launchFailed(let detail):
                return "Failed to launch container CLI: \(detail)"
            case .terminatedBeforeStart:
                return "Container run was terminated before the process started."
            }
        }
    }

    /// Host executable. Fixed by policy; never taken from a guest request.
    public static let executablePath = "/usr/local/bin/container"

    private let arguments: [String]
    private let lock = NSLock()
    private var process: Process?
    private var terminateRequested = false

    public init(arguments: [String]) {
        self.arguments = arguments
    }

    /// Whether the container CLI is present and executable on this host.
    public static var isExecutableAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: executablePath)
    }

    /// Launches the process and returns immediately.
    ///
    /// - Parameters:
    ///   - onOutput: Called from private reader threads, in pipe order, once per
    ///     read chunk until the pipe reaches EOF.
    ///   - onExit: Called exactly once, only after the process exited AND both
    ///     pipes were drained to EOF, so no output is lost to a termination race.
    ///     Exit codes of signal-killed processes are reported as 128+signal.
    public func start(onOutput: @escaping (Stream, Data) -> Void, onExit: @escaping (Int32) -> Void) throws {
        guard Self.isExecutableAvailable else {
            throw RunnerError.executableNotFound(Self.executablePath)
        }

        // terminate() before start() is remembered: do not launch at all.
        lock.lock()
        let cancelledBeforeLaunch = terminateRequested
        lock.unlock()
        guard !cancelledBeforeLaunch else {
            throw RunnerError.terminatedBeforeStart
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.executablePath)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw RunnerError.launchFailed(error.localizedDescription)
        }

        lock.lock()
        self.process = process
        let terminateImmediately = terminateRequested
        lock.unlock()
        // terminate() raced with run(): kill the just-started process so a
        // container is never left running after a stop request.
        if terminateImmediately {
            Self.terminateWithEscalation(process)
        }

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

        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            // Wait for both pipes to drain so the exit status is reported only
            // after all buffered output has been forwarded.
            drainGroup.wait()
            let code: Int32
            if process.terminationReason == .uncaughtSignal {
                code = 128 + process.terminationStatus
            } else {
                code = process.terminationStatus
            }
            onExit(code)
        }
    }

    /// Asks the child to exit (SIGTERM, escalating to SIGKILL after ~2s if the
    /// process is still running). Safe to call multiple times and remembered
    /// when called before start(), so a late start() never leaves a container
    /// running after a stop request.
    public func terminate() {
        lock.lock()
        terminateRequested = true
        let process = self.process
        lock.unlock()
        if let process, process.isRunning {
            Self.terminateWithEscalation(process)
        }
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
