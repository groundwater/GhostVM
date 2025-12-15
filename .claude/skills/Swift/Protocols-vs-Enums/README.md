---
name: Protocols-vs-Enums
description: Choose between protocols and enums for polymorphism. Use when deciding type representation. Key message - `any` is fine, don't abuse enums to avoid it. (project)
---

# Protocols vs Enums for Polymorphism

Both can represent "one of many types." Choose correctly.

## When to Use Each

| Situation | Use |
|-----------|-----|
| Fixed, known set of cases | Enum |
| Open-ended, extensible types | Protocol |
| Need exhaustive switch | Enum |
| Third parties might add types | Protocol |
| Cases have totally different data shapes | Protocol |
| Cases share similar data | Enum with associated values |

## The Problem

AI agents (and developers) avoid protocols because of `any` complexity:

```swift
// "Scary" - requires `any`
var connections: [any Connection]

// "Easier" - no `any` needed
var connections: [ConnectionEnum]
```

**This leads to enum abuse** - cramming unrelated types into enums just to avoid `any`.

## Enum Abuse Example

```swift
// BAD - these are fundamentally different types forced into an enum
enum Connection {
    case arkit(ARKitConnection)
    case liveLink(LiveLinkConnection)
    case midi(MIDIConnection)
    case bluetooth(BluetoothConnection)
    // ... 15 more cases

    // Every method becomes a massive switch
    func start() {
        switch self {
        case .arkit(let c): c.start()
        case .liveLink(let c): c.start()
        case .midi(let c): c.start()
        // ... 15 more
        }
    }

    var isConnected: Bool {
        switch self {
        // ... same thing again
        }
    }
}
```

**Signs you're abusing enums:**
- Switch statements repeated everywhere
- Cases have completely different associated data
- Adding a new case requires touching many files
- The enum keeps growing

## Protocol Solution

```swift
// GOOD - open, extensible
protocol Connection {
    var id: UUID { get }
    var name: String { get }
    var isConnected: Bool { get }
    func start() async throws
    func stop()
}

// Each type implements its own logic
struct ARKitConnection: Connection { ... }
struct LiveLinkConnection: Connection { ... }
struct MIDIConnection: Connection { ... }

// Usage with `any`
var connections: [any Connection] = []
connections.append(ARKitConnection())
connections.append(LiveLinkConnection())

for connection in connections {
    try await connection.start()  // Just works
}
```

## `any` is Fine

Don't fear `any`. It's the correct tool for heterogeneous collections:

```swift
// This is fine
var connections: [any Connection]

// This is fine
func addConnection(_ connection: any Connection)

// This is fine (in an @Observable class)
var activeConnections: [any Connection] = []
```

**When `any` hurts:**
- Hot loops with millions of iterations (rare)
- When you need `Equatable` or `Hashable` on the protocol (use type erasers or identifiers)

## Codable with Protocols

The one legitimate pain point. Options:

**1. Registry pattern (recommended):**

```swift
// Register all known types
enum ConnectionType: String, Codable {
    case arkit, liveLink, midi
}

struct ConnectionWrapper: Codable {
    let type: ConnectionType
    let connection: any Connection

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(ConnectionType.self, forKey: .type)

        switch type {
        case .arkit: connection = try container.decode(ARKitConnection.self, forKey: .connection)
        case .liveLink: connection = try container.decode(LiveLinkConnection.self, forKey: .connection)
        case .midi: connection = try container.decode(MIDIConnection.self, forKey: .connection)
        }
    }
}
```

**2. Accept the single switch:**

One switch for serialization is fine. It's the *only* place you enumerate types. Everything else uses the protocol.

## Decision Checklist

Use **Enum** when:
- [ ] Cases are truly fixed (e.g., `LoadingState: idle, loading, loaded, error`)
- [ ] You want exhaustive compile-time checking
- [ ] Cases share structure (associated values are similar)
- [ ] It's a state machine

Use **Protocol** when:
- [ ] Types are conceptually open (connections, plugins, providers)
- [ ] Each type has different internal complexity
- [ ] You're wrapping enums just to avoid `any`
- [ ] Switch statements are multiplying

## Don't

- Use enums just to avoid writing `any`
- Create enums with 10+ cases that keep growing
- Duplicate switch statements across the codebase
- Fear `any` - it's a feature, not a bug
