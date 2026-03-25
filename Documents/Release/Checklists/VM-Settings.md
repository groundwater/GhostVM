# Release Checklist

Testable assertions for every feature and invariant. Format: `When X: Y MUST Z`.

---

## VM Settings Page

### Application Settings (Cmd+,)

**When opening application settings:**
- [ ] Cmd+, MUST open the Settings window
- [ ] GhostVM menu > Settings... MUST open the Settings window
- [ ] Settings window MUST have minimum size 520x320

**When viewing VMs Folder setting:**
- [ ] Text field MUST show current VMs folder path (default: ~/VMs)
- [ ] "Browse..." button MUST be visible

**When viewing IPSW Cache setting:**
- [ ] Text field MUST show current IPSW cache directory path

**When viewing IPSW Feed URL setting:**
- [ ] Text field MUST show current feed URL
- [ ] "Verify" button MUST be visible
- [ ] Clicking "Verify" MUST disable the button during verification
- [ ] Successful verification MUST show green checkmark + "Feed verified successfully."
- [ ] Failed verification MUST show orange warning icon + error message

**When viewing App Icon Mode setting:**
- [ ] Picker MUST show three options: System, Light, Dark
- [ ] Changing selection MUST update the Dock icon appearance

**When Sparkle updater is available:**
- [ ] "Automatically check for updates" toggle MUST be visible
- [ ] Toggle MUST reflect current updater setting
- [ ] Changing toggle MUST persist to Sparkle configuration

**When Sparkle updater is NOT available:**
- [ ] "Automatically check for updates" toggle MUST NOT be shown

---

### Per-VM Settings (EditVMView)

**When VM is running:**
- [ ] "Edit Settings..." context menu item MUST be disabled
- [ ] User MUST NOT be able to open the edit settings sheet

**When VM is stopped:**
- [ ] "Edit Settings..." context menu item MUST be enabled
- [ ] Clicking it MUST open the edit settings sheet

**When edit settings sheet opens:**
- [ ] Title MUST read "Edit [VM Name]"
- [ ] Sheet MUST show loading spinner while config loads
- [ ] After loading, CPU field MUST show current vCPU count
- [ ] After loading, Memory field MUST show current memory in GiB
- [ ] After loading, Disk field MUST show current disk size in GiB
- [ ] Shared folders list MUST show all configured shared folders
- [ ] Port forwards list MUST show all configured port forwards
- [ ] Info banner MUST read "Changes will take effect the next time you start the VM."
- [ ] Sheet minimum width MUST be 620

**When editing CPU count:**
- [ ] Text field MUST accept numeric input
- [ ] Default value MUST be 4 if not previously set
- [ ] Field MUST have max width 120
- [ ] "cores" label MUST be visible next to field

**When editing Memory:**
- [ ] Text field MUST accept numeric input
- [ ] Default value MUST be 8 if not previously set
- [ ] Field MUST have max width 120
- [ ] "GiB" label MUST be visible next to field

**When editing Disk size:**
- [ ] Text field MUST accept numeric input
- [ ] Field MUST have max width 120
- [ ] "GiB" label MUST be visible next to field

---

### Icon Selection

**When selecting icon mode:**
- [ ] Five icon tiles MUST be visible: Generic, Glass, Application, Stack, Custom
- [ ] Selecting Generic MUST clear custom icon and icon mode
- [ ] Selecting Glass MUST set glass icon mode
- [ ] Selecting Application MUST set app icon mode
- [ ] Selecting Stack MUST set dynamic/stack icon mode
- [ ] Selecting Custom MUST open icon popover

**When Custom icon popover is open:**
- [ ] Preset icon grid MUST show (4 columns): Hipster, Nerd, 80s Bro, Terminal, Quill, Typewriter, Kernel, Banana, Papaya, Daemon
- [ ] "Upload" button MUST be visible
- [ ] Upload dialog MUST accept: PNG, JPEG, TIFF, HEIC
- [ ] Drag and drop MUST be supported on the icon tile

**When saving icon:**
- [ ] Custom icon MUST be saved as icon.png in VM bundle
- [ ] Finder icon MUST be updated via NSWorkspace.shared.setIcon()
- [ ] Icon mode MUST be persisted in config.json

---

### Shared Folders

**When no shared folders exist:**
- [ ] Placeholder text "No shared folders" MUST be shown

