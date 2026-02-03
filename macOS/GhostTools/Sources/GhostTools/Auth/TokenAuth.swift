import Foundation
import Hummingbird

/// Path where the authentication token is stored on the GhostVM shared volume
private let tokenPath = "/Volumes/GhostVM/.ghost-token"

/// Token-based authentication for GhostTools HTTP/2 server
/// Validates Bearer tokens against the token stored in the GhostVM volume
actor TokenAuth {
    static let shared = TokenAuth()

    private var cachedToken: String?
    private var lastTokenCheck: Date?
    private let tokenCheckInterval: TimeInterval = 60 // Re-check token file every 60 seconds

    private init() {}

    /// Validates a bearer token from an Authorization header
    /// - Parameter authHeader: The full Authorization header value (e.g., "Bearer abc123")
    /// - Returns: true if the token is valid
    func validateToken(_ authHeader: String?) async -> Bool {
        guard let authHeader = authHeader else {
            return false
        }

        // Parse Bearer token
        let prefix = "Bearer "
        guard authHeader.hasPrefix(prefix) else {
            return false
        }

        let token = String(authHeader.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        guard !token.isEmpty else {
            return false
        }

        // Get expected token
        guard let expectedToken = await getExpectedToken() else {
            // If we can't read the token file, deny access
            return false
        }

        // Constant-time comparison to prevent timing attacks
        return constantTimeCompare(token, expectedToken)
    }

    /// Reads the expected token from disk, with caching
    private func getExpectedToken() async -> String? {
        // Check if we have a recent cached token
        if let cached = cachedToken,
           let lastCheck = lastTokenCheck,
           Date().timeIntervalSince(lastCheck) < tokenCheckInterval {
            return cached
        }

        // Read token from file
        do {
            let token = try String(contentsOfFile: tokenPath, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if !token.isEmpty {
                cachedToken = token
                lastTokenCheck = Date()
                return token
            }
        } catch {
            print("Failed to read auth token from \(tokenPath): \(error)")
        }

        return nil
    }

    /// Performs constant-time string comparison to prevent timing attacks
    private func constantTimeCompare(_ a: String, _ b: String) -> Bool {
        let aBytes = Array(a.utf8)
        let bBytes = Array(b.utf8)

        guard aBytes.count == bBytes.count else {
            return false
        }

        var result: UInt8 = 0
        for (aByte, bByte) in zip(aBytes, bBytes) {
            result |= aByte ^ bByte
        }

        return result == 0
    }

    /// Clears the cached token, forcing a re-read on next validation
    func clearCache() {
        cachedToken = nil
        lastTokenCheck = nil
    }
}

/// Middleware that validates Bearer token authentication on all requests
struct TokenAuthMiddleware<Context: RequestContext>: RouterMiddleware {
    func handle(
        _ request: Request,
        context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        // Skip auth for health check endpoint
        if request.uri.path == "/health" {
            return try await next(request, context)
        }

        let authHeader = request.headers[.authorization]
        let isValid = await TokenAuth.shared.validateToken(authHeader)

        guard isValid else {
            return Response(
                status: .unauthorized,
                headers: [.wwwAuthenticate: "Bearer"],
                body: .init(byteBuffer: .init(string: #"{"error":"Unauthorized"}"#))
            )
        }

        return try await next(request, context)
    }
}
