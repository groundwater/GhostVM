<READONLY - NEVER EDIT THIS SECTION>
Your mission, if you choose to accept it:

- This repository is private.
- Use the `gh` cli to access github. See `docs/gh.md` for details.
- Do websearch for documentation as needed.
- USE COMMON SENSE!!! If common sense conflicts with these instructions, use common sense.
- Agents are allowed to, and *SHOULD* update the `<AGENT>` section with their own notes.
  - Remove old or outdated notes.
  - Don't re-explain code, just point future you in the right direction.
- Always update any github issues you are working on.
  - Update checklists in the description.
  - Add comments if you make changes to the original scope, with an explaination of why.

<IMPORTANT>
When done any task, run: `terminal-notifier -title "$TITLE" -message "$MESSAGE" -sound default -sender com.apple.Terminal` with appropriate text.
</IMPORTANT>

## GitHub URL

If given the link to a github issue

- [ ] Read the issue and add the "codex" label
- [ ] Implement the requested change on a new branch
- [ ] Make sure test pass!
- [ ] Update Agents.md if necessary
- [ ] commit and push the change
- [ ] Open a PR referencing the issue
  - short title
  - write the changelog in the description
  - reference issue if applicable

## Ship It

If you are told to "ship it":
A PR *MUST* already exist, otherwise ABORT.

- [ ] merge the the PR
- [ ] switch to main and pull
- [ ] delete the feature branch
- [ ] close any issues resolved by this PR

</READONLY>
<Agent>

This repository ships two cooperating surfaces—a command-line tool (`vmctl`) and a SwiftUI/macOS App (`GhostVM.app`)—that orchestrate Apple’s `Virtualization.framework` to provision, install, and run `.GhostVM` bundles. The codebase is organized around a handful of long-lived “agents”, each with clear responsibilities and collaboration patterns. This document captures those agents, their inputs/outputs, and the execution flows they participate in so new contributors can reason about changes without re-reading the entire Swift codebase.

Shared Concepts
---------------

* **Bundle layout (`vmctl.swift` – `VMFileLayout`)** – Every VM lives in a user-specified directory (default `~/VMs/<name>.GhostVM`). `VMFileLayout` centralizes paths for `config.json`, `disk.img`, hardware blobs, PID file, and `Snapshots/`.
* **Persisted configuration (`VMStoredConfig`)** – JSON saved via `VMConfigStore` containing hardware sizing, shared folder defaults, restore image metadata, install history, etc. This structure is the contract between CLI/App sessions.
* **Runtime policy** – Apple Silicon + macOS 15+, virtualization entitlement, NAT networking (`VZNATNetworkDeviceAttachment`), Virtio block/file system devices, optional shared folders.
* **Locking & ownership (`vmctl.swift` – PID helpers)** – A simple `vmctl.pid` file encodes which process (CLI vs embedded app) currently owns a VM to prevent concurrent starts.

Agent Catalog
-------------

### 1. Controller Agent (`vmctl.swift`: `VMController`, `VMConfigurationBuilder`, `VMConfigStore`, helpers)

* **Role** – Source of truth for all VM lifecycle operations (init, install, start/stop, status, snapshots, settings updates, deletion). Used by both CLI and UI.
* **Inputs** – Target bundle URL, optional overrides (`InitOptions`, `RuntimeSharedFolderOverride`), file system state, restore images, user commands.
* **Outputs** – Mutated bundle contents, console feedback, structured `VMListEntry` records, running `VZVirtualMachine` instances (via embedded sessions).
* **Key collaborators**
  * `VMFileLayout` to locate assets.
  * `VMConfigurationBuilder` to produce `VZVirtualMachineConfiguration` objects (graphics vs headless, shared folders, serial wiring).
  * `VMLockOwner` utilities to set/clear ownership.
  * `EmbeddedVMSession` interface when compiled with `VMCTL_APP`.
* **Notable behaviors**
  * Discovers restore images automatically from `~/Downloads/*.ipsw` and `Install macOS*.app`.
  * Validates resource availability (shared folder existence, virtualization support).
  * Implements coarse snapshotting by duplicating the bundle (space-heavy but resilient).
  * Surfaces uniform status strings for UI/CLI (running, managed by app, installed, etc.).

### 2. CLI Agent (`vmctl.swift`: `CLI`, `SignalTrap`, `VMCTLMain`)

