# GhostVM

GhostVM is a native macOS app for creating and managing macOS virtual machines on Apple Silicon using Apple's `Virtualization.framework`. VMs are stored as self-contained `.GhostVM` bundles.

## Features

- Create macOS VMs with customizable CPU, memory, and disk
- Download and manage restore images (IPSW) with built-in feed
- Start, stop, suspend, and resume VMs
- Create, revert, and delete snapshots
- Shared folders between host and guest
- Clipboard sync, file transfer, and URL forwarding via the GhostTools guest agent
- Port forwarding through vsock tunnels
- Per-VM Dock icons with a helper-per-VM architecture
- `vmctl` CLI for headless VM management and scripting
- `vmctl remote` for programmatic guest control (accessibility, pointer, keyboard)

## Requirements

- macOS 15+ on Apple Silicon (arm64)
- Xcode 15+ and XcodeGen (`brew install xcodegen`)

## Building

```bash
make              # Show available targets
make app          # Build GhostVM.app
make cli          # Build vmctl CLI
make test         # Run unit tests
make run          # Build and run attached to terminal
make launch       # Build and launch detached
make dist         # Create distribution DMG
make clean        # Remove build artifacts
```

## Project Structure

```
.
├── Makefile              # Build orchestration
├── macOS/
│   ├── project.yml       # XcodeGen project definition
│   ├── GhostVM/          # Main SwiftUI app (VM manager/launcher)
│   ├── GhostVMHelper/    # Per-VM helper process (display, toolbar, services)
│   ├── GhostVMKit/       # Shared framework (types, VM controller, utilities)
│   ├── GhostTools/       # Guest agent (runs inside VM, vsock communication)
│   ├── GhostVMTests/     # Unit tests
│   └── GhostVMUITests/   # UI tests
└── Website/              # GitHub Pages site
```

## CLI Usage

```bash
vmctl init ~/VMs/sandbox.GhostVM --cpus 6 --memory 16 --disk 128
vmctl install ~/VMs/sandbox.GhostVM
vmctl start ~/VMs/sandbox.GhostVM
vmctl stop ~/VMs/sandbox.GhostVM
```

**Commands:**

| Command | Description |
|---------|-------------|
| `init <bundle>` | Create a new VM bundle (`--cpus`, `--memory`, `--disk`, `--restore-image`) |
| `install <bundle>` | Install macOS from a restore image |
| `start <bundle>` | Launch the VM (`--headless`, `--shared-folder`) |
| `stop <bundle>` | Graceful shutdown |
| `suspend` / `resume` | Suspend and resume VM state |
| `status <bundle>` | Report running state and config |
| `snapshot <bundle> list\|create\|revert\|delete` | Manage snapshots |
| `list` | List all VMs and their status |
| `remote <vm> screenshot` | Capture guest screenshot |
| `remote <vm> elements` | Inspect accessibility tree |
| `remote <vm> leftclick --label <text>` | Click a UI element |
| `remote <vm> type --text <text>` | Type text into the guest |

## Notes

- VMs use `VZNATNetworkDeviceAttachment` for networking
- Shared folders use `VZVirtioFileSystemDeviceConfiguration`
- GhostTools auto-installs to `/Applications` in the guest and auto-updates
- Enable Remote Login (SSH) in the guest for headless use
- Apple's EULA requires macOS guests to run on Apple-branded hardware
