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

struct GhostFileShareRemoval: Equatable {
    let eventID = UUID()
    let shareID: UUID
}

struct GhostFileBonjourLease {
    // NetService does not expose the TTL of the PTR/SRV records. GhostFile
    // therefore publishes a short application-level lease in its TXT record
    // and changes the heartbeat value often enough to refresh that lease.
    static let advertisedTTL: TimeInterval = 6
    static let legacyTTL: TimeInterval = 15
    static let heartbeatInterval = Duration.seconds(2)
    static let sweepInterval = Duration.seconds(1)

    static func ttl(from txt: [String: Data]) -> TimeInterval {
        guard let data = txt["ttl"],
              let string = String(data: data, encoding: .utf8),
              let seconds = TimeInterval(string),
              seconds.isFinite else {
            return legacyTTL
        }
        return min(max(seconds, 4), 60)
    }

    static func isExpired(lastSeen: Date, ttl: TimeInterval, now: Date = Date()) -> Bool {
        now.timeIntervalSince(lastSeen) >= ttl
    }
}

@MainActor
final class GhostFileDiscovery: NSObject, ObservableObject {
    @Published private(set) var shares: [DiscoveredGhostFileShare] = []
    @Published private(set) var isSearching = false
    @Published private(set) var removalEvent: GhostFileShareRemoval?

    private let browser = NetServiceBrowser()
    private var services: [ObjectIdentifier: NetService] = [:]
    private var shareIDsByService: [ObjectIdentifier: UUID] = [:]
    private var stoppingServices: Set<ObjectIdentifier> = []
    private var lastSeenByService: [ObjectIdentifier: Date] = [:]
    private var ttlByService: [ObjectIdentifier: TimeInterval] = [:]
    private var expiryTask: Task<Void, Never>?

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
        expiryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: GhostFileBonjourLease.sweepInterval)
                guard !Task.isCancelled else { return }
                guard let self else { return }
                self.expireStaleServices()
            }
        }
    }

    func stop() {
        expiryTask?.cancel()
        expiryTask = nil
        browser.stop()
        for service in services.values {
            service.stopMonitoring()
            service.stop()
        }
        services.removeAll()
        shareIDsByService.removeAll()
        stoppingServices.removeAll()
        lastSeenByService.removeAll()
        ttlByService.removeAll()
        shares.removeAll()
        isSearching = false
    }

    private func resolved(_ service: NetService, txtData suppliedTXTData: Data? = nil) {
        guard let hostName = service.hostName,
              let txtData = suppliedTXTData ?? service.txtRecordData() else { return }
        let txt = NetService.dictionary(fromTXTRecord: txtData)
        guard let idData = txt["id"],
              let idString = String(data: idData, encoding: .utf8),
              let id = UUID(uuidString: idString) else { return }

        let key = ObjectIdentifier(service)
        let state = txt["state"].flatMap { String(data: $0, encoding: .utf8) } ?? "ready"
        if state == "stopping" {
            if stoppingServices.insert(key).inserted {
                shareIDsByService[key] = id
                removeShare(forService: key)
            }
            return
        }
        stoppingServices.remove(key)
        shareIDsByService[key] = id

        let mode = txt["mode"].flatMap { String(data: $0, encoding: .utf8) } ?? "ro"
        let transport = txt["transport"].flatMap { String(data: $0, encoding: .utf8) } ?? GhostFileProtocol.transport
        let alpn = txt["alpn"].flatMap { String(data: $0, encoding: .utf8) } ?? GhostFileProtocol.alpn
        guard transport == GhostFileProtocol.transport, alpn == GhostFileProtocol.alpn else { return }
        guard let pinData = txt["tls-pin"],
              let publicKeyPin = String(data: pinData, encoding: .utf8),
              !publicKeyPin.isEmpty else { return }
        lastSeenByService[key] = Date()
        ttlByService[key] = GhostFileBonjourLease.ttl(from: txt)
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
        shares.removeAll { $0.id == id }
        shares.append(discovered)
        shares.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func removeShare(forService key: ObjectIdentifier) {
        guard let shareID = shareIDsByService.removeValue(forKey: key) else { return }
        lastSeenByService.removeValue(forKey: key)
        ttlByService.removeValue(forKey: key)
        guard !shareIDsByService.values.contains(shareID) else { return }
        shares.removeAll { $0.id == shareID }
        removalEvent = GhostFileShareRemoval(shareID: shareID)
    }

    private func expireStaleServices(now: Date = Date()) {
        let expired = lastSeenByService.compactMap { key, lastSeen -> ObjectIdentifier? in
            let ttl = ttlByService[key] ?? GhostFileBonjourLease.legacyTTL
            return GhostFileBonjourLease.isExpired(lastSeen: lastSeen, ttl: ttl, now: now) ? key : nil
        }
        for key in expired {
            removeShare(forService: key)
        }
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
            service.stopMonitoring()
            services.removeValue(forKey: key)
            stoppingServices.remove(key)
            lastSeenByService.removeValue(forKey: key)
            ttlByService.removeValue(forKey: key)
            removeShare(forService: key)
        }
    }

    nonisolated func netServiceDidResolveAddress(_ sender: NetService) {
        Task { @MainActor in
            resolved(sender)
            sender.startMonitoring()
        }
    }

    nonisolated func netService(_ sender: NetService, didUpdateTXTRecord data: Data) {
        Task { @MainActor in resolved(sender, txtData: data) }
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
