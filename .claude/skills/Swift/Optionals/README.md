---
name: Optionals
description: Handle Swift optionals with "crash until you understand" philosophy. Use when deciding between !, guard let, if let, or ??. Crash on unexpected nil, handle only understood cases. (project)
---

# Optionals

A value that might be `nil`. Swift forces you to handle it.

## The Rule: Crash Until You Understand

**Silently absorbing nils is worse than crashing.**

If you don't know why something could be nil, **crash**. This surfaces problems immediately. Once you understand the failure mode, add proper handling.

```swift
// You don't understand why user might be nil
guard let user = user else {
    preconditionFailure("Expected user to exist here")
}

// Later, after investigation, you understand: user is nil when logged out
guard let user = user else {
    showLoginScreen()
    return
}
```

## Unwrapping Syntax

| Method | Use When |
|--------|----------|
| `!` | Nil is a bug - crash immediately |
| `guard let ... else { preconditionFailure() }` | Nil is a bug - crash with context |
| `guard let ... else { handle(); return }` | You understand the nil case |
| `if let` | Both nil and non-nil are valid paths |
| `??` | You have a meaningful default (not just "empty") |

### Force Unwrap (!)

Use when nil means a bug:

```swift
// Checked moments ago
if array.contains(item) {
    let index = array.firstIndex(of: item)!
}

// Invariant: connection must exist during session
let connection = activeConnection!

// Resource that must exist
let url = Bundle.main.url(forResource: "config", withExtension: "json")!
```

### guard let with Crash

When you need more context than `!` provides:

```swift
guard let user = currentUser else {
    preconditionFailure("currentUser must be set before calling processOrder")
}
```

### guard let with Handling

Only after you understand why nil occurs:

```swift
// You know: data is nil when network fails
guard let data = response.data else {
    showNetworkError()
    return
}

// You know: user is nil when not logged in
guard let user = session.user else {
    navigateToLogin()
    return
}
```

### if let

When both branches are valid:

```swift
if let name = user?.nickname {
    greet(name)
} else {
    greet(user.firstName)
}
```

### Nil Coalescing (??)

When the default is meaningful, not just "avoid thinking about it":

```swift
// GOOD - "Anonymous" is a real fallback
let displayName = user?.name ?? "Anonymous"

// GOOD - 0 is the correct count when items don't exist
let count = items?.count ?? 0

// BAD - empty string hides a bug
let name = user?.name ?? ""  // Why would name be nil? Crash instead.

// BAD - "Unknown" masks missing data
let city = address?.city ?? "Unknown"  // Is this expected? Crash until you know.
```

## Optional Chaining

```swift
let city = user?.address?.city  // String?
user?.save()
```

## map and flatMap

Transform without unwrapping:

```swift
let upper = name.map { $0.uppercased() }  // Optional("ALICE")
let parsed = number.flatMap { Int($0) }   // Optional(42)
```

## Multiple Optionals

```swift
// Both must exist
if let name = user?.name, let email = user?.email {
    send(to: email, greeting: name)
}

// With validation
guard let url = URL(string: input),
      url.scheme == "https" else {
    preconditionFailure("Invalid URL: \(input)")
}
```

## Implicitly Unwrapped Optionals

`Type!` - crashes on nil access. Use for:

```swift
// Set once during initialization, never nil after
var repository: Repository!

// IBOutlets (storyboard guarantees non-nil)
@IBOutlet var label: UILabel!
```

## Don't

- Use `guard let x else { return }` when you don't understand why x could be nil
- Use `??` with empty/placeholder values to avoid thinking
- Silence failures with `_ = thing?.method()` when the result matters
- Use `Type!` as a lazy alternative to proper optionals
- Deeply nest `if let` (use `guard` instead)
