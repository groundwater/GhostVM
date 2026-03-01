import Foundation
import GhostVMKit
import os

/// Manages custom network processors for VMs using custom network mode.
@MainActor
public final class CustomNetworkService: ObservableObject {
    private static let logger = Logger(subsystem: "org.ghostvm.ghostvm", category: "CustomNetworkService")
    private var processors: [UUID: CustomNetworkProcessor] = [:]

    public init() {}

    /// Start custom network processors for the given attachments.
    public func start(attachments: [CustomNetworkAttachment]) {
        let store = CustomNetworkStore.shared

        for attachment in attachments {
            guard let routerConfig = try? store.get(attachment.customNetworkID) else {
                Self.logger.error("Custom network \(attachment.customNetworkID.uuidString) not found, skipping NIC \(attachment.nicIndex)")
                continue
            }

            let vmMAC = MACAddress(string: attachment.vmMAC) ?? MACAddress(0x00, 0x00, 0x00, 0x00, 0x00, 0x00)
            let processor = CustomNetworkProcessor(
                hostHandle: attachment.hostHandle,
                config: routerConfig,
                vmMAC: vmMAC
            )
            processor.start()
            processors[attachment.customNetworkID] = processor

            Self.logger.info("Started custom network '\(routerConfig.name)' for NIC \(attachment.nicIndex)")
        }
    }

    /// Stop all custom network processors.
    public func stop() {
        for (_, processor) in processors {
            processor.stop()
        }
        processors.removeAll()
        Self.logger.info("Stopped all custom network processors")
    }
}
