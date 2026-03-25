# GhostVM
Native macOS VM manager for Apple Silicon using Virtualization.framework.
Stack: Swift, SwiftUI, AppKit, Virtualization.framework, XcodeGen, SPM

## Architecture
- **GhostVM** — Main SwiftUI app (VM library, creation, snapshots)
- **GhostVMHelper** — Per-VM host process (window, toolbar, services)
- **GhostVMKit** — Shared framework (core types, config, HTTP utilities)
- **GhostTools** — Guest agent (runs inside VM, vsock HTTP server)
- **vmctl** — CLI tool for scripting and automation

## Requirements
- macOS 15+ on Apple Silicon, Xcode 15+, XcodeGen (`brew install xcodegen`)
- `com.apple.security.virtualization` entitlement required

## Commands
- Build (debug): `make debug`
- Generate Xcode project: `make generate`
- Run tests: `make test` and `make uitest`
- Clean: `make clean`

## Critical Constraints
- Version lives in `.version` file; `.plist.in` templates use `__VERSION__` placeholder
- All services (`GhostVM/Services/`) are `@MainActor` isolated
- VZVirtioSocketConnection must be held alive — dropping the object closes the fd
- Guest vsock servers: only blocking accept() works (kqueue/poll/DispatchSource all fail)
- VZVirtualMachineView rejects ALL synthetic events — pointer/keyboard must go through guest GhostTools
- Host screenshots via ScreenCaptureKit only (NSView snapshots return blank for VZ views)
- HTTP builders use `Data` not `String` (binary safety for file transfers)
- GhostTools duplicates HTTP code from host (cannot import GhostVMKit in guest)

## Pull Requests
- Do NOT include a "Test plan" section with manual testing checklists — they are not actionable in CI and add noise
- If automated tests exist for the change, mention them briefly; otherwise omit the section

## Common Mistakes to Avoid
- Never use ad-hoc signing (`-s "-"`) for GhostTools — TCC permissions reset every rebuild
- Never return just the vsock fd — return the VZVirtioSocketConnection object to keep it alive
- Never use NSView snapshot for VM screenshots — use ScreenCaptureKit
- Never add host-side Accessibility permission requirements
