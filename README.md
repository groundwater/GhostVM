# vmctl

`vmctl` is a single-file Swift command-line utility that provisions and manages macOS virtual machines on Apple Silicon using Apple’s Virtualization.framework. It creates self-contained VM bundles under `~/VMs/<name>.vm/` and supports initialization, installation, start (GUI or headless), graceful stop, status inspection, and coarse snapshots.

## Requirements

- macOS 13 or newer running on Apple Silicon (arm64).
- Xcode command-line tools with the Virtualization.framework headers/libraries.
- The host must comply with Apple’s EULA (macOS guests on Apple-branded hardware).
- macOS virtualization entitlement enabled (run from Terminal on the host).

## Building

```bash
make            # builds ./vmctl
make clean      # removes the binary
```

The Makefile invokes:

```bash
swiftc -parse-as-library -o vmctl vmctl.swift -framework Virtualization -framework AppKit
```

You can override `SWIFTC` or `TARGET` environment variables when calling `make`.

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
