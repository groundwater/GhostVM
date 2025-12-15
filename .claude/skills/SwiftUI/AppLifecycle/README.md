---
name: AppLifecycle
description: Handle macOS app lifecycle with ScenePhase and NSApplicationDelegate. Use when responding to app activation, termination, or background transitions. (project)
---

# App Lifecycle (macOS)

## ScenePhase

```swift
@main
struct MyApp: App {
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        Window("Main", id: "main") {
            ContentView()
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            switch newPhase {
            case .active:
                // App is frontmost
            case .inactive:
                // App visible but not frontmost
            case .background:
                // App hidden or closing
            @unknown default:
                break
            }
        }
    }
}
```

## NSApplicationDelegate

For AppKit-level events, use an adapter:

```swift
@main
struct MyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Window("Main", id: "main") {
            ContentView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Setup after launch
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Cleanup before quit
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false  // Keep running with no windows
    }
}
```

## Common Delegate Methods

| Method | When |
|--------|------|
| `applicationDidFinishLaunching` | App started |
| `applicationWillTerminate` | App quitting |
| `applicationDidBecomeActive` | App frontmost |
| `applicationDidResignActive` | Lost focus |
| `applicationShouldTerminateAfterLastWindowClosed` | Control quit behavior |
| `application(_:open:)` | File/URL opened |

## Don't

- Mix ScenePhase and delegate for same events
- Block in `applicationWillTerminate` (async cleanup may not complete)
- Assume background means suspended (macOS apps keep running)
