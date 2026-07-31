import GhostHTTP3

guard ghost_http3_backend_is_ready() else {
    fatalError("GhostHTTP3 backend is not ready")
}

let backend = String(cString: ghost_http3_backend_version())
print("Swift linked GhostHTTP3 API \(ghost_http3_api_version()), quiche \(backend)")
