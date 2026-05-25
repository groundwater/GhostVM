import Foundation
import Darwin

public enum HTTPMethod: String, Sendable {
    case GET, POST, PUT, DELETE, HEAD, OPTIONS, PATCH
}

public enum HTTPQueryParser {
    public static func parseQuery(_ path: String, key: String) -> String? {
        guard let queryStart = path.firstIndex(of: "?") else { return nil }
        let query = String(path[path.index(after: queryStart)...])
        for pair in query.components(separatedBy: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 && parts[0] == key {
                return parts[1].removingPercentEncoding ?? parts[1]
            }
        }
        return nil
    }
}

public enum HTTPStatus: Int, Sendable {
    case switchingProtocols = 101
    case ok = 200
    case created = 201
    case noContent = 204
    case badRequest = 400
    case unauthorized = 401
    case forbidden = 403
    case notFound = 404
    case methodNotAllowed = 405
    case requestTimeout = 408
    case payloadTooLarge = 413
    case headerTooLarge = 431
    case badGateway = 502
    case serviceUnavailable = 503
    case gatewayTimeout = 504
    case internalServerError = 500

    public var reasonPhrase: String {
        switch self {
        case .switchingProtocols: return "Switching Protocols"
        case .ok: return "OK"
        case .created: return "Created"
        case .noContent: return "No Content"
        case .badRequest: return "Bad Request"
        case .unauthorized: return "Unauthorized"
        case .forbidden: return "Forbidden"
        case .notFound: return "Not Found"
        case .methodNotAllowed: return "Method Not Allowed"
        case .requestTimeout: return "Request Timeout"
        case .payloadTooLarge: return "Payload Too Large"
        case .headerTooLarge: return "Request Header Fields Too Large"
        case .badGateway: return "Bad Gateway"
        case .serviceUnavailable: return "Service Unavailable"
        case .gatewayTimeout: return "Gateway Timeout"
        case .internalServerError: return "Internal Server Error"
        }
    }

    public static func from(code: Int) -> HTTPStatus {
        HTTPStatus(rawValue: code) ?? .internalServerError
    }
}

public struct HTTPHeaders: Sendable, ExpressibleByDictionaryLiteral {
    public struct Entry: Sendable, Equatable {
        public let name: String
        public let value: String

        public init(name: String, value: String) {
            self.name = name
            self.value = value
        }
    }

    private var entries: [Entry]
    private var lowercaseIndex: [String: Int]

    public init(_ entries: [Entry] = []) {
        self.entries = entries
        self.lowercaseIndex = [:]
        rebuildIndex()
    }

    public init(_ dictionary: [String: String]) {
        self.init(dictionary.map { Entry(name: $0.key, value: $0.value) })
    }

    public init(dictionaryLiteral elements: (String, String)...) {
        self.init(Dictionary(uniqueKeysWithValues: elements))
    }

    public subscript(name: String) -> String? {
        get {
            guard let index = lowercaseIndex[name.lowercased()] else { return nil }
            return entries[index].value
        }
        set {
            let key = name.lowercased()
            if let index = lowercaseIndex[key] {
                if let newValue {
                    entries[index] = Entry(name: entries[index].name, value: newValue)
                } else {
                    entries.remove(at: index)
                    rebuildIndex()
                }
            } else if let newValue {
                entries.append(Entry(name: name, value: newValue))
                lowercaseIndex[key] = entries.count - 1
            }
        }
    }

    public var all: [Entry] { entries }

    public var dictionary: [String: String] {
        var result: [String: String] = [:]
        for entry in entries {
            result[entry.name] = entry.value
        }
        return result
    }

    private mutating func rebuildIndex() {
        lowercaseIndex.removeAll(keepingCapacity: true)
        for (index, entry) in entries.enumerated() {
            lowercaseIndex[entry.name.lowercased()] = index
        }
    }
}

public struct HTTPRequestHead: Sendable {
    public let method: HTTPMethod
    public let path: String
    public let headers: HTTPHeaders

    public init(method: HTTPMethod, path: String, headers: HTTPHeaders = HTTPHeaders()) {
        self.method = method
        self.path = path
        self.headers = headers
    }

    public func header(_ name: String) -> String? {
        headers[name]
    }

    public var contentLength: Int? {
        header("content-length").flatMap(Int.init)
    }
}

public struct HTTPResponseHead: Sendable {
    public let status: HTTPStatus
    public let headers: HTTPHeaders

