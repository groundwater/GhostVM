import XCTest
@testable import GhostVMKit

final class GhostToolsInstallStateTests: XCTestCase {
    func testStateStaysNotInstalledUntilFirstConnection() {
        var state: GhostToolsInstallState = .notInstalled

        state.record(healthStatus: .connecting)
        XCTAssertEqual(state, .notInstalled)

        state.record(healthStatus: .notFound)
        XCTAssertEqual(state, .notInstalled)

        state.record(healthStatus: .connected)
        XCTAssertEqual(state, .installedConfirmed)
    }

    func testConfirmedInstallStateDoesNotDemoteWhenToolsDisappear() {
        var state: GhostToolsInstallState = .notInstalled
        state.record(healthStatus: .connected)
        XCTAssertEqual(state, .installedConfirmed)

        state.record(healthStatus: .notFound)
        XCTAssertEqual(state, .installedConfirmed)

        state.record(healthStatus: .connecting)
        XCTAssertEqual(state, .installedConfirmed)
    }

    func testToolbarPolicyHidesLiveStatusWhileNotInstalled() {
        XCTAssertEqual(
            GhostToolsToolbarPolicy.presentation(installState: .notInstalled, healthStatus: .connecting),
            .installCallToAction
        )
        XCTAssertEqual(
            GhostToolsToolbarPolicy.presentation(installState: .notInstalled, healthStatus: .notFound),
            .installCallToAction
        )
        XCTAssertEqual(
            GhostToolsToolbarPolicy.presentation(installState: .notInstalled, healthStatus: .connected),
            .installCallToAction
        )
    }

    func testToolbarPolicyUsesLiveStatusAfterInstallConfirmation() {
        XCTAssertEqual(
            GhostToolsToolbarPolicy.presentation(installState: .installedConfirmed, healthStatus: .connecting),
            .liveStatus(.connecting)
        )
        XCTAssertEqual(
            GhostToolsToolbarPolicy.presentation(installState: .installedConfirmed, healthStatus: .connected),
            .liveStatus(.connected)
        )
        XCTAssertEqual(
            GhostToolsToolbarPolicy.presentation(installState: .installedConfirmed, healthStatus: .notFound),
            .liveStatus(.notFound)
        )
    }
}
