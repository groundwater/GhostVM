# GhostVM-dev

Development wrapper repo. The `GhostVM/` subtree tracks [groundwater/GhostVM](https://github.com/groundwater/GhostVM).

## Workflow

- **Outer repo** — commit and push directly to `main` (no PR required)
- **Subtree (`GhostVM/`)** — changes must go through a PR on the upstream repo

### Subtree Changes

```bash
# 1. Push subtree changes to a feature branch on upstream
git subtree push --prefix=GhostVM ghostvm my-feature-branch

# 2. Open a PR on the upstream repo
gh pr create -R groundwater/GhostVM --head my-feature-branch --title "..." --body "..."

# 3. After the PR merges, pull it back
git subtree pull --prefix=GhostVM ghostvm main --squash
```

Never push the subtree directly to `main` — always use a branch and PR.

## Stack
Swift, SwiftUI, AppKit, Virtualization.framework, XcodeGen, SPM

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
All build commands run from `GhostVM/`:
- Build (debug): `make -C GhostVM debug`
- Generate Xcode project: `make -C GhostVM generate`
- Run tests: `make -C GhostVM test` and `make -C GhostVM uitest`
- Clean: `make -C GhostVM clean`

## Critical Constraints
- Version lives in `GhostVM/.version`; `.plist.in` templates use `__VERSION__` placeholder
- All services (`GhostVM/macOS/GhostVM/Services/`) are `@MainActor` isolated
- VZVirtioSocketConnection must be held alive — dropping the object closes the fd
- Guest vsock servers: only blocking accept() works (kqueue/poll/DispatchSource all fail)
- VZVirtualMachineView rejects ALL synthetic events — pointer/keyboard must go through guest GhostTools
- Host screenshots via ScreenCaptureKit only (NSView snapshots return blank for VZ views)
- HTTP builders use `Data` not `String` (binary safety for file transfers)
- GhostTools duplicates HTTP code from host (cannot import GhostVMKit in guest)

## Pull Requests
- Do NOT include a "Test plan" section with manual testing checklists — they are not actionable in CI and add noise
- If automated tests exist for the change, mention them briefly; otherwise omit the section

## Documents

- **Journal** — Every agent run adds one entry at `Documents/Journal/YYYY/MM/DD/{title}.md`. See `Documents/Developer/Journal-Policy.md` for required fields and naming rules.
- **Plans** — Execution plans go in `Documents/Plans/YYYY/MM/DD/{title}.md`. Reuse existing plans before creating duplicates.
- **Doc-search** — Prefer `bin/doc-search search <query>` over grep/glob when searching documentation. Keyword search via ripgrep.

## Common Mistakes to Avoid
- Never use ad-hoc signing (`-s "-"`) for GhostTools — TCC permissions reset every rebuild
- Never return just the vsock fd — return the VZVirtioSocketConnection object to keep it alive
- Never use NSView snapshot for VM screenshots — use ScreenCaptureKit
- Never add host-side Accessibility permission requirements
