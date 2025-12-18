# GhostVM

GhostVM is a native macOS app and CLI tool for provisioning and managing macOS and Linux virtual machines on Apple Silicon using Apple's `Virtualization.framework`. VMs are stored as self-contained `.GhostVM` bundles.

## Requirements

- macOS 15+ on Apple Silicon (arm64)
- Xcode 15+ and XcodeGen for building (`brew install xcodegen`)
- `com.apple.security.virtualization` entitlement (included in builds)

## Building

```bash
make              # Show available targets
make cli          # Build vmctl CLI
make app          # Build GhostVM.app via xcodebuild
make run          # Build and run attached to terminal
make launch       # Build and launch detached
make test         # Run unit tests
make dist         # Create distribution DMG with app + vmctl
make clean        # Remove build artifacts and generated project
```

Builds are ad-hoc signed by default. Override `CODESIGN_ID` for a different identity.

## GUI App

The GhostVM.app provides a SwiftUI interface for managing VMs:

- Create macOS or Linux VMs with customizable CPU, memory, and disk
- Manage restore images (IPSW) with built-in download support
- Start, stop, suspend, and resume VMs
- Create, revert, and delete snapshots
- Configure shared folders (read-only or writable)
- VM menu with keyboard shortcuts for Start, Suspend, Shut Down, and Terminate

## CLI Usage

```bash
./vmctl --help
```

**macOS VM Commands:**

- `init <bundle-path>` – Create a new macOS VM bundle
  - Options: `--cpus N`, `--memory GiB`, `--disk GiB`, `--restore-image PATH`, `--shared-folder PATH`, `--writable`
- `install <bundle-path>` – Install macOS from restore image

**Linux VM Commands:**

- `create-linux <bundle-path>` – Create a new Linux VM bundle
  - Options: `--iso PATH`, `--cpus N`, `--memory GiB`, `--disk GiB`
- `detach-iso <bundle-path>` – Remove installer ISO after installation

**Common Commands:**

- `start <bundle-path>` – Launch the VM (GUI by default)
  - Options: `--headless`, `--shared-folder PATH`, `--writable|--read-only`
- `stop <bundle-path>` – Graceful shutdown
- `status <bundle-path>` – Report running state and config
- `resume <bundle-path>` – Resume from suspended state
  - Options: `--headless`, `--shared-folder PATH`, `--writable|--read-only`
- `discard-suspend <bundle-path>` – Discard suspended state
- `snapshot <bundle-path> list` – List snapshots
- `snapshot <bundle-path> create|revert|delete <name>` – Manage snapshots

Restore images are auto-discovered from `~/Downloads/*.ipsw` and `/Applications/Install macOS*.app`.

## Examples

**macOS VM:**

```bash
make cli
./vmctl init ~/VMs/sandbox.GhostVM --cpus 6 --memory 16 --disk 128
./vmctl install ~/VMs/sandbox.GhostVM
./vmctl start ~/VMs/sandbox.GhostVM
./vmctl stop ~/VMs/sandbox.GhostVM
```

**Linux VM:**

```bash
./vmctl create-linux ~/VMs/ubuntu.GhostVM --iso ~/Downloads/ubuntu-24.04-live-server-arm64.iso --disk 50 --memory 4 --cpus 4
./vmctl start ~/VMs/ubuntu.GhostVM
./vmctl detach-iso ~/VMs/ubuntu.GhostVM  # After installation
```

**Suspend and Resume:**

```bash
# Use VM > Suspend menu (Cmd+Option+S) in the app, then:
./vmctl resume ~/VMs/sandbox.GhostVM
```

**Snapshots:**

```bash
./vmctl snapshot ~/VMs/sandbox.GhostVM list
./vmctl snapshot ~/VMs/sandbox.GhostVM create clean
./vmctl snapshot ~/VMs/sandbox.GhostVM revert clean
./vmctl snapshot ~/VMs/sandbox.GhostVM delete clean
```

## Notes

- Disk images are raw sparse files (default 64 GiB)
- NAT networking via `VZNATNetworkDeviceAttachment`
- Shared folders use `VZVirtioFileSystemDeviceConfiguration` (read-only by default)
- Linux VMs require ARM64 ISOs (aarch64); x86_64 ISOs will not work
- Enable Remote Login (SSH) in guest for headless use
- Apple's EULA requires macOS guests to run on Apple-branded hardware
