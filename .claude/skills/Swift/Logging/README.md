---
name: Logging
description: Log with OSLog and capture to ring buffer for diagnostics. Use when implementing logging, diagnostic export, or debug output. Never use print() in production. (project)
---

# Logging

Use OSLog. Capture logs for diagnostics.

## Rules

1. **OSLog, not print()** - `print()` has no levels, no privacy, no persistence
2. **Capture to ring buffer** - For user-exportable diagnostics
3. **Strip privacy for diagnostics** - OSLog privacy stays intact, ring buffer gets readable text

## Pattern

Use a macro that writes to both OSLog (with privacy) and a ring buffer (without):

```swift
#log(.info, "User: \(username, privacy: .private)", category: .network)
// Console.app: "User: <private>"
// Ring buffer: "User: alice"
```

The macro expands to OSLog call + ring buffer append. See Macros skill.

## Log Levels

| Level | Use |
|-------|-----|
| `.debug` | Verbose dev info, stripped in release |
| `.info` | General flow |
| `.error` | Failures - these should be investigated |

## Diagnostic Export

Keep a ring buffer (last ~500 entries) that users can export via share sheet. This is how you debug issues on user devices.

## Don't

- Use `print()` in production
- Log passwords, tokens, or keys - even with `.private`
- Skip the ring buffer (you need diagnostics from user devices)
- Create loggers in hot paths
