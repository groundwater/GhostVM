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
- Direct Apple Containerization diagnostics

Installation
------------

GhostTools is automatically installed to /Applications in the guest VM when
the GhostTools DMG is attached. It auto-updates when a newer version is
available from the host.

To install manually:

   sudo cp /Volumes/GhostTools/GhostTools.app /Applications/

The direct Containerization CLI can be run from the mounted DMG:

   /Volumes/GhostTools/bin/ghostbox --help

The Docker-like helper is packaged beside it:

   /Volumes/GhostTools/bin/ghostbox-docker --help

The Compose-compatible helper manages multi-container projects through that
Docker-like helper:

   /Volumes/GhostTools/bin/ghostbox-docker-compose config
   /Volumes/GhostTools/bin/ghostbox-docker-compose up -d
   /Volumes/GhostTools/bin/ghostbox-docker-compose ps
   /Volumes/GhostTools/bin/ghostbox-docker-compose logs -f
   /Volumes/GhostTools/bin/ghostbox-docker-compose down

It discovers compose.yaml, compose.yml, docker-compose.yaml, or
docker-compose.yml and supports image-based services, commands, entrypoints,
environment files and values, bind mounts, loopback TCP ports, dependencies,
and common process settings. Builds, named volumes, custom networks,
service-name DNS, health checks, and scaling are not implemented. The helper
uses the system /usr/bin/ruby YAML parser.

Ghostbox Direct API
-------------------

`ghostbox` exposes direct, source-shaped Apple Containerization operations. It
does not provide compatibility fallback commands. `ghostbox-docker` separately
composes these operations into Docker-like `build`, `pull`, and foreground
`run --rm` workflows. Currently implemented direct operations are listed by:

   ghostbox --help

Examples:

   ghostbox cn:kernel:default
   ghostbox cn:dns:default-nameservers
   ghostbox cn:dns:create dev --nameserver 1.1.1.1
   ghostbox cn:dns:resolv-conf @dns/dev
   ghostbox cn:process-config:default-path
   ghostbox cn:container:default-masked-paths

Guest-backed process I/O uses explicit resources and remains independent from
container lifecycle operations:

   ghostbox cn:reader-stream:create job-input
   ghostbox cn:writer:create job-output
   ghostbox cn:process-config:create job /bin/sh \
       --stdin @reader-stream/job-input --stdout @writer/job-output
   producer | ghostbox cn:reader-stream:attach @reader-stream/job-input &
   ghostbox cn:writer:attach @writer/job-output | consumer &

Start attachments before the process to avoid filling their bounded transport
buffers. Close a writer after the corresponding process wait completes so its
attachment emits EOF. For an interactive PTY, create a terminal, pass it to
`cn:process-config:set-terminal-io`, and keep the following attachment in the
foreground while the lifecycle controller waits and then closes the terminal:

   ghostbox cn:terminal:attach @terminal/NAME --resize-target @container/NAME

Terminal attach requires a real TTY and forwards raw input, output, and
window-size changes. A lifecycle controller in another process can block on
`ghostbox cn:terminal:wait-attached @terminal/NAME` before starting the process.

The outer Mac must be Apple silicon. In GhostVM, open Edit Settings for this VM,
select NAT (Shared), and enable Host-backed Containers before starting the VM.

Enabling the bridge grants any process in the guest permission to request
host-side Containerization operations. Unsupported direct operations fail
explicitly; they are never translated to a legacy one-shot request.

`cn:kernel:default` is a GhostVM host extension backed by Apple container's
configured default Linux ARM kernel. See `examples/ghostbox` for scripts that
compose it with the direct manager, container, process, and I/O APIs.

GhostTools requires Accessibility permission in the guest to enable pointer,
keyboard, and UI automation features. Grant this in System Settings > Privacy &
Security > Accessibility.

Requirements
------------

- macOS 14.0 or later (running as a guest in GhostVM)
