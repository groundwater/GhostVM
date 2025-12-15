# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build Commands

```bash
make          # Build vmctl CLI (default)
make cli      # Build vmctl CLI
make generate # Generate Xcode project from project.yml
make app      # Build SwiftUI app (auto-generates project)
make run      # Build and launch the app
make clean    # Remove build artifacts and generated project
```

The Xcode project is generated from `project.yml` using XcodeGen (`brew install xcodegen`). The standalone `vmctl` binary is built via swiftc with `-parse-as-library` flag.

## Architecture

GhostVM manages macOS VMs on Apple Silicon using Apple's `Virtualization.framework`. VMs are stored as self-contained `.GhostVM` or `.FixieVM` bundles containing:
- `config.json` - VM metadata (CPUs, memory, disk size, paths)
- `disk.img` - Raw sparse disk image
- `HardwareModel.bin`, `MachineIdentifier.bin`, `AuxiliaryStorage.bin` - Platform identity blobs

### Two Parallel Surfaces

1. **vmctl CLI** (`vmctl.swift`) - Single-file CLI tool for init/install/start/stop/status/snapshot operations. Contains `VMController`, `VMConfigStore`, `VMFileLayout`, and `CLI` classes. Builds both as standalone binary and embedded in the app.

2. **SwiftUI App** (`SwiftUIDemoApp.swift` + `App2*.swift`) - Modern SwiftUI app built via Xcode project:
   - `App2VMStore` - Observable store managing VM list from `UserDefaults` + disk
   - `App2VMRunSession` - Runtime controller wrapping `VZVirtualMachine`
   - `App2RestoreImageStore` / `App2IPSW.swift` - IPSW feed and download management
   - `App2VMDisplayHost.swift` - `NSViewRepresentable` wrapper for `VZVirtualMachineView`
   - Adapter files (`FinderAdapter`, `SavePanelAdapter`, `AppIconAdapter`) - Isolate AppKit dependencies

### Design Guidelines

- **SwiftUI-first**: New UI goes in SwiftUI; AppKit only when unavoidable
- **AppKit isolation**: All AppKit code belongs in dedicated `*Adapter.swift` files exposing SwiftUI-friendly APIs
- **Window scenes**: Each window type is a separate `WindowGroup` with stable `id` strings (`"main"`, `"settings"`, `"restoreImages"`, `"vm"`)

## Key Paths

- Restore images: `~/Downloads/*.ipsw` and `Install macOS*.app` SharedSupport discovered automatically
- IPSW cache: `~/Library/Application Support/GhostVM/IPSW/`
- Default VM location: `~/VMs/*.GhostVM` or `*.FixieVM`

## Requirements

- macOS 15+ on Apple Silicon (arm64)
- Xcode 15+ for building
- XcodeGen (`brew install xcodegen`)
- `com.apple.security.virtualization` entitlement required

## Agent Workflow Notes

- Use `gh` CLI for GitHub operations (see `docs/gh.md`)
- When done with a task, run: `terminal-notifier -title "$TITLE" -message "$MESSAGE" -sound default -sender com.apple.Terminal`
- Update `AGENTS.md` `<Agent>` section with implementation notes for future reference