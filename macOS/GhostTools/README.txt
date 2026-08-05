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

The native container CLI can be run directly from the mounted DMG:

   /Volumes/GhostTools/bin/ghostbox run registry-1.docker.io/library/alpine:latest echo hello

Host-backed Containers
----------------------

Ghostbox runs ephemeral Linux containers on the outer Mac through Apple's
Containerization framework. It supports:

   ghostbox run IMAGE [COMMAND...]
   ghostbox run -it IMAGE [COMMAND...]
   ghostbox run -v /guest/path:/container/path[:ro|rw] IMAGE [COMMAND...]
   ghostbox run -p 8080:80 -e MODE=production -w /app IMAGE
   ghostbox run -u 1000:1000 --cpus 2 --memory 1g IMAGE

Use -i to attach stdin and -t to allocate a terminal. Combined -it sessions
support terminal resize events and Ctrl-C through the container PTY. Alpine
images provide /bin/sh by default:

   ghostbox run -it registry-1.docker.io/library/alpine:latest /bin/sh

Published ports currently support TCP and bind to the guest's 127.0.0.1 by
default. Provide an explicit guest IPv4 address before the host port to change
the bind address.

The outer Mac must be Apple silicon. In GhostVM, open Edit Settings for this VM,
select NAT (Shared), and enable Host-backed Containers before starting the VM.
Guest directory mounts additionally require macOS 26 or later and the GhostVM
file system extension enabled under System Settings > General > Login Items &
Extensions > File System Extensions. Restart the VM after changing the setting.

Enabling the bridge grants any process in the guest permission to request the
limited host-side container run operation. Images are pulled using the host
user's registry access and remain in the host image store after the ephemeral
container exits, so private registry access and disk usage are part of this
trust grant. Volumes expose the requested guest directory to the container and
default to read-write; append `:ro` for a read-only mount. Outer-host paths,
builds, and persistent containers are not supported.

GhostTools requires Accessibility permission in the guest to enable
pointer, keyboard, and UI automation features. Grant this in
System Settings > Privacy & Security > Accessibility.

Requirements
------------

- macOS 14.0 or later (running as a guest in GhostVM)
