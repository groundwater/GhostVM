import XCTest
@testable import GhostVMKit

final class AsyncVsockConnectorTests: XCTestCase {
    func testConnectTimeoutWhenCallbackNeverFires() async {
        let connector = AsyncVsockConnector(
            timeoutNanoseconds: 20_000_000,
            connectOperation: { _ in }
        )

        do {
            _ = try await connector.connect()
            XCTFail("Expected timeout")
        } catch let error as AsyncVsockConnectorError {
            switch error {
            case .timeout:
                break
            default:
                XCTFail("Expected timeout, got \(error)")
            }
        } catch {
            XCTFail("Expected AsyncVsockConnectorError.timeout, got \(error)")
        }
    }

    func testConnectPropagatesConnectFailure() async {
        struct FakeConnectError: Error, Equatable {}
        let connector = AsyncVsockConnector(
            timeoutNanoseconds: 100_000_000,
            connectOperation: { completion in
                completion(.failure(FakeConnectError()))
            }
        )

        do {
            _ = try await connector.connect()
            XCTFail("Expected connection failure")
        } catch is FakeConnectError {
            // expected
        } catch {
            XCTFail("Expected FakeConnectError, got \(error)")
        }
    }
}
