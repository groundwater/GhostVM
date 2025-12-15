---
name: Closures
description: Write safe Swift closures avoiding retain cycles. Use when writing @escaping closures, callbacks, or completion handlers. Key rule - if @escaping, use [weak self]. (project)
---

# Closures

Functions as values. The main danger is retain cycles.

## @escaping = [weak self]

If a closure is `@escaping`, use `[weak self]`. Period.

```swift
// Stored closure = escaping = weak self
var onComplete: (() -> Void)?

func setup() {
    onComplete = { [weak self] in
        guard let self else { return }
        self.refresh()
    }
}
```

## When You Don't Need [weak self]

- `map`, `filter`, `sort` - not escaping
- Non-escaping closures (default)
- Closures that don't reference `self`

```swift
items.filter { $0.isActive }  // No self, no problem
items.map { $0.name }         // No self, no problem
```

## guard let self

When you need self multiple times:

```swift
onComplete = { [weak self] in
    guard let self else { return }
    self.refresh()
    self.updateUI()
    self.save()
}
```

## Prefer async/await

Callbacks require `[weak self]`. Async/await usually doesn't:

```swift
// Callback style - needs [weak self]
fetchUser { [weak self] result in
    self?.display(result)
}

// Async style - cleaner
Task {
    let user = try await fetchUser()
    display(user)  // Called on same actor, no weak self needed
}
```

## Don't

- Forget `[weak self]` in escaping closures
- Use `[unowned self]` (just use weak, it's safer)
- Nest closures deeply (refactor to methods or use async/await)
- Capture large objects when you only need one property