* **Role** – Thin parser translating user commands into `VMController` calls; default entry point when building `vmctl`.
* **Inputs** – `CommandLine.arguments`, POSIX signals (via `SignalTrap`), environment for `--restore-image` expansions.
* **Outputs** – Human-oriented stdout/stderr text, exit codes, running VMs (in the foreground headless mode the CLI keeps the process alive).
* **Responsibilities**
  * Option parsing with friendly errors (e.g., size parsing via `parseBytes`).
  * Path normalization/validation via `resolveBundleURL`.
  * `start` command optionally wires STDIN/STDOUT to the virtual serial console for headless workflows.
  * Ensures usage help stays in sync with command set.

### 3. Embedded Session Agent (`vmctl.swift`: `EmbeddedVMSession`)

* **Role** – Manages an in-process `VZVirtualMachine` plus the AppKit window hosting `VZVirtualMachineView` when the app launches a VM internally.
* **Inputs** – `VMController.makeEmbeddedSession`, bundle metadata, runtime shared folder overrides.
* **Outputs** – NSWindow lifecycle (show/hide), status callbacks, graceful/forced stop handling, PID lock management.
* **Behaviors**
  * Tracks `State` (`initialized → running → stopped`) and notifies observers.
  * Hooks `VZVirtualMachineDelegate` callbacks for error reporting.
  * Captures the lock until termination; on stop, tears down UI and releases ownership.
  * Falls back to `issueForceStop` when ACPI shutdown fails.

### 4. App Agent (`VMApp.swift`: `VMCTLApp`)

* **Role** – The macOS app shell: bootstraps menus, window, SwiftUI content, form sheets, and wires user intents to the controller/CLI.
* **Inputs** – User actions (buttons, menus, drag-and-drop), `VMLibrary` contents, asynchronous CLI output, embedded session callbacks.
* **Outputs** – Updated `VMListViewModel`, status messages, modals, `NSPanel` forms, running `EmbeddedVMSession` windows, spawned `vmctl` `Process` objects for long operations (init/install/snapshot/stop when not embedded).
* **Key subsystems**
  * Keeps a cache of busy bundle paths to gray out UI while commands run.
  * Uses `VMCTL_CLI_PATH` env override when the CLI lives outside the bundle.
  * Presents install progress windows (`InstallProgressSession`) streaming CLI stdout.
  * Offers create/edit/settings sheets using AppKit controls but binds values back into SwiftUI state.

### 5. UI State & Persistence Agent (`VMApp.swift`: `VMListViewModel`, `VMLibrary`)

* **Role** – Keeps cross-session state synchronized.
  * `VMListViewModel` exposes observable SwiftUI state (entries, busy flags, selection, empty list messaging).
  * `VMLibrary` persists known VM bundle paths in `UserDefaults`, deduplicates entries, and supports drag/drop imports plus cleanup of missing bundles.
* **Inputs** – Controller-provided `VMListEntry` data, Finder/NSEvents, `UserDefaults`.
* **Outputs** – SwiftUI-friendly arrays & selection, updates to `UserDefaults`.

### 6. Build & Distribution Agent (`Makefile`, `vmctl.swift` entry guard, packaging assets)

* **Role** – Handles reproducible builds, entitlements, app/dmg packaging, and notarization helpers.
* **Inputs** – Environment variables (`SWIFTC`, `TARGET`, `CODESIGN_ID`, `RELEASE_CODESIGN_ID`, notarization credentials).
* **Outputs** – `vmctl` binary, `GhostVM.app`, signed/notarized `.dmg`.
* **Behaviors** – Ad-hoc signing by default; optional Developer ID/resigning pathway; `make notary-info` prints helper info.

### 7. Restore Image Feed Agent (`VMApp.swift`: `IPSWLibrary`, `IPSWManagerWindowController`)

* **Role** – Maintains the IPSW feed URL, downloads cache into `~/Library/Application Support/GhostVM/IPSW`, and exposes a management UI so users can fetch/delete restore images.
* **Inputs** – UserDefaults-driven feed URL, Apple’s XML feed, cached `.ipsw` files.
* **Outputs** – Downloaded restore images surfaced to the Create VM drop-down (`NSPopUpButton`), per-entry download/delete actions, Finder reveals.
* **Behaviors** – Deduplicates feed entries by `FirmwareURL`, sorts by version/build, blocks concurrent downloads per entry, and notifies the Create VM sheet when the cache changes so menus stay in sync.

Operational Flows
-----------------

### Creating a VM (`vmctl init` or App “Create VM”)
1. User supplies target path and optional sizing arguments.
2. `VMController.initVM` validates virtualization support, normalizes bundle URL, and calls `discoverRestoreImage` unless overridden.
3. `VMFileLayout.ensureBundleDirectory` prepares folders; hardware model and identifiers are generated via `VZMacHardwareModel`/`VZMacMachineIdentifier`.
4. `config.json` is seeded with defaults and stored via `VMConfigStore`.

