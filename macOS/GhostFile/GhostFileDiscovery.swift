import Foundation

struct DiscoveredGhostFileShare: Identifiable, Equatable {
    let id: UUID
    let name: String
    let host: String
    let port: Int
    let readOnly: Bool
    let transport: String
    let publicKeyPin: String

    var url: URL? {
        var components = URLComponents()
        components.scheme = GhostFileProtocol.urlScheme
        components.host = host
        components.port = port
        components.path = GhostFileProtocol.shareBasePath(id: id)
        components.queryItems = [URLQueryItem(name: "tls_pin", value: publicKeyPin)]
        return components.url
    }
}

@MainActor
final class GhostFileDiscovery: NSObject, ObservableObject {
    @Published private(set) var shares: [DiscoveredGhostFileShare] = []
    @Published private(set) var isSearching = false

    private let browser = NetServiceBrowser()
    private var services: [ObjectIdentifier: NetService] = [:]
    private var shareIDsByService: [ObjectIdentifier: UUID] = [:]

    override init() {
        super.init()
        browser.delegate = self
        browser.includesPeerToPeer = true
    }

    func start() {
        guard !isSearching else { return }
        isSearching = true
        browser.searchForServices(
            ofType: GhostFileProtocol.bonjourType,
            inDomain: GhostFileProtocol.bonjourDomain
        )
    }

    func stop() {
        browser.stop()
        for service in services.values {
            service.stop()
        }
        services.removeAll()
        shareIDsByService.removeAll()
        shares.removeAll()
        isSearching = false
    }

    private func resolved(_ service: NetService) {
        guard let hostName = service.hostName,
              let txtData = service.txtRecordData() else { return }
        let txt = NetService.dictionary(fromTXTRecord: txtData)
        guard let idData = txt["id"],
              let idString = String(data: idData, encoding: .utf8),
              let id = UUID(uuidString: idString) else { return }

        let mode = txt["mode"].flatMap { String(data: $0, encoding: .utf8) } ?? "ro"
        let transport = txt["transport"].flatMap { String(data: $0, encoding: .utf8) } ?? GhostFileProtocol.transport
        let alpn = txt["alpn"].flatMap { String(data: $0, encoding: .utf8) } ?? GhostFileProtocol.alpn
        guard transport == GhostFileProtocol.transport, alpn == GhostFileProtocol.alpn else { return }
        guard let pinData = txt["tls-pin"],
              let publicKeyPin = String(data: pinData, encoding: .utf8),
              !publicKeyPin.isEmpty else { return }
        let host = hostName.hasSuffix(".") ? String(hostName.dropLast()) : hostName
        let discovered = DiscoveredGhostFileShare(
            id: id,
            name: service.name,
            host: host,
            port: service.port,
            readOnly: mode == "ro",
            transport: transport,
            publicKeyPin: publicKeyPin
        )
        shareIDsByService[ObjectIdentifier(service)] = id
        shares.removeAll { $0.id == id }
        shares.append(discovered)
        shares.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

extension GhostFileDiscovery: NetServiceBrowserDelegate, NetServiceDelegate {
    nonisolated func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didFind service: NetService,
        moreComing: Bool
    ) {
        Task { @MainActor in
            let key = ObjectIdentifier(service)
            services[key] = service
            service.delegate = self
            service.includesPeerToPeer = true
            service.resolve(withTimeout: 5)
        }
    }

    nonisolated func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didRemove service: NetService,
        moreComing: Bool
    ) {
        Task { @MainActor in
            let key = ObjectIdentifier(service)
            services.removeValue(forKey: key)
            if let shareID = shareIDsByService.removeValue(forKey: key) {
                shares.removeAll { $0.id == shareID }
            }
        }
    }

    nonisolated func netServiceDidResolveAddress(_ sender: NetService) {
        Task { @MainActor in resolved(sender) }
    }

    nonisolated func netServiceBrowserDidStopSearch(_ browser: NetServiceBrowser) {
        Task { @MainActor in isSearching = false }
    }

    nonisolated func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didNotSearch errorDict: [String: NSNumber]
    ) {
        Task { @MainActor in isSearching = false }
    }
}
