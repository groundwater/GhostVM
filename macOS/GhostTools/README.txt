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
- Experimental host-backed Apple container execution

Installation
------------

GhostTools is automatically installed to /Applications in the guest VM
when the GhostTools DMG is attached. It auto-updates when a newer version
is available from the host.

To install manually:

   sudo cp /Volumes/GhostTools/GhostTools.app /Applications/

The experimental container CLI can be run directly from the mounted DMG:

   /Volumes/GhostTools/ghost-container run alpine echo hello

Host-backed Containers
----------------------

This feature runs ephemeral Linux containers on the outer Mac through Apple's
container tool. It currently supports only:

   ghost-container run IMAGE [COMMAND...]

The outer Mac must be Apple silicon running macOS 26 or later, with Apple's
container tool installed at /usr/local/bin/container and its system service
started. Enable the experimental bridge before starting the GhostVM:

   defaults write org.ghostvm.ghostvm.helper HostContainersEnabled -bool true

Restart the VM after changing this setting. The setting applies to every
GhostVM for the current host user. Disable it with:

   defaults delete org.ghostvm.ghostvm.helper HostContainersEnabled

Enabling the bridge grants any process in the guest permission to request the
limited host-side container run operation. Images are pulled using the host
user's Apple container registry access and remain in the host image store after
the ephemeral container exits, so private registry access and disk usage are
part of this trust grant. Host paths, environment variables, mounts, builds,
ports, interactive terminals, and persistent containers are not supported.

GhostTools requires Accessibility permission in the guest to enable
pointer, keyboard, and UI automation features. Grant this in
System Settings > Privacy & Security > Accessibility.

Requirements
------------

- macOS 14.0 or later (running as a guest in GhostVM)
