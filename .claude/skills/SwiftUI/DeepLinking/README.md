---
name: DeepLinking
description: Handle URL schemes for navigation and config changes. Use when implementing onOpenURL, config links with user confirmation, or URL-based navigation. Path=navigation, query=config. (project)
---

# Deep Linking

Two purposes:
1. **Navigation** - Jump to a screen
2. **Config** - Modify app settings via URL

Note: deep linking does *NOT* modify documents.

Deep linking **does not store config state**. It parses URLs and updates the app's config system (see ConfigManagement skill).

## URL Format

```
myapp://settings
myapp://connection/abc-123
myapp://settings?api_url=https://staging.api.com&debug_mode=true
myapp://settings/advanced?show_hidden=true
```

Path is navigation, query params are config.

## Navigation Links

Direct user to a specific screen (path portion):

```
myapp://settings
myapp://connections
myapp://connection/{id}
myapp://connection/{id}/edit
```

Handle in SwiftUI:

```swift
.onOpenURL { url in
    navigationState.navigate(to: url.path)
}
```

## Config Links

Modify app configuration values (query params). **User must confirm changes.**

```
myapp://settings?key=value&key2=value2
myapp://?key=value  // Config only, no navigation
```

### Confirmation Flow

When user opens a config link:

1. App parses URL into list of proposed changes
2. App presents confirmation sheet
3. User toggles individual changes on/off
4. User taps "Apply" or "Cancel"
5. Only toggled-on changes are applied

```swift
struct ConfigConfirmationSheet: View {
    let proposedChanges: [ConfigChange]
    @State private var enabled: Set<String> = []  // Keys to apply

    var body: some View {
        List(proposedChanges) { change in
            Toggle(isOn: binding(for: change.key)) {
                VStack(alignment: .leading) {
                    Text(change.key)
                    Text("\(change.oldValue) → \(change.newValue)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }
}
```

## Hidden Configs

Some configs are hidden by default. A config link can modify them:

```
myapp://?internal_api_timeout=5000
```

**Visibility rule:** A modified hidden config becomes visible in the UI until:
1. It is reset to its default value, AND
2. The app restarts

This allows users to see and revert hidden configs they've changed.

## Security

- Config links only modify **local preferences**, never documents
- User **must confirm** every change via sheet
- Log config link usage for debugging

## Don't

- Apply config changes silently without user confirmation
- Allow config links to modify user documents
- Expose sensitive settings via URL parameters
- Skip confirmation in release builds (ok for `--Mock` testing)
