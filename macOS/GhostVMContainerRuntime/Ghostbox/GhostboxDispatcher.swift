import GhostVMKit

struct GhostboxDispatcher: Sendable {
    private let handlers: [String: any GhostboxDomainHandler]

    init(_ handlers: [any GhostboxDomainHandler]) {
        self.handlers = Dictionary(uniqueKeysWithValues: handlers.map { ($0.resource, $0) })
    }

    func dispatch(
        method: GhostboxDirectMethod,
        parameters: [String: GhostboxJSONValue],
        session: GhostboxSession
    ) async throws -> GhostboxDirectValue {
        let components = method.rawValue.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard components.count == 2, !components[0].isEmpty, !components[1].isEmpty else {
            throw DirectDispatchError(.invalidArgument, "invalid direct method '\(method.rawValue)'")
        }
        let resource = String(components[0])
        guard let handler = handlers[resource] else {
            throw DirectDispatchError(.unsupported, "unsupported direct resource '\(resource)'")
        }
        return try await handler.handle(method: method, parameters: parameters, session: session)
    }

    static let standard = GhostboxDispatcher(
        [
            GhostboxDNSCommands(),
            GhostboxContentStoreCommands(),
            GhostboxAuthenticationCommands(),
            GhostboxProgressHandlerCommands(),
            GhostboxImageStoreCommands(),
            GhostboxImageDescriptionCommands(),
            GhostboxImageCommands(),
            GhostboxVolumeCommands(),
            GhostboxContainerMemorySizeCommands(),
            GhostboxContainerResourceLabelsCommands(),
            GhostboxContainerParserCommands(),
            GhostboxNetworkCommands(),
            GhostboxInterfaceCommands(),
            GhostboxContentCommands(),
            GhostboxProcessConfigCommands(),
            GhostboxIOCommands(resource: "readerStream"),
            GhostboxIOCommands(resource: "writer"),
            GhostboxIOCommands(resource: "terminal"),
        ] + GhostboxBootCommandHandlers.all
            + GhostboxConfigurationCommandHandlers.all
            + GhostboxVMCommandHandlers.all
            + GhostboxLifecycleCommandHandlers.all
            + GhostboxPodCommandHandlers.all
    )
}
