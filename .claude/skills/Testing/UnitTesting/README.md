---
name: UnitTesting
description: Write XCTest unit tests with mocks and async support. Use when testing business logic, state transitions, or error handling. Test via public interface, not private methods. (project)
---

# Unit Testing

## Structure

```swift
final class MyTests: XCTestCase {
    func testSomething() {
        // Arrange
        let mock = MockRepository()
        let sut = ViewModel(repository: mock)

        // Act
        sut.doThing()

        // Assert
        XCTAssertEqual(sut.state, .expected)
    }
}
```

## Async Tests

```swift
func testAsyncLoad() async {
    let mock = MockRepository()
    mock.items = [Item(name: "Test")]
    let sut = ViewModel(repository: mock)

    await sut.load()

    XCTAssertEqual(sut.items.count, 1)
}
```

## Mock Pattern

```swift
class MockRepository: Repository {
    var items: [Item] = []
    var shouldFail = false
    var saveCallCount = 0

    func fetch() async throws -> [Item] {
        if shouldFail { throw TestError.mock }
        return items
    }

    func save(_ item: Item) async throws {
        saveCallCount += 1
        items.append(item)
    }
}
```

## Mock API Client

For network code, wrap URLSession in a protocol and mock it:

```swift
protocol APIClient {
    func get<T: Decodable>(_ path: String) async throws -> T
}

class MockAPIClient: APIClient {
    var responses: [String: Any] = [:]
    var shouldFail = false

    func get<T: Decodable>(_ path: String) async throws -> T {
        if shouldFail { throw URLError(.badServerResponse) }
        return responses[path] as! T
    }
}
```

Use URLSession directly. No third-party HTTP libraries for basic networking.

## What to Test

- Business logic
- State transitions
- Error handling
- Edge cases (empty, nil, boundaries)

## Don't

- Test SwiftUI views directly (use UI tests)
- Test private methods (test via public interface)
- Test Apple frameworks
- Write tests that depend on order
- Add Alamofire/Moya for basic HTTP (URLSession is fine)