**When adding a shared folder:**
- [ ] "Add Folder..." button MUST open NSOpenPanel for directory selection
- [ ] "Read Only" checkbox MUST default to checked (true)
- [ ] Duplicate paths MUST be rejected
- [ ] Added folder MUST appear in list with folder icon, name, and full path

**When viewing shared folder list:**
- [ ] Each entry MUST show folder icon, display name, and full path
- [ ] Read-only folders MUST show "Read Only" badge
- [ ] Remove button (-) MUST be visible on each entry
- [ ] Remove button MUST turn red on hover

**When saving shared folders:**
- [ ] Paths MUST be normalized (tilde expansion, absolute resolution)
- [ ] Legacy single-folder config MUST be migrated to array format on load

---

### Port Forwards (Settings Sheet)

**When no port forwards exist:**
- [ ] Placeholder text "No port forwards" MUST be shown

**When adding a port forward:**
- [ ] Host port field MUST be visible (placeholder "Host port", max width 80)
- [ ] Guest port field MUST be visible (placeholder "Guest port", max width 80)
- [ ] Arrow icon MUST separate host and guest fields
- [ ] "Add" button MUST be disabled until both ports are entered
- [ ] Tab/Return MUST advance focus between fields
- [ ] Host port MUST be validated as UInt16 > 0
- [ ] Guest port MUST be validated as UInt16 > 0
- [ ] Duplicate host ports MUST show error "Host port X already in use"

**When viewing port forward list:**
- [ ] Each entry MUST show format: `localhost:XXXX -> guest:XXXX` (monospace)
- [ ] Remove button (-) MUST be visible on each entry
- [ ] Remove button MUST turn red on hover

---

### Save / Cancel Behavior

**When pressing Cancel (or Esc):**
- [ ] Sheet MUST close without saving changes
- [ ] Esc keyboard shortcut MUST trigger cancel

**When pressing Save (or Enter):**
- [ ] Enter/Return keyboard shortcut MUST trigger save
- [ ] Save button MUST be disabled while saving
- [ ] Save button MUST be disabled while loading
- [ ] On success: sheet MUST close
- [ ] On failure: alert "Unable to Save Settings" MUST show with error message
- [ ] Config modifiedAt timestamp MUST be updated

**When config is saved:**
- [ ] CPU count MUST persist to config.json
- [ ] Memory (converted to bytes) MUST persist to config.json
- [ ] Shared folders MUST persist to config.json
- [ ] Port forwards MUST persist to config.json (only valid entries with both ports > 0)
- [ ] Icon mode MUST persist to config.json
- [ ] Config file MUST use atomic writes

---

### Runtime Settings (VM Running)

**When VM is running - Port Forwards toolbar:**
- [ ] "Ports" toolbar button MUST be visible
- [ ] Button MUST show count of active forwards (if any)
- [ ] Clicking MUST open port forward editor popover (width 300)
- [ ] Adding a forward at runtime MUST take effect immediately
- [ ] Removing a forward at runtime MUST take effect immediately
- [ ] Runtime errors MUST display in red with "Dismiss" button
- [ ] Quick-copy buttons MUST show `localhost:HOST -> guest:GUEST` for each forward
- [ ] Clicking quick-copy MUST copy `http://localhost:PORT` to clipboard

**When VM is running - Clipboard Sync:**
- [ ] Clipboard sync menu MUST be in toolbar
- [ ] Four modes MUST be available: Bidirectional, Host to Guest, Guest to Host, Disabled
- [ ] Current mode MUST show checkmark
- [ ] Icon MUST change based on mode (arrows for directions, clipboard for disabled)
- [ ] Mode change MUST persist to UserDefaults (key: `clipboardSyncMode_<hash>`)
- [ ] Sync MUST be event-driven on window focus/blur (no polling)

**When VM is running - File Transfer:**
- [ ] File transfer indicator MUST only appear when files are queued from guest
- [ ] Button MUST show count of pending files
- [ ] Clicking MUST trigger fetchAllGuestFiles()

---

### Keyboard Shortcuts

- [ ] Cmd+, MUST open application settings
- [ ] Cmd+R MUST start VM (when VM window active)
- [ ] Cmd+Option+S MUST suspend VM (when VM window active)
- [ ] Cmd+Option+Q MUST shut down VM gracefully (when VM window active)
