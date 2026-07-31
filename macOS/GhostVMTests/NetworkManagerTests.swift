import XCTest
@testable import GhostVMKit

final class NetworkManagerTests: XCTestCase {
    func testVMAndContainerEndpointsShareNetworkControlPlane() async throws {
        let networkID = ManagedNetworkID(rawValue: "development")
        let network = ManagedNetwork(
            id: networkID,
            name: "Development",
            driver: .vmnetShared,
            ipv4Subnet: "192.168.127.0/24",
            gateway: "192.168.127.1"
        )
        let manager = NetworkManager(networks: [network])

        try await manager.attach(ManagedNetworkEndpoint(
            networkID: networkID,
            workloadKind: .virtualMachine,
            workloadID: "macos-dev"
        ))
        try await manager.attach(ManagedNetworkEndpoint(
            networkID: networkID,
            workloadKind: .container,
            workloadID: "web"
        ))

        let endpoints = await manager.endpoints(networkID: networkID)
        XCTAssertEqual(Set(endpoints.map(\.workloadKind)), [.virtualMachine, .container])
    }

    func testAttachRequiresKnownNetwork() async {
        let manager = NetworkManager()
        let networkID = ManagedNetworkID(rawValue: "missing")
        let endpoint = ManagedNetworkEndpoint(
            networkID: networkID,
            workloadKind: .container,
            workloadID: "web"
        )

        do {
            try await manager.attach(endpoint)
            XCTFail("Expected missing network error")
        } catch let error as NetworkManagerError {
            XCTAssertEqual(error, .networkNotFound(networkID))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRemovingNetworkRemovesItsEndpoints() async throws {
        let networkID = ManagedNetworkID(rawValue: "temporary")
        let manager = NetworkManager(networks: [
            ManagedNetwork(id: networkID, name: "Temporary", driver: .virtualizationNAT)
        ])
        try await manager.attach(ManagedNetworkEndpoint(
            networkID: networkID,
            workloadKind: .virtualMachine,
            workloadID: "test-vm"
        ))

        try await manager.remove(id: networkID)

        let endpoints = await manager.endpoints()
        let network = await manager.network(id: networkID)
        XCTAssertTrue(endpoints.isEmpty)
        XCTAssertNil(network)
    }
}