    public init(status: HTTPStatus, headers: HTTPHeaders = HTTPHeaders()) {
        self.status = status
        self.headers = headers
    }

    public func header(_ name: String) -> String? {
        headers[name]
    }

    public var contentLength: Int? {
        header("content-length").flatMap(Int.init)
    }
}

public enum HTTPBodyFraming: Sendable, Equatable {
    case knownLength(Int)
    case chunked
    case eof
}

public protocol HTTPBodyWriter {
    func write(_ data: Data) throws
    func write(_ buffer: UnsafeRawBufferPointer) throws
}

public enum HTTPResponseBody: Sendable {
    case empty
    case bytes(Data)
    case stream(contentLength: Int, producer: @Sendable (HTTPBodyWriter) throws -> Void)
}

public struct HTTPResponse: Sendable {
    public var status: HTTPStatus
    public var headers: HTTPHeaders
    public var body: HTTPResponseBody

    public init(status: HTTPStatus, headers: HTTPHeaders = HTTPHeaders(), body: HTTPResponseBody = .empty) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public init(status: HTTPStatus, headers: [String: String], body: HTTPResponseBody = .empty) {
        self.init(status: status, headers: HTTPHeaders(headers), body: body)
    }

    public static func json(_ data: Data, status: HTTPStatus = .ok) -> HTTPResponse {
        HTTPResponse(
            status: status,
            headers: HTTPHeaders(["Content-Type": "application/json"]),
            body: .bytes(data)
        )
    }

    public static func text(_ string: String, status: HTTPStatus = .ok) -> HTTPResponse {
        HTTPResponse(
            status: status,
            headers: HTTPHeaders(["Content-Type": "text/plain; charset=utf-8"]),
            body: .bytes(Data(string.utf8))
        )
    }

    public static func error(_ status: HTTPStatus, message: String) -> HTTPResponse {
        let payload = (try? JSONSerialization.data(withJSONObject: ["error": message]))
            ?? Data(#"{"error":"unknown"}"#.utf8)
        return .json(payload, status: status)
    }
}

public struct HTTPBufferedResponse: Sendable {
    public let head: HTTPResponseHead
    public let body: Data

    public init(head: HTTPResponseHead, body: Data) {
        self.head = head
        self.body = body
    }
}

public struct HTTPUpgradedConnection: Sendable {
    public let responseHead: HTTPResponseHead
    public let prelude: Data

    public init(responseHead: HTTPResponseHead, prelude: Data) {
        self.responseHead = responseHead
        self.prelude = prelude
    }
}

public enum HTTPError: Error, CustomStringConvertible, Sendable {
    case malformedRequestLine(String)
    case malformedStatusLine(String)
    case malformedHeader(String)
    case headerTooLarge(maxBytes: Int)
    case unsupportedMethod(String)
    case writeFailed(errno: Int32)
    case readFailed(errno: Int32)
    case unexpectedEOF(read: Int, expected: Int)
    case bodyTooLarge(contentLength: Int, max: Int)

    public var description: String {
        switch self {
        case .malformedRequestLine(let line):
            return "Malformed request line: \(line)"
        case .malformedStatusLine(let line):
            return "Malformed status line: \(line)"
        case .malformedHeader(let line):
            return "Malformed header: \(line)"
        case .headerTooLarge(let maxBytes):
            return "Header section exceeded the \(maxBytes) byte cap"
        case .unsupportedMethod(let method):
            return "Unsupported HTTP method: \(method)"
        case .writeFailed(let err):
            return "write() failed: errno \(err)"
        case .readFailed(let err):
            return "read() failed: errno \(err)"
        case .unexpectedEOF(let read, let expected):
            return "Unexpected EOF after \(read) of \(expected) bytes"
        case .bodyTooLarge(let contentLength, let max):
            return "Body of \(contentLength) bytes exceeds limit of \(max) bytes"
        }
    }
}

public final class HTTPBodyReader {
    public let framing: HTTPBodyFraming

    private let fd: Int32
    private var prelude: Data
    private var bytesDelivered = 0
    private var eofReached = false
    private var chunkRemaining = 0
    private var chunkedFinished = false

    public init(fd: Int32, framing: HTTPBodyFraming, prelude: Data) {
        self.fd = fd
        self.framing = framing
        self.prelude = prelude
    }

    public var contentLength: Int? {
        if case .knownLength(let count) = framing { return count }
        return nil
    }

