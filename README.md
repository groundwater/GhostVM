# Virtual Machine Manager

Virtual Machine Manager ships both a native macOS app (`VirtualMachineManager.app`) and the accompanying `vmctl` command-line tool. Together they provision and manage macOS virtual machines on Apple Silicon using Apple’s `Virtualization.framework`, producing self-contained bundles under `~/VMs/<name>.vm/`. The UI surfaces your VM inventory, status, and common actions; the CLI remains available for scripting and automation.

## Requirements

### Running the App

- macOS 15 or newer on Apple Silicon (arm64).
- Apple’s macOS virtualization entitlement enabled on the host.
- Apple’s `Virtualization.framework`, which is part of macOS; end users do **not** need Xcode installed to run the packaged app.

### Using the Command Line Tool

- Same runtime requirements as the app.
- Keep the VM bundles under `~/VMs` accessible to the user account invoking `vmctl`.

### Building From Source

- Xcode 15 (or newer) with the corresponding command-line tools installed so `swiftc` can link against `Virtualization.framework` and `AppKit`.
- macOS 15 or newer on Apple Silicon.
- The ability to run binaries with the macOS virtualization entitlement (granted via Terminal once per host).

## Building

```bash
make            # builds ./vmctl
make app        # builds VirtualMachineManager.app alongside vmctl
make clean      # removes the binary and app bundle
```

The `make` targets rely on `swiftc` to compile both targets and link against the system frameworks in `/System/Library/Frameworks`. Override `SWIFTC`, `TARGET`, or `APP_TARGET` if you need custom toolchains or names.

## Usage

```bash
./vmctl --help
```

Key commands:

- `init <name>` – Create a new VM bundle, generate hardware identifiers, auxiliary storage, empty disk, and config. Options: `--cpus`, `--memory`, `--disk`, `--restore-image`, `--shared-folder`, `--writable`.
- `install <name>` – Boot the VM with `VZMacOSInstaller` using the restore image. Progress updates print to stdout.
- `start <name> [--headless] [--shared-folder PATH] [--writable|--read-only]` – Launch the VM. GUI mode displays a minimal AppKit window hosting `VZVirtualMachineView`; headless mode hooks the serial console to STDIO. Supplying `--shared-folder` lets you override or add a shared directory for this run (default read-only unless `--writable` is provided).
- `stop <name>` – Request graceful shutdown; escalates to SIGKILL if the guest ignores requests.
- `status <name>` – Report running state, PID, and configuration summary.
- `snapshot <name> create|revert <snapname>` – External snapshots by copying bundle artifacts (coarse and space-heavy but simple).

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
./vmctl init sandbox --cpus 6 --memory 16 --disk 128
./vmctl install sandbox
./vmctl start sandbox          # GUI
./vmctl start sandbox --headless
./vmctl start sandbox --shared-folder ~/Projects --writable
./vmctl snapshot sandbox create clean
./vmctl stop sandbox
./vmctl snapshot sandbox revert clean
```

Enjoy experimenting with macOS VMs on Apple Silicon!
