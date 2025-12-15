---
name: Application
description: GhostVM app architecture, file layout, and design patterns. Use when adding features, understanding code organization, or working with VM bundles. (project)
---

# GhostVM Application Architecture

## Two Parallel Surfaces

### 1. vmctl CLI (`GhostVM/vmctl.swift`)

Single-file CLI tool for VM operations. Contains:
- `VMController` - VM lifecycle operations
- `VMConfigStore` - JSON config read/write
- `VMFileLayout` - Bundle path conventions
- `CLI` - Argument parsing and commands

Commands: `init`, `install`, `start`, `stop`, `status`, `snapshot`

Builds as standalone binary AND embedded in app.

### 2. SwiftUI App (`GhostVM/`)

| File | Purpose |
|------|---------|
| `SwiftUIDemoApp.swift` | App entry, window scenes |
| `App2VMStore.swift` | Observable VM list from UserDefaults + disk |
| `App2VMRunSession.swift` | Runtime controller wrapping VZVirtualMachine |
| `App2RestoreImageStore.swift` | IPSW feed discovery |
| `App2IPSW.swift` | IPSW download management |
| `App2VMDisplayHost.swift` | NSViewRepresentable for VZVirtualMachineView |
| `App2Models.swift` | Data models |
| `*Adapter.swift` | AppKit isolation (Finder, SavePanel, AppIcon) |

## Design Rules

### SwiftUI-First
- New UI in SwiftUI
- AppKit only when unavoidable

### AppKit Isolation
All AppKit code in dedicated `*Adapter.swift` files:
```swift
// FinderAdapter.swift
import AppKit

enum FinderAdapter {
    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
```

### Window Scenes
Each window type is a separate scene with stable `id`:
- `"main"` - VM list
- `"settings"` - Preferences
- `"restoreImages"` - IPSW browser
- `"vm"` - VM display (parameterized by bundle path)

## VM Bundle Format (`.GhostVM`)

Self-contained bundle containing:
```
MyVM.GhostVM/
├── config.json              # VM metadata (CPUs, memory, disk size)
├── disk.img                 # Raw sparse disk image
├── HardwareModel.bin        # Platform identity
├── MachineIdentifier.bin    # Machine identity
└── AuxiliaryStorage.bin     # Auxiliary storage
```

## Key Paths

| Path | Purpose |
|------|---------|
| `~/Downloads/*.ipsw` | User-downloaded restore images |
| `Install macOS*.app` | Installer app SharedSupport |
| `~/Library/Application Support/GhostVM/IPSW/` | IPSW cache |
| `~/VMs/*.GhostVM` | Default VM location |

## Adding Features

1. **New UI**: Create SwiftUI view, add to appropriate window scene
2. **AppKit needed**: Create `*Adapter.swift` with static methods
3. **VM operations**: Add to `VMController` in vmctl.swift
4. **New window**: Add `WindowGroup` to SwiftUIDemoApp.swift with unique `id`
