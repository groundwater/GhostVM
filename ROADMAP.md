ROADMAP
=======

This roadmap groups suggested improvements by timeline so contributors can reason about what to tackle next. Each item references the current implementation to highlight why the feature matters.

Near-Term (P0–P1)
-----------------

### 1. Bring CLI to Parity with Controller Capabilities
- **Motivation** – `VMController` already exposes inventory data via `listVMs()` and deletion/update helpers (`vmctl.swift:525`, `vmctl.swift:633`), but the CLI only offers `init/install/start/stop/status/snapshot`.
- **Scope** – Ship `vmctl list`, `vmctl delete`, and `vmctl config` commands that wrap the existing controller APIs so users can manage bundles without the GUI.
- **Notes** – Keeps CLI output aligned with `VMApp` by reusing `VMListEntry.statusDescription`; minimal risk because the logic already exists in the library layer.

### 2. Restore-Image Lifecycle Manager
- **Motivation** – `discoverRestoreImage()` currently scans `~/Downloads` and `/Applications` for IPSW/installer artifacts (`vmctl.swift:138`), failing hard if nothing is found.
- **Scope** – Add `vmctl images fetch/list/prune` commands (and matching UI affordances) that download, cache, and validate restore images via Apple’s softwareupdate/notary endpoints.
- **Notes** – Improves onboarding by baking in the otherwise manual download step and enables the UI to present “Get Restore Image” when none are detected.

### 3. Multi Shared-Folder Profiles
- **Motivation** – `VMStoredConfig` persists only a single `sharedFolderPath` plus a Boolean for read-only state (`vmctl.swift:54`), limiting workflows that need separate project folders.
- **Scope** – Allow multiple named shares per VM with read/write flags, expose them in the Edit Settings sheet, and let `vmctl start` override subsets.
- **Notes** – Requires expanding the config schema (e.g., `[SharedDirectory]`) and updating both CLI parser and SwiftUI forms; migration code should keep legacy single-folder configs working.

### 4. Disk Resize & Clone Templates
- **Motivation** – `InitOptions` locks disk size at creation time (`vmctl.swift:430`), so resizing requires manual disk replacement and reinstalling macOS. Likewise, creating similar VMs forces repeated installs.
- **Scope** – Provide `vmctl disk resize` to grow sparse images safely and add “Clone VM / Save as Template” options in both CLI and UI that duplicate bundles while regenerating hardware IDs.
- **Notes** – Resizing can reuse APFS sparse file utilities; cloning should hook into `VMController.initVM` to avoid sharing identifiers.

Mid-Term (P2)
-------------

### 5. Space-Efficient Snapshots
- **Motivation** – Snapshotting currently copies every artifact into `Snapshots/<name>` (`vmctl.swift:1161`), which is reliable but slow and storage-heavy.
- **Scope** – Investigate APFS clone APIs or `diskutil apfs snapshot` integration to create copy-on-write checkpoints, plus UI to list/restore them.
- **Notes** – Keep the existing coarse implementation as a fallback for external volumes that do not support cloning.

### 6. Advanced Networking Options
- **Motivation** – Every VM uses NAT via `VZNATNetworkDeviceAttachment` (`vmctl.swift:273`), so bridged networking, shared VLANs, or port forwarding require external tools.
- **Scope** – Surface configuration for bridged interfaces, static MACs, and simple port-forwarding rules (especially for headless VMs) inside both the CLI and UI.
- **Notes** – Requires new UI controls and validation to ensure the selected interface supports bridging; should default to NAT to preserve today’s behavior.

Exploratory
-----------

### 7. Telemetry & Health Reporting
- **Motivation** – The app already tails installer logs via pipes (`VMApp.swift:1360`), but there’s no persistent log viewer, uptime tracker, or guest heartbeat monitor once a VM is running.
- **Scope** – Add an optional background agent that collects vmctl/app logs, exposes per-VM uptime, and notifies when a guest shuts down unexpectedly; consider exporting Prometheus-friendly stats.
- **Notes** – This unlocks richer status cards in the SwiftUI list and makes the CLI more automation-friendly by exposing `vmctl status --json`.

### 8. Automated Release & Update Channel
- **Motivation** – The Makefile handles builds, signing, and notarization manually; there’s no documented channel for distributing new builds or auto-updating installed apps.
- **Scope** – Define a GitHub Releases workflow (CI build, notarize, publish DMG) and optionally integrate Sparkle or `softwareupdate`-style feeds so the app can self-update.
- **Notes** – Requires CI secrets management and careful notarization handling but dramatically lowers the friction to ship fixes.

Revisit and reprioritize items as the project evolves; each feature above maps directly to existing code paths, making it straightforward to break them into actionable issues.
