# GhostVM

GhostVM is a native macOS app and CLI tool for provisioning and managing macOS virtual machines on Apple Silicon using Apple's `Virtualization.framework`. VMs are stored as self-contained `.GhostVM` bundles.

## Requirements

- macOS 15+ on Apple Silicon (arm64)
- Xcode 15+ and XcodeGen for building (`brew install xcodegen`)
- `com.apple.security.virtualization` entitlement (included in builds)

## Building

```bash
make              # Build vmctl CLI (default)
make app          # Build GhostVM.app via xcodebuild
make run          # Build and launch the app
make clean        # Remove build artifacts
```

Builds are ad-hoc signed by default. Override `CODESIGN_ID` for a different identity.

## Usage

```bash
./vmctl --help
```

**Commands:**

- `init <bundle-path>` – Create a new VM bundle with hardware identifiers and empty disk
  - Options: `--cpus N`, `--memory GiB`, `--disk GiB`, `--restore-image PATH`, `--shared-folder PATH`, `--writable`
- `install <bundle-path>` – Install macOS from restore image
- `start <bundle-path>` – Launch the VM (GUI by default)
  - Options: `--headless`, `--shared-folder PATH`, `--writable|--read-only`
- `stop <bundle-path>` – Graceful shutdown
- `status <bundle-path>` – Report running state and config
- `snapshot <bundle-path> create|revert <name>` – Manage snapshots

Restore images are auto-discovered from `~/Downloads/*.ipsw` and `/Applications/Install macOS*.app`.

## Example

```bash
make
./vmctl init ~/VMs/sandbox.GhostVM --cpus 6 --memory 16 --disk 128
./vmctl install ~/VMs/sandbox.GhostVM
./vmctl start ~/VMs/sandbox.GhostVM
./vmctl stop ~/VMs/sandbox.GhostVM
```

## Notes

- Disk images are raw sparse files (default 64 GiB)
- NAT networking via `VZNATNetworkDeviceAttachment`
- Shared folders use `VZVirtioFileSystemDeviceConfiguration` (read-only by default)
- Enable Remote Login (SSH) in guest for headless use