    public func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        switch framing {
        case .knownLength(let total):
            let remaining = total - bytesDelivered
            if remaining == 0 { return 0 }
            let count = try readSocket(into: buffer, maxBytes: min(buffer.count, remaining), errorOnEOF: true)
            bytesDelivered += count
            return count

        case .eof:
            if eofReached { return 0 }
            let count = try readSocket(into: buffer, maxBytes: buffer.count, errorOnEOF: false)
            bytesDelivered += count
            return count

        case .chunked:
            return try readChunked(into: buffer)
        }
    }

    public func readAll(maxSize: Int = 16 * 1024 * 1024) throws -> Data {
        switch framing {
        case .knownLength(let total):
            if total == 0 { return Data() }
            guard total <= maxSize else {
                throw HTTPError.bodyTooLarge(contentLength: total, max: maxSize)
            }
            var out = Data(count: total)
            var written = 0
            try out.withUnsafeMutableBytes { rawPtr in
                while written < total {
                    let slice = UnsafeMutableRawBufferPointer(rebasing: rawPtr[written..<total])
                    let count = try read(into: slice)
                    if count == 0 { break }
                    written += count
                }
            }
            return out.prefix(written)

        case .eof, .chunked:
            var out = Data()
            var buf = [UInt8](repeating: 0, count: 64 * 1024)
            try buf.withUnsafeMutableBytes { rawPtr in
                while true {
                    if out.count > maxSize {
                        throw HTTPError.bodyTooLarge(contentLength: out.count, max: maxSize)
                    }
                    let count = try read(into: rawPtr)
                    if count == 0 { break }
                    out.append(rawPtr.baseAddress!.assumingMemoryBound(to: UInt8.self), count: count)
                }
            }
            return out
        }
    }

    public func discard() {
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buf.withUnsafeMutableBytes { ptr in
                (try? read(into: ptr)) ?? 0
            }
            if count == 0 { break }
        }
    }

    private func readChunked(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        while !chunkedFinished {
            if chunkRemaining > 0 {
                let count = try readSocket(into: buffer, maxBytes: min(buffer.count, chunkRemaining), errorOnEOF: true)
                chunkRemaining -= count
                bytesDelivered += count
                if chunkRemaining == 0 {
                    try expectCRLF()
                }
                return count
            }

            let sizeLine = try readLine(max: 1024)
            let core = sizeLine.split(separator: ";", maxSplits: 1).first ?? Substring(sizeLine)
            let hex = core.trimmingCharacters(in: .whitespaces)
            guard let size = Int(hex, radix: 16), size >= 0 else {
                throw HTTPError.malformedHeader("Invalid chunk size: \(hex)")
            }

            if size == 0 {
                while true {
                    let trailer = try readLine(max: 8192)
                    if trailer.isEmpty { break }
                }
                chunkedFinished = true
                return 0
            }

            chunkRemaining = size
        }

        return 0
    }

    private func readSocket(
        into buffer: UnsafeMutableRawBufferPointer,
        maxBytes: Int,
        errorOnEOF: Bool
    ) throws -> Int {
        if !prelude.isEmpty {
            let fromPrelude = min(maxBytes, prelude.count)
            prelude.withUnsafeBytes { src in
                buffer.copyMemory(from: UnsafeRawBufferPointer(rebasing: src[..<fromPrelude]))
            }
            prelude.removeFirst(fromPrelude)
            return fromPrelude
        }

        while true {
            let count = Darwin.read(fd, buffer.baseAddress, maxBytes)
            if count > 0 {
                return count
            }
            if count == 0 {
                if errorOnEOF {
                    throw HTTPError.unexpectedEOF(read: bytesDelivered, expected: contentLength ?? (bytesDelivered + 1))
                }
                eofReached = true
                return 0
            }
            if errno == EINTR {
                continue
            }
            throw HTTPError.readFailed(errno: errno)
        }
    }

    private func readByte() throws -> UInt8 {
        if !prelude.isEmpty {
            let byte = prelude.removeFirst()
            return byte
        }

        while true {
            var byte: UInt8 = 0
            let count = Darwin.read(fd, &byte, 1)
            if count == 1 { return byte }
            if count == 0 {
                throw HTTPError.unexpectedEOF(read: bytesDelivered, expected: bytesDelivered + 1)
            }
            if errno == EINTR { continue }
            throw HTTPError.readFailed(errno: errno)
        }
    }

    private func readLine(max: Int) throws -> String {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(64)
        var previous: UInt8 = 0
        while bytes.count < max {
            let byte = try readByte()
            if previous == 0x0D && byte == 0x0A {
                bytes.removeLast()
                return String(bytes: bytes, encoding: .utf8) ?? ""
            }
            bytes.append(byte)
            previous = byte
        }
        throw HTTPError.malformedHeader("Line exceeded \(max) bytes")
    }

    private func expectCRLF() throws {
        let cr = try readByte()
        let lf = try readByte()
        if cr != 0x0D || lf != 0x0A {
            throw HTTPError.malformedHeader("Expected CRLF")
        }
    }
}

