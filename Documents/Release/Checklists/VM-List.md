# Release Checklist

Testable assertions for every feature and invariant. Format: `When X: Y MUST Z`.

---

## VM List (Main Window)

### Main Window

**When the app launches:**
- [ ] Window title MUST read "GhostVM"
- [ ] Window minimum size MUST be 520x360
- [ ] Window MUST restore its previous position and size across launches

---

### Header Bar

**When viewing the header bar:**
- [ ] "Create" button MUST be visible on the left side
- [ ] "Create" button MUST use borderedProminent style
- [ ] "Images" button MUST be visible on the right side
- [ ] "Images" button MUST use bordered style

**When clicking "Create":**
- [ ] Create VM sheet MUST open

**When clicking "Images":**
- [ ] Restore Images window MUST open

---

### VM List Display

**When VMs exist:**
- [ ] VMs MUST be sorted alphabetically by name
- [ ] List MUST use inset style
- [ ] Ghost watermark MUST be visible behind the list

**When no VMs exist:**
- [ ] No explicit empty-state message MUST be shown
- [ ] Ghost watermark MUST still be visible
- [ ] Dragging a .ghostvm bundle over the list MUST show a drop hint row

---

### VM Row Layout

**When viewing a VM row:**
- [ ] VM icon MUST be 64x64 pixels
- [ ] VM icon MUST show custom icon if set, otherwise fallback icon
- [ ] VM name MUST be displayed with .headline font style
- [ ] OS version MUST be displayed with .caption font style
- [ ] Status label MUST have a fixed width of 80pt
- [ ] Status label MUST be color-coded (see Status Colors below)
- [ ] Action buttons MUST be visible on the right side of the row

**When VM is not installed:**
- [ ] "Install" button MUST be visible instead of play circle

**When VM is installed and idle:**
- [ ] Play circle button MUST be visible

**When VM row has an ellipsis menu:**
- [ ] Ellipsis button MUST open the context menu

---

### Status Colors

**When VM status is "Running":**
- [ ] Status text MUST be green

**When VM status is "Paused":**
- [ ] Status text MUST be orange

**When VM status is any other state:**
- [ ] Status text MUST use secondary color

---

### Inline Rename

**When "Rename" is triggered from the context menu:**
- [ ] VM name MUST become an editable text field
- [ ] Pressing Return MUST commit the rename
- [ ] Pressing Escape MUST cancel the rename
- [ ] Clicking outside (blur) MUST cancel the rename

**When rename fails:**
- [ ] Error alert MUST be shown with the failure reason

---

### Context Menu

**When right-clicking a VM row:**
- [ ] "Install macOS" MUST be visible (when applicable)
- [ ] "Start" MUST be visible
- [ ] "Boot to Recovery" MUST be visible
- [ ] "Suspend" MUST be visible
- [ ] "Shut Down" MUST be visible
- [ ] "Terminate" MUST be visible
- [ ] "Edit Settings..." MUST be visible
- [ ] "Rename" MUST be visible
- [ ] "Clone" MUST be visible
- [ ] "Snapshots" submenu MUST be visible
- [ ] "Show in Finder" MUST be visible
- [ ] "Remove from List" MUST be visible
- [ ] "Delete" MUST be visible

**When VM is running:**
- [ ] "Start" MUST be disabled
- [ ] "Edit Settings..." MUST be disabled
- [ ] "Suspend" MUST be enabled
- [ ] "Shut Down" MUST be enabled
- [ ] "Terminate" MUST be enabled

**When VM is idle/stopped:**
- [ ] "Start" MUST be enabled
- [ ] "Edit Settings..." MUST be enabled
- [ ] "Suspend" MUST be disabled
- [ ] "Shut Down" MUST be disabled
- [ ] "Terminate" MUST be disabled

---

### VM Selection

**When clicking a VM row:**
- [ ] VM MUST become selected (highlighted)
- [ ] Only single selection MUST be supported (no multi-select)
- [ ] Selecting a VM MUST NOT trigger any automatic action (no auto-open)

---

### Drag-and-Drop Import

**When dragging files onto the VM list:**
- [ ] .ghostvm bundles MUST be accepted
- [ ] Non-.ghostvm files MUST be silently ignored
- [ ] Duplicate bundles (already in list) MUST be deduplicated
- [ ] Successfully imported VMs MUST appear in the list

---

### Alerts

**When deleting a VM:**
- [ ] Confirmation alert MUST be shown before deletion

**When reverting a snapshot:**
- [ ] Confirmation alert MUST be shown before revert

**When deleting a snapshot:**
- [ ] Confirmation alert MUST be shown before deletion

**When rename fails:**
- [ ] Error alert MUST display the failure reason

**When clone fails:**
- [ ] Error alert MUST display the failure reason

---

### Sheets

**When "Create" is triggered:**
- [ ] Create VM sheet MUST be presented

**When "Clone" is triggered:**
- [ ] Clone VM sheet MUST be presented

**When creating a snapshot:**
- [ ] Create Snapshot sheet MUST be presented

**When installing macOS on a VM:**
- [ ] Install VM sheet MUST be presented

---

### Menu Bar Commands

**When viewing the application menu:**
- [ ] "About GhostVM" MUST be available
- [ ] "Settings..." (Cmd+,) MUST be available
- [ ] "Check for Updates..." MUST be available

**When viewing the VM menu:**
- [ ] "Start" MUST be available
- [ ] "Clipboard Sync" submenu MUST be available
- [ ] "Suspend" MUST be available
- [ ] "Shut Down" MUST be available
- [ ] "Terminate" MUST be available

**When viewing the Window menu:**
- [ ] Standard window management commands MUST be available

---

### VM States

**Runtime states:**
- [ ] "Idle" MUST be a valid state (VM not running)
- [ ] "Starting" MUST be a valid state (VM booting)
- [ ] "Running" MUST be a valid state (VM active)
- [ ] "Suspending" MUST be a valid state (saving state)
- [ ] "Stopping" MUST be a valid state (shutting down)
- [ ] "Stopped" MUST be a valid state (graceful shutdown complete)
- [ ] "Failed" MUST be a valid state (error occurred)

**Disk-persisted states:**
- [ ] VM state MUST persist across app restarts
- [ ] A VM that was suspended MUST show as suspended after relaunch

---

### Window Management

**When managing windows:**
- [ ] Main window MUST be the VM list
- [ ] Settings window MUST open separately (Cmd+,)
- [ ] Restore Images window MUST open separately
- [ ] Each running VM MUST open in its own window

---

### Persistence

**When the app stores VM references:**
- [ ] Known VM bundles MUST be stored in UserDefaults key "SwiftUIKnownVMBundles"
- [ ] Bundles missing from disk MUST be silently dropped on load
- [ ] Adding a VM MUST persist to UserDefaults
- [ ] Removing a VM from the list MUST remove it from UserDefaults
