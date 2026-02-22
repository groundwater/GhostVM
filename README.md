<p align="center">
  <img src="Website/public/images/ghostvm-icon.png" width="128" height="128" alt="GhostVM icon">
</p>

<h1 align="center">GhostVM</h1>

<p align="center">
  <strong>Isolated macOS workspaces for agents, projects, and clients</strong>
</p>

<p align="center">
  <a href="https://github.com/groundwater/GhostVM/releases/latest">
    <img src="https://img.shields.io/github/v/release/groundwater/GhostVM?style=flat-square&label=Download&color=5D5CDE" alt="Latest Release">
  </a>
  <a href="#">
    <img src="https://img.shields.io/badge/Platform-macOS%2015%2B-blue?style=flat-square" alt="Platform">
  </a>
  <a href="#">
    <img src="https://img.shields.io/badge/Architecture-Apple%20Silicon-orange?style=flat-square" alt="Architecture">
  </a>
  <a href="LICENSE">
    <img src="https://img.shields.io/github/license/groundwater/GhostVM?style=flat-square" alt="License">
  </a>
</p>

<p align="center">
  <a href="https://ghostvm.dev">Website</a> •
  <a href="https://ghostvm.dev/docs/getting-started">Documentation</a> •
  <a href="https://github.com/groundwater/GhostVM/releases/latest">Download</a>
</p>

---

<p align="center">
  <img src="Website/public/images/screenshots/hero-screenshot.jpg" width="800" alt="GhostVM running VS Code inside a virtual machine">
</p>

GhostVM is a native macOS app for creating and managing macOS virtual machines on Apple Silicon using Apple's `Virtualization.framework`. Each VM is stored as a self-contained `.GhostVM` bundle that you can copy, move, or back up like any file.

## Screenshots

<p align="center">
  <img src="Website/public/images/screenshots/vm-list-with-vms.png" width="280" alt="VM List">&nbsp;&nbsp;
  <img src="Website/public/images/screenshots/create-vm-sheet.png" width="280" alt="Create VM">&nbsp;&nbsp;
  <img src="Website/public/images/screenshots/restore-images.png" width="280" alt="Restore Images">
</p>

<p align="center">
  <img src="Website/public/images/screenshots/clipboard-permission.png" width="280" alt="Clipboard Sync">&nbsp;&nbsp;
  <img src="Website/public/images/screenshots/port-forward-notification.png" width="280" alt="Port Forwarding">&nbsp;&nbsp;
  <img src="Website/public/images/screenshots/context-menu.png" width="280" alt="Context Menu">
</p>

## Features

- **Native Performance** — Built on Apple's Virtualization.framework, near-native speed with no emulation
- **Self-Contained Bundles** — Each workspace is a single `.GhostVM` folder you can copy, move, or back up
- **Snapshots & Clones** — Checkpoint before risky changes; clone instantly with APFS copy-on-write
- **Deep Host Integration** — Clipboard sync, file transfer, shared folders, and automatic port forwarding
- **Per-VM Dock Icons** — Each workspace appears in the Dock with its own custom icon
- **CLI & Scripting** — Full control via `vmctl` for headless operation and automation
- **Host API** — Programmatic access via Unix socket for agent integration

## Installation

<p align="center">
  <a href="https://github.com/groundwater/GhostVM/releases/latest">
    <img src="https://img.shields.io/badge/Download-GhostVM-5D5CDE?style=for-the-badge&logo=apple" alt="Download GhostVM">
  </a>
</p>

1. Download the latest DMG from the [releases page](https://github.com/groundwater/GhostVM/releases/latest)
2. Open the DMG and drag **GhostVM.app** to your Applications folder
3. Launch GhostVM and create your first workspace

**Requirements:** macOS 15+ (Sequoia) on Apple Silicon (M1 or later)

## CLI Usage

The `vmctl` command-line tool provides full control over GhostVM virtual machines:

```bash
# Create and install a macOS VM
vmctl init ~/VMs/dev.GhostVM --cpus 6 --memory 16 --disk 128
vmctl install ~/VMs/dev.GhostVM
vmctl start ~/VMs/dev.GhostVM

# Manage snapshots
vmctl snapshot ~/VMs/dev.GhostVM create clean-state
vmctl snapshot ~/VMs/dev.GhostVM revert clean-state

# Remote commands (requires GhostTools in guest)
vmctl remote --name dev exec uname -a
vmctl remote --name dev clipboard get
vmctl remote --name dev apps
```

<details>
<summary><strong>All Commands</strong></summary>

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
| `remote --name <vm> exec <command>` | Run a shell command in the guest |
| `remote --name <vm> clipboard get\|set` | Read or write the guest clipboard |
| `remote --name <vm> apps` | List running guest applications |

</details>

## Building from Source

**Requirements:** Xcode 15+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen)

```bash
brew install xcodegen

git clone https://github.com/groundwater/GhostVM.git
cd GhostVM
make app
```

<details>
<summary><strong>Build Targets</strong></summary>

| Target | Description |
|--------|-------------|
| `make app` | Build GhostVM.app |
| `make cli` | Build vmctl CLI |
| `make test` | Run unit tests |
| `make run` | Build and run attached to terminal |
| `make launch` | Build and launch detached |
| `make dist` | Create distribution DMG |
| `make clean` | Remove build artifacts |

</details>

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
│   └── GhostVMTests/     # Unit tests
└── Website/              # Documentation site (ghostvm.dev)
```

## Notes

- VMs use NAT networking via `VZNATNetworkDeviceAttachment`
- Shared folders use VirtioFS via `VZVirtioFileSystemDeviceConfiguration`
- GhostTools provides clipboard sync, file transfer, and port discovery
- Apple's EULA requires macOS guests to run on Apple-branded hardware

## License

[MIT License](LICENSE)
