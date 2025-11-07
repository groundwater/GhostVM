# Virtual Machine Manager

Virtual Machine Manager ships both a native macOS app (`VirtualMachineManager.app`) and the accompanying `vmctl` command-line tool. Together they provision and manage macOS virtual machines on Apple Silicon using Apple’s `Virtualization.framework`, producing self-contained `.VirtualMachine` bundles wherever you choose to store them (the app defaults to `~/VMs` but any writable location works). The UI surfaces your VM inventory, status, and common actions; the CLI remains available for scripting and automation.

## Requirements

### Running the App

- macOS 15 or newer on Apple Silicon (arm64).
- Apple’s macOS virtualization entitlement enabled on the host.
- Apple’s `Virtualization.framework`, which is part of macOS; end users do **not** need Xcode installed to run the packaged app.

### Using the Command Line Tool

- Same runtime requirements as the app.
- Run commands against the full path to a `.VirtualMachine` bundle, no matter where it lives.

### Building From Source

- Xcode 15 (or newer) with the corresponding command-line tools installed so `swiftc` can link against `Virtualization.framework` and `AppKit`.
- macOS 15 or newer on Apple Silicon.
- The ability to run binaries with the macOS virtualization entitlement (granted via Terminal once per host).

## Building

```bash
make            # builds ./vmctl (codesigned ad-hoc with entitlements)
make app        # builds VirtualMachineManager.app alongside vmctl
make clean      # removes the binary and app bundle
```

The `make` targets rely on `swiftc` to compile both targets and link against the system frameworks in `/System/Library/Frameworks`. By default the binaries are ad-hoc signed so the virtualization entitlement is present. Override `CODESIGN_ID` with a Developer ID or other identity if you prefer. You can also override `SWIFTC`, `TARGET`, or `APP_TARGET` for custom toolchains or names.

## Usage

```bash
./vmctl --help
```

Key commands (all expect a full path to `*.VirtualMachine`):

- `init <bundle-path>` – Create a new VM bundle, generate hardware identifiers, auxiliary storage, empty disk, and config. Options: `--cpus`, `--memory`, `--disk`, `--restore-image`, `--shared-folder`, `--writable`.
- `install <bundle-path>` – Boot the VM with `VZMacOSInstaller` using the restore image. Progress updates print to stdout.
- `start <bundle-path> [--headless] [--shared-folder PATH] [--writable|--read-only]` – Launch the VM. GUI mode displays a minimal AppKit window hosting `VZVirtualMachineView`; headless mode hooks the serial console to STDIO. Supplying `--shared-folder` lets you override or add a shared directory for this run (default read-only unless `--writable` is provided).
- `stop <bundle-path>` – Request graceful shutdown; escalates to SIGKILL if the guest ignores requests.
- `status <bundle-path>` – Report running state, PID, and configuration summary.
- `snapshot <bundle-path> create|revert <snapname>` – External snapshots by copying bundle artifacts (coarse and space-heavy but simple).
- The macOS app mirrors the same workflow: create a VM, then choose **Install** to run the installer with a live log/progress window, no Terminal required. Once installed, start/stop the VM directly in the UI.

Restore images are auto-discovered (e.g. `~/Downloads/*.ipsw`, `/Applications/Install macOS*.app/Contents/SharedSupport/SharedSupport.dmg`) unless `--restore-image` is specified.

https://developer.apple.com/download/os/

After installation, enable Remote Login (SSH) inside the guest for comfortable headless use.

## Notes

- Disk images are raw sparse files by default (64 GiB). Adjust via `--disk`.
- NAT networking is configured via `VZNATNetworkDeviceAttachment`.
- Shared folders (optional) use `VZVirtioFileSystemDeviceConfiguration` and default to read-only.
- Signal handling ensures Ctrl+C issues a graceful ACPI power button request before force-stopping.

## Example Workflow

```bash
make
./vmctl init ~/VMs/sandbox.VirtualMachine --cpus 6 --memory 16 --disk 128
./vmctl install ~/VMs/sandbox.VirtualMachine
./vmctl start ~/VMs/sandbox.VirtualMachine          # GUI
./vmctl start ~/VMs/sandbox.VirtualMachine --headless
./vmctl start ~/VMs/sandbox.VirtualMachine --shared-folder ~/Projects --writable
./vmctl snapshot ~/VMs/sandbox.VirtualMachine create clean
./vmctl stop ~/VMs/sandbox.VirtualMachine
./vmctl snapshot ~/VMs/sandbox.VirtualMachine revert clean
```

Enjoy experimenting with macOS VMs on Apple Silicon!