public enum HTTPCodec {
    public static let defaultMaxHeaderBytes = 16 * 1024

    public static func requestFraming(for request: HTTPRequestHead) -> HTTPBodyFraming {
        if let transferEncoding = request.header("transfer-encoding")?.lowercased() {
            let values = transferEncoding
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            if values.contains("chunked") {
                return .chunked
            }
        }
        if let contentLength = request.contentLength {
            return .knownLength(contentLength)
        }
        return .eof
    }

    public static func responseFraming(for response: HTTPResponseHead) -> HTTPBodyFraming {
        if let transferEncoding = response.header("transfer-encoding")?.lowercased() {
            let values = transferEncoding
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            if values.contains("chunked") {
                return .chunked
            }
        }
        if let contentLength = response.contentLength {
            return .knownLength(contentLength)
        }
        return .eof
    }

    public static func readRequest(fd: Int32, maxHeaderBytes: Int = defaultMaxHeaderBytes) throws -> (HTTPRequestHead, prelude: Data) {
        let (headerText, prelude) = try readHeaderBlock(fd: fd, maxHeaderBytes: maxHeaderBytes)
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            throw HTTPError.malformedRequestLine("empty")
        }

        let parts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 3 else {
            throw HTTPError.malformedRequestLine(requestLine)
        }
        guard let method = HTTPMethod(rawValue: parts[0]) else {
            throw HTTPError.unsupportedMethod(parts[0])
        }

