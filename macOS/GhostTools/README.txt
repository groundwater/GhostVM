GhostTools - Guest Agent for GhostVM
=====================================

GhostTools is a guest agent that runs inside a GhostVM virtual machine,
enabling enhanced host-guest integration:

- Clipboard synchronization between host and guest
- File transfer via drag-and-drop (bidirectional)
- URL forwarding (guest links open on host)
- Port scanning and auto-discovery
- Accessibility tree inspection and UI automation
- Pointer and keyboard input injection
- Screenshot capture with element overlays
- Log streaming to host

Installation
------------

GhostTools is automatically installed to /Applications in the guest VM
when the GhostTools DMG is attached. It auto-updates when a newer version
is available from the host.

To install manually:

   sudo cp /Volumes/GhostTools/GhostTools.app /Applications/

GhostTools requires Accessibility permission in the guest to enable
pointer, keyboard, and UI automation features. Grant this in
System Settings > Privacy & Security > Accessibility.

Requirements
------------

- macOS 14.0 or later (running as a guest in GhostVM)
