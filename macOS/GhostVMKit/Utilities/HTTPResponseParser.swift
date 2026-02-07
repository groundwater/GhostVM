import Foundation

/// Parses raw HTTP response data into status code and body.
/// Extracted from GhostClient for testability.
public enum HTTPResponseParser {
    /// Parse HTTP response treating body as UTF-8 text
    public static func parse(_ data: Data) throws -> (statusCode: Int, body: Data?) {
        guard let responseString = String(data: data, encoding: .utf8) else {
            throw GhostClientError.decodingError
        }

        // Split headers and body
        let parts = responseString.components(separatedBy: "\r\n\r\n")
        guard parts.count >= 1 else {
            throw GhostClientError.decodingError
        }

        let headerSection = parts[0]
        let bodyString = parts.count > 1 ? parts[1] : nil

        // Parse status line
        let headerLines = headerSection.components(separatedBy: "\r\n")
        guard let statusLine = headerLines.first else {
            throw GhostClientError.decodingError
        }

        // Parse status code from "HTTP/1.1 200 OK"
        let statusParts = statusLine.components(separatedBy: " ")
        guard statusParts.count >= 2,
              let statusCode = Int(statusParts[1]) else {
            throw GhostClientError.decodingError
        }

        let body = bodyString?.data(using: .utf8)

        return (statusCode, body)
    }

    /// Parse HTTP response preserving binary body data
    public static func parseBinary(_ data: Data) throws -> (statusCode: Int, body: Data?) {
        // Find the header/body separator (CRLFCRLF)
        let separator = Data([0x0D, 0x0A, 0x0D, 0x0A]) // \r\n\r\n
        guard let separatorRange = data.range(of: separator) else {
            // No body, try parsing header only
            guard let responseString = String(data: data, encoding: .utf8) else {
                throw GhostClientError.decodingError
            }

            let headerLines = responseString.components(separatedBy: "\r\n")
            guard let statusLine = headerLines.first else {
                throw GhostClientError.decodingError
            }

            let statusParts = statusLine.components(separatedBy: " ")
            guard statusParts.count >= 2,
                  let statusCode = Int(statusParts[1]) else {
                throw GhostClientError.decodingError
            }

            return (statusCode, nil)
        }

        // Parse header section
        let headerData = data[..<separatorRange.lowerBound]
        guard let headerString = String(data: headerData, encoding: .utf8) else {
            throw GhostClientError.decodingError
        }

        let headerLines = headerString.components(separatedBy: "\r\n")
        guard let statusLine = headerLines.first else {
            throw GhostClientError.decodingError
        }

        let statusParts = statusLine.components(separatedBy: " ")
        guard statusParts.count >= 2,
              let statusCode = Int(statusParts[1]) else {
            throw GhostClientError.decodingError
        }

        // Extract binary body
        let bodyData = data[separatorRange.upperBound...]
        return (statusCode, bodyData.isEmpty ? nil : Data(bodyData))
    }
}
