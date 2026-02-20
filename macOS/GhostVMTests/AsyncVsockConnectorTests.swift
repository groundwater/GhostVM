import XCTest
@testable import GhostVMKit

final class AsyncVsockConnectorTests: XCTestCase {
    struct FakeConnectError: Error, Equatable {}

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

    func testConnectImmediateCallbackDoesNotLaterTimeout() async {
        let connector = AsyncVsockConnector(
            timeoutNanoseconds: 200_000_000,
            connectOperation: { completion in
                completion(.failure(FakeConnectError()))
            }
        )

        do {
            _ = try await connector.connect()
            XCTFail("Expected immediate callback failure")
        } catch is FakeConnectError {
            // expected
        } catch {
            XCTFail("Expected FakeConnectError, got \(error)")
        }
    }

    func testConnectPropagatesConnectFailure() async {
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

    func testCancellationReturnsCancelled() async {
        let connector = AsyncVsockConnector(
            timeoutNanoseconds: 1_000_000_000,
            connectOperation: { _ in }
        )

        let task = Task {
            try await connector.connect()
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancelled")
        } catch let error as AsyncVsockConnectorError {
            switch error {
            case .cancelled:
                break
            default:
                XCTFail("Expected cancelled, got \(error)")
            }
        } catch {
            XCTFail("Expected AsyncVsockConnectorError.cancelled, got \(error)")
        }
    }
}
