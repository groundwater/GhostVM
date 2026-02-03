import Foundation
import Hummingbird
import NIOCore
import NIOPosix

/// HTTP/2 server for GhostTools guest-host communication
/// Listens on vsock port 80 for connections from the host
actor GhostServer {
    private let app: Application<RouterResponder<BasicRequestContext>>
    private let port: Int

    /// Creates a new GhostServer
    /// - Parameter port: The port to listen on (default: 80 for vsock)
    init(port: Int = 80) async throws {
        self.port = port

        // Configure router with routes
        let router = Router()

        // Add authentication middleware (skips /health)
        router.middlewares.add(TokenAuthMiddleware())

        // Configure routes
        configureRoutes(router)

        // Build the application
        // Note: For vsock, we'll need custom channel setup. For now, use TCP for development.
        self.app = Application(
            router: router,
            configuration: .init(
                address: .hostname("127.0.0.1", port: port)
            )
        )
    }

    /// Runs the HTTP/2 server
    func run() async throws {
        print("GhostTools server starting on port \(port)...")
        try await app.run()
    }
}