        let request = HTTPRequestHead(
            method: method,
            path: parts[1],
            headers: try parseHeaders(lines.dropFirst())
        )
        return (request, prelude)
    }

    public static func readResponseHead(fd: Int32, maxHeaderBytes: Int = defaultMaxHeaderBytes) throws -> (HTTPResponseHead, prelude: Data) {
        let (headerText, prelude) = try readHeaderBlock(fd: fd, maxHeaderBytes: maxHeaderBytes)
        let lines = headerText.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else {
            throw HTTPError.malformedStatusLine("empty")
        }

        let parts = statusLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2, let statusCode = Int(parts[1]) else {
            throw HTTPError.malformedStatusLine(statusLine)
        }

        let head = HTTPResponseHead(
            status: HTTPStatus.from(code: statusCode),
            headers: try parseHeaders(lines.dropFirst())
        )
        return (head, prelude)
    }

    public static func writeRequest(
        fd: Int32,
        method: String,
        path: String,
        headers: HTTPHeaders = HTTPHeaders(),
        body: Data? = nil
    ) throws {
        try writeAll(fd: fd, data: requestData(method: method, path: path, headers: headers, body: body))
    }

    public static func writeRaw(fd: Int32, _ string: String) throws {
        try writeAll(fd: fd, data: Data(string.utf8))
    }

    public static func writeResponse(_ response: HTTPResponse, fd: Int32) throws {
        try writeAll(fd: fd, data: responseHeaderData(status: response.status, headers: response.headers, body: response.body))

        switch response.body {
        case .empty:
            break
        case .bytes(let data):
            try writeAll(fd: fd, data: data)
        case .stream(let contentLength, let producer):
            let writer = CountingBodyWriter(fd: fd, expectedCount: contentLength)
            try producer(writer)
            try writer.finish()
        }
    }

    public static func writeResponseHead(
        fd: Int32,
        status: HTTPStatus,
        headers: HTTPHeaders = HTTPHeaders()
    ) throws {
        try writeAll(fd: fd, data: responseHeadData(status: status, headers: headers))
    }

    public static func requestData(
        method: String,
        path: String,
        headers: HTTPHeaders = HTTPHeaders(),
        body: Data? = nil
    ) -> Data {
        var workingHeaders = headers
        let connectionHeader = workingHeaders["Connection"]?.lowercased() ?? ""
        let isUpgradeRequest = connectionHeader.split(separator: ",").contains { $0.trimmingCharacters(in: .whitespaces) == "upgrade" }
        if let body {
            workingHeaders["Content-Length"] = "\(body.count)"
        } else if !isUpgradeRequest && workingHeaders["Content-Length"] == nil && workingHeaders["Transfer-Encoding"] == nil {
            workingHeaders["Content-Length"] = "0"
        }
        if workingHeaders["Host"] == nil {
            workingHeaders["Host"] = "localhost"
        }
        if workingHeaders["Connection"] == nil {
            workingHeaders["Connection"] = "close"
        }

        var block = "\(method) \(path) HTTP/1.1\r\n"
        for entry in workingHeaders.all {
            block += "\(entry.name): \(entry.value)\r\n"
        }
        block += "\r\n"

        var data = Data(block.utf8)
        if let body {
            data.append(body)
        }
        return data
    }

    public static func responseData(status: HTTPStatus, headers: HTTPHeaders = HTTPHeaders(), body: Data = Data()) -> Data {
        var data = responseHeaderData(status: status, headers: headers, bodyLength: body.count)
        data.append(body)
        return data
    }

    public static func responseHeadData(status: HTTPStatus, headers: HTTPHeaders = HTTPHeaders()) -> Data {
        var block = "HTTP/1.1 \(status.rawValue) \(status.reasonPhrase)\r\n"
        for entry in headers.all {
            block += "\(entry.name): \(entry.value)\r\n"
        }
        block += "\r\n"
        return Data(block.utf8)
    }

    @discardableResult
    public static func writeAll(fd: Int32, data: Data) throws -> Int {
        guard !data.isEmpty else { return 0 }
        try data.withUnsafeBytes { ptr in
            try writeAll(fd: fd, ptr: ptr.baseAddress!, count: data.count)
        }
        return data.count
    }

    public static func writeAll(fd: Int32, ptr: UnsafeRawPointer, count: Int) throws {
        var offset = 0
        while offset < count {
            let written = Darwin.write(fd, ptr + offset, count - offset)
            if written > 0 {
                offset += written
            } else if written < 0 {
                let writeErrno = errno
                if writeErrno == EINTR {
                    continue
                }
                throw HTTPError.writeFailed(errno: writeErrno)
            } else {
                throw HTTPError.writeFailed(errno: EPIPE)
            }
        }
    }

    private static func readHeaderBlock(fd: Int32, maxHeaderBytes: Int) throws -> (String, Data) {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        let separator = Data([0x0D, 0x0A, 0x0D, 0x0A])

        while true {
            if let range = buffer.range(of: separator) {
                let headerData = buffer[..<range.lowerBound]
                let prelude = Data(buffer[range.upperBound...])
                guard let headerText = String(data: headerData, encoding: .utf8) else {
                    throw HTTPError.malformedHeader("non-UTF8 header section")
                }
                return (headerText, prelude)
            }

            if buffer.count > maxHeaderBytes {
                throw HTTPError.headerTooLarge(maxBytes: maxHeaderBytes)
            }

            let count = Darwin.read(fd, &chunk, chunk.count)
            if count > 0 {
                buffer.append(contentsOf: chunk[0..<count])
            } else if count == 0 {
                throw HTTPError.unexpectedEOF(read: buffer.count, expected: buffer.count + 1)
            } else if errno == EINTR {
                continue
            } else {
                throw HTTPError.readFailed(errno: errno)
            }
        }
    }

    private static func parseHeaders<S: Sequence>(_ lines: S) throws -> HTTPHeaders where S.Element == String {
        var entries: [HTTPHeaders.Entry] = []
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else {
                throw HTTPError.malformedHeader(line)
            }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            entries.append(.init(name: name, value: value))
        }
        return HTTPHeaders(entries)
    }

    private static func responseHeaderData(status: HTTPStatus, headers: HTTPHeaders, body: HTTPResponseBody) -> Data {
        let bodyLength: Int
        switch body {
        case .empty:
            bodyLength = 0
        case .bytes(let data):
            bodyLength = data.count
        case .stream(let length, _):
            bodyLength = length
        }
        return responseHeaderData(status: status, headers: headers, bodyLength: bodyLength)
    }

    private static func responseHeaderData(status: HTTPStatus, headers: HTTPHeaders, bodyLength: Int) -> Data {
        var workingHeaders = headers
        if status != .switchingProtocols && status != .noContent {
            workingHeaders["Content-Length"] = "\(bodyLength)"
        }
        if workingHeaders["Connection"] == nil {
            workingHeaders["Connection"] = "close"
        }

        var block = "HTTP/1.1 \(status.rawValue) \(status.reasonPhrase)\r\n"
        for entry in workingHeaders.all {
            block += "\(entry.name): \(entry.value)\r\n"
        }
        block += "\r\n"
        return Data(block.utf8)
    }
}

