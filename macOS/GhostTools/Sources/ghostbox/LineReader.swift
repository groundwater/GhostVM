import Foundation

/// Errors from the line-based NDJSON reader.
enum LineReaderError: Error {
    case lineTooLong(max: Int)
    case ioError(errno: Int32, op: String)
}

/// Reads newline-delimited lines from a blocking file descriptor.
/// Enforces a maximum line length to bound memory in a guest.
final class LineReader {
    private let fd: Int32
    private let maxLineBytes: Int
    private var buffer: [UInt8] = []

    init(fd: Int32, maxLineBytes: Int = 1_048_576) {
        self.fd = fd
        self.maxLineBytes = maxLineBytes
        self.buffer.reserveCapacity(4096)
    }

    var hasBufferedLine: Bool {
        buffer.contains(0x0A)
    }

    /// Read the next complete line (without the trailing `\n`).
    /// Returns `nil` on clean EOF before any data.
    /// Throws on line-too-long or read errors.
    func readLine() throws -> Data? {
        while true {
            if let nlIdx = buffer.firstIndex(of: 0x0A) {
                guard nlIdx <= maxLineBytes else {
                    throw LineReaderError.lineTooLong(max: maxLineBytes)
                }
                let line = Data(buffer[0..<nlIdx])
                buffer.removeFirst(nlIdx + 1)
                return line
            }

            if buffer.count > maxLineBytes {
                throw LineReaderError.lineTooLong(max: maxLineBytes)
            }

            let readSize = min(4096, maxLineBytes - buffer.count + 1)
            var chunk = [UInt8](repeating: 0, count: readSize)
            let n = Darwin.read(fd, &chunk, chunk.count)

            if n < 0 {
                let err = errno
                if err == EINTR { continue }
                throw LineReaderError.ioError(errno: err, op: "read")
            }

            if n == 0 {
                if buffer.isEmpty {
                    return nil
                }
                let remaining = Data(buffer)
                buffer.removeAll(keepingCapacity: true)
                return remaining
            }

            buffer.append(contentsOf: chunk[0..<n])
        }
    }
}