### Installing macOS (`vmctl install` / App install button)
1. Controller loads existing config, prevents concurrent runs with PID lock.
2. `VZMacOSRestoreImage.load` fetches metadata; `VZMacOSInstaller` is created on a private queue.
3. Progress observations forward human-readable status; upon completion metadata (`installed`, build/version/date) updates.
4. App variant streams installer stdout into an `NSTextView` while the CLI prints to stdout directly.

### Starting & Stopping
* **CLI** – `controller.startVM` builds a configuration (headless toggles serial bridging vs GUI), writes PID lock, installs `SignalTrap` so Ctrl+C first requests ACPI shutdown before force-stopping.
* **App** – Attempts embedded launch first:
  * If allowed, `makeEmbeddedSession` returns an `EmbeddedVMSession` that owns the PID lock and shows the live window.
  * Otherwise falls back to spawning `vmctl start` as a detached process and tracks it via `runningProcesses`.
* **Stopping** – Either sends graceful request through the session or runs `vmctl stop`. Lock removal happens in both code paths to avoid stale ownership.

### Snapshots
1. `controller.snapshot(... create|revert ...)` sanitizes names to prevent path traversal.
2. Snapshot creation duplicates key files into `Snapshots/<name>/`.
3. Revert copies snapshot artifacts back after taking a temporary safety backup; temp folder deleted on success.

### VM Deletion
* App shows an `NSAlert`; on confirmation `VMController.moveVMToTrash` validates non-running status then uses `FileManager.trashItem`.

Extending / Creating New Agents
-------------------------------

* **Adding CLI commands** – Extend `CLI.run()` switch plus `showHelp`. Keep argument parsing side-effect free, then call into `VMController` or new helpers so UI and CLI stay consistent.
* **Augmenting VM metadata** – Update `VMStoredConfig`, adjust JSON coding strategies, and ensure both CLI/App update and display the new fields (`VMRowView.statsDescription`).
* **New UI features** – Prefer enhancing `VMListViewModel` or creating dedicated observable objects; route heavy lifting back through `VMController` or `vmctl` to avoid duplicating logic.
* **Icons & appearance** – App and `.GhostVM` bundle icons are now driven by light/dark PNG resources (`ghostvm.png`, `ghostvm-dark.png`) wired in `VMCTLApp.applicationDidFinishLaunching` and copied via the `app` target in `Makefile`.
* **Automation hooks** – The PID lock, snapshot layout, and `vmctl` textual output are the integration surface for external tooling (CI, scripts). Preserve backward compatibility when possible.

Reference Map
-------------

| Agent / Concept | Primary File(s) | Notes |
| --- | --- | --- |
| VM lifecycle core | `vmctl.swift` (sections: utilities → controller → CLI) | Compiles for both CLI and app (`#if VMCTL_APP`). |
| CLI entrypoint | `vmctl.swift` (`CLI`, `VMCTLMain`) | Builds `vmctl` binary used standalone and embedded inside the app bundle. |
| App shell & UI | `VMApp.swift` | Requires `VMCTL_APP` flag; embeds SwiftUI view hierarchy within AppKit shell. |
| Build tooling | `Makefile`, `entitlements.plist`, assets | Coordinates `swiftc`, codesigning, DMG/notarization. |
| macOS guidelines | `docs/MacOS.md` | High-level rules for preferring SwiftUI and isolating AppKit in adapter files. |

### 8. SwiftUI Demo App Agent (`SwiftUIDemoApp.swift`: `GhostVMSwiftUIApp`)

* **Role** – Pure SwiftUI playground app that mimics key surfaces (VM list, settings, VM window) using only placeholder data.
* **Inputs** – In-memory `DemoVMStore` sample models; no file system, Virtualization, or AppKit dependencies.
* **Outputs** – A SwiftUI-only app bundle (`GhostVM-SwiftUI.app`) built via `make app2`, with:
  * Main window showing a list of demo VMs and action buttons wired to no-op or demo behaviors.
  * Separate Settings window implemented as a distinct `WindowGroup`, not a sheet or panel.
  * Fake VM windows opened via `openWindow(id: "vm", value: vm)` that render a stub display and console.
* **Notes** – This app intentionally does not touch real `.GhostVM` bundles or share code with `VMController`; it is safe to prototype UI flows here without impacting the production app.

Use this document as the living index when introducing new behavior. If you add an additional long-running subsystem (e.g., a background agent that syncs VM templates), document it here with its inputs, outputs, and interactions so contributors can quickly orient themselves.

</Agent>
