---
name: Macros
description: Use Swift 5.9 macros for repetitive, error-prone boilerplate. Use when pattern repeats across many types and can be derived from source. Prefer built-in macros like @Observable first. (project)
---

# Macros

Swift 5.9+ compile-time code generation.

## When to Use

Use macros to eliminate boilerplate where the pattern is:
1. Repetitive
2. Error-prone if done manually
3. Can be fully derived from the source

| Good Use | Example |
|----------|---------|
| Auto-generate UI from config | `@Settings` struct → form + URL handling |
| Observation boilerplate | `@Observable` |
| Codable with validation | Custom encoder with compile-time checks |

## When NOT to Use

| Bad Use | Why | Alternative |
|---------|-----|-------------|
| Simple code generation | Overkill | Function or generic |
| Runtime behavior | Macros are compile-time only | Protocol, closure |
| Complex logic | Hard to debug | Regular code |
| One-off generation | Not worth the setup | Write it manually |

## Prefer Built-in Macros

Use Apple's macros before writing your own:

```swift
@Observable      // Instead of manual ObservableObject
#Preview         // Instead of PreviewProvider
```

## Creating Custom Macros

Only if built-ins don't cover your case.

**The cost:**
- Separate SPM package required
- SwiftSyntax dependency (~large)
- Harder to debug than regular code
- Xcode tooling still maturing

**Worth it when:**
- Pattern repeats across many types
- Manual implementation is error-prone
- You want compile-time enforcement

## Testing

Always test macro expansions:

```swift
assertMacroExpansion(
    """
    @MyMacro
    struct Foo {}
    """,
    expandedSource: """
    struct Foo {
        // expected generated code
    }
    """,
    macros: ["MyMacro": MyMacro.self]
)
```

## Debugging

Right-click → "Expand Macro" in Xcode to see generated code.

If expansion is confusing, the macro is too complex.

## Don't

- Write macros for things a function could do
- Create macros with complex/surprising expansions
- Skip testing expansions
- Use macros as a substitute for runtime flexibility
- Assume macros are always the "modern" solution