public enum HTTPClient {
    public static func performRequest(
        fd: Int32,
        method: String,
        path: String,
        headers: HTTPHeaders = HTTPHeaders(),
        body: Data? = nil,
        shutdownWrite: Bool = true
    ) throws -> HTTPBufferedResponse {
        try HTTPCodec.writeRequest(fd: fd, method: method, path: path, headers: headers, body: body)
        if shutdownWrite {
            _ = Darwin.shutdown(fd, SHUT_WR)
        }
        return try readBufferedResponse(fd: fd)
    }

    public static func sendRequestHead(
        fd: Int32,
        method: String,
        path: String,
        headers: HTTPHeaders = HTTPHeaders()
    ) throws {
        try HTTPCodec.writeRequest(fd: fd, method: method, path: path, headers: headers, body: nil)
    }

    public static func readBufferedResponse(fd: Int32, maxBodySize: Int = 64 * 1024 * 1024) throws -> HTTPBufferedResponse {
        let (head, prelude) = try HTTPCodec.readResponseHead(fd: fd)
        let reader = HTTPBodyReader(fd: fd, framing: HTTPCodec.responseFraming(for: head), prelude: prelude)
        let body = try reader.readAll(maxSize: maxBodySize)
        return HTTPBufferedResponse(head: head, body: body)
    }

    public static func readResponseHead(fd: Int32) throws -> (HTTPResponseHead, HTTPBodyReader) {
        let (head, prelude) = try HTTPCodec.readResponseHead(fd: fd)
        return (head, HTTPBodyReader(fd: fd, framing: HTTPCodec.responseFraming(for: head), prelude: prelude))
    }

    public static func performUpgradeRequest(
        fd: Int32,
        method: String = "GET",
        path: String,
        headers: HTTPHeaders,
        expectedStatus: HTTPStatus = .switchingProtocols
    ) throws -> HTTPUpgradedConnection {
        try HTTPCodec.writeRequest(fd: fd, method: method, path: path, headers: headers, body: nil)
        let (responseHead, prelude) = try HTTPCodec.readResponseHead(fd: fd)
        guard responseHead.status == expectedStatus else {
            throw HTTPError.malformedStatusLine(
                "Expected \(expectedStatus.rawValue), got \(responseHead.status.rawValue)"
            )
        }
        return HTTPUpgradedConnection(responseHead: responseHead, prelude: prelude)
    }
}

private struct SocketBodyWriter: HTTPBodyWriter {
    let fd: Int32

    func write(_ data: Data) throws {
        try HTTPCodec.writeAll(fd: fd, data: data)
    }

    func write(_ buffer: UnsafeRawBufferPointer) throws {
        guard let base = buffer.baseAddress else { return }
        try HTTPCodec.writeAll(fd: fd, ptr: base, count: buffer.count)
    }
}

private final class CountingBodyWriter: HTTPBodyWriter, @unchecked Sendable {
    private let socketWriter: SocketBodyWriter
    private let expectedCount: Int
    private var bytesWritten = 0

    init(fd: Int32, expectedCount: Int) {
        socketWriter = SocketBodyWriter(fd: fd)
        self.expectedCount = expectedCount
    }

    func write(_ data: Data) throws {
        bytesWritten += data.count
        guard bytesWritten <= expectedCount else {
            throw HTTPError.unexpectedEOF(read: bytesWritten, expected: expectedCount)
        }
        try socketWriter.write(data)
    }

    func write(_ buffer: UnsafeRawBufferPointer) throws {
        bytesWritten += buffer.count
        guard bytesWritten <= expectedCount else {
            throw HTTPError.unexpectedEOF(read: bytesWritten, expected: expectedCount)
        }
        try socketWriter.write(buffer)
    }

    func finish() throws {
        guard bytesWritten == expectedCount else {
            throw HTTPError.unexpectedEOF(read: bytesWritten, expected: expectedCount)
        }
    }
}
