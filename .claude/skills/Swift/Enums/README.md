---
name: Enums
description: Use Swift enums for closed, fixed sets like state machines. Use when implementing state enums, error types, or discriminated unions. Avoid for open-ended types - use protocols instead. (project)
---

# Enums

Swift enums are state machines with data. Use them for **closed, fixed sets**.

## When to Use

| Use Enum | Example |
|----------|---------|
| State machine | `ConnectionState: disconnected, connecting, connected, failed` |
| Fixed options | `SortOrder: ascending, descending` |
| Error types | `ValidationError: tooShort, invalidFormat` |
| Discriminated union | `Result<T, E>` |

## When NOT to Use

| Don't Use Enum | Use Instead |
|----------------|-------------|
| Open-ended types (plugins, connections) | Protocol (see Protocols-vs-Enums skill) |
| Growing list of cases | Protocol |
| Avoiding `any` keyword | Protocol - `any` is fine |

## Associated Values

Each case holds different data:

```swift
enum ConnectionState {
    case disconnected
    case connecting(attempt: Int)
    case connected(host: String)
    case failed(Error)
}
```

## Computed Properties Over Switch Spam

Put the switch in one place:

```swift
enum ConnectionState {
    // ...

    var canRetry: Bool {
        switch self {
        case .disconnected, .failed: true
        case .connecting, .connected: false
        }
    }
}
```

Don't repeat switches everywhere. If you're switching on the same enum in multiple places, add a computed property.

## @unknown default

For SDK enums that might add cases:

```swift
switch externalEnum {
case .known: // ...
@unknown default:
    preconditionFailure("Unhandled case: \(externalEnum)")
}
```

Crash on unknown cases. Don't silently ignore them.

## Don't

- Use enums to avoid `any` (see Protocols-vs-Enums skill)
- Add 10+ cases to one enum (it's probably a protocol)
- Switch on the same enum in multiple files (add computed property)
- Use `default:` to ignore cases (be exhaustive, crash on unknown)
