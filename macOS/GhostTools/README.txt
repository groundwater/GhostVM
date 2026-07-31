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

   /Volumes/GhostTools/ghost-container run registry-1.docker.io/library/alpine:latest echo hello

Host-backed Containers
----------------------

This feature runs ephemeral Linux containers on the outer Mac through Apple's
Containerization framework. It currently supports:

   ghost-container run IMAGE [COMMAND...]
   ghost-container run -it IMAGE [COMMAND...]
   ghost-container run -v /guest/path:/container/path:ro IMAGE [COMMAND...]

Use -i to attach stdin and -t to allocate a terminal. Combined -it sessions
support terminal resize events and Ctrl-C through the container PTY. Alpine
images provide /bin/sh by default:

   ghost-container run -it registry-1.docker.io/library/alpine:latest /bin/sh

The outer Mac must be Apple silicon. In GhostVM, open Edit Settings for this VM,
select NAT (Shared), and enable Host-backed Containers before starting the VM.
Guest directory mounts additionally require macOS 26 or later and the GhostVM
file system extension enabled under System Settings > General > Login Items &
Extensions > File System Extensions. Restart the VM after changing the setting.

Enabling the bridge grants any process in the guest permission to request the
limited host-side container run operation. Images are pulled using the host
user's registry access and remain in the host image store after the ephemeral
container exits, so private registry access and disk usage are part of this
trust grant. A read-only volume exposes only the requested guest directory to
the container. Outer-host paths, read-write mounts, builds, ports, and
persistent containers are not supported.

GhostTools requires Accessibility permission in the guest to enable
pointer, keyboard, and UI automation features. Grant this in
System Settings > Privacy & Security > Accessibility.

Requirements
------------

- macOS 14.0 or later (running as a guest in GhostVM)
