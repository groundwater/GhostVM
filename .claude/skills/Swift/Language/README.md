---
name: Swift
description: Swift 6 language fundamentals including strict concurrency, @Observable, actors, and async/await. Use when working with modern Swift patterns. (project)
---

# Swift (Modern)

Swift 6 language fundamentals. Training data may predate Swift 6 (September 2024).

## Swift 6.0 Strict Concurrency

Data races are now **compile-time errors**, not warnings. Enabled via Swift 6 language mode.

```swift
// Sendable - types safe to share across concurrency domains
struct Config: Sendable { let name: String }  // Value types usually infer Sendable

// Non-Sendable types cannot cross actor boundaries
class MutableState { var count = 0 }  // NOT Sendable - mutable reference type
```

## Swift 6.2 (2025) - Approachable Concurrency

Main actor isolation by default (opt-in). Less boilerplate for common UI patterns.

```swift
// @concurrent marks functions that explicitly run off main actor
@concurrent
func fetchData() async -> Data { ... }
```

## @Observable (iOS 17+, Swift 5.9+)

Replaces `ObservableObject`. More efficient - only invalidates views reading changed properties.

```swift
@Observable
class ViewModel {
    var items: [Item] = []      // Automatically tracked
    var isLoading = false
}

struct ContentView: View {
    @State private var vm = ViewModel()  // Use @State, not @StateObject

    var body: some View {
        List(vm.items) { item in ... }   // Only re-renders when items changes
    }
}
```

### Property Wrappers with @Observable

| Wrapper | Use Case |
|---------|----------|
| `@State` | Own the @Observable instance |
| `@Environment` | Inject from environment |
| `@Bindable` | Get bindings from @Observable |

### @Observable + Sendable

```swift
@Observable @MainActor  // Isolate to main actor for thread safety
class AppState {
    var user: User?
}
```

## Actors

```swift
actor DataStore {
    private var cache: [String: Data] = [:]

    func get(_ key: String) -> Data? { cache[key] }       // Isolated
    func set(_ key: String, _ data: Data) { cache[key] = data }
}

// Calling from outside requires await
let store = DataStore()
let data = await store.get("key")
```

## async/await

```swift
func loadUser() async throws -> User {
    let data = try await URLSession.shared.data(from: url).0
    return try JSONDecoder().decode(User.self, from: data)
}

// Structured concurrency
async let profile = loadProfile()
async let posts = loadPosts()
let (p, ps) = await (profile, posts)  // Parallel fetch
```

## Task and Cancellation

```swift
let task = Task {
    for await item in stream {
        try Task.checkCancellation()  // Throws if cancelled
        process(item)
    }
}
task.cancel()  // Request cancellation
```

## Result Builders

```swift
@resultBuilder
struct ArrayBuilder<T> {
    static func buildBlock(_ components: T...) -> [T] { components }
    static func buildOptional(_ component: [T]?) -> [T] { component ?? [] }
    static func buildEither(first: [T]) -> [T] { first }
    static func buildEither(second: [T]) -> [T] { second }
}
```

## Macros (Swift 5.9+)

Built-in macros reduce boilerplate:

```swift
@Observable    // Observation framework
@Model         // SwiftData
#Preview { }   // SwiftUI previews
#expect(...)   // Swift Testing assertions
```

## Swift Testing (Xcode 16+)

```swift
import Testing

@Test func userCreation() {
    let user = User(name: "Test")
    #expect(user.name == "Test")
}

@Test(arguments: [1, 2, 3])
func parameterized(value: Int) {
    #expect(value > 0)
}
```
