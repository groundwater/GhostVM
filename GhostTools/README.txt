GhostTools - Guest Agent for GhostVM
=====================================

GhostTools is a guest agent that enables enhanced features when running
inside a GhostVM virtual machine, including:

- Clipboard synchronization between host and guest
- File transfer support via drag-and-drop

Installation
------------

1. Copy GhostTools to /usr/local/bin in your guest VM:

   sudo cp /Volumes/GhostTools/GhostTools /usr/local/bin/
   sudo chmod +x /usr/local/bin/GhostTools

2. Run GhostTools to start the guest agent:

   /usr/local/bin/GhostTools

3. (Optional) To start GhostTools automatically at login, add it to your
   Login Items in System Settings > General > Login Items.

Usage
-----

GhostTools runs as a background service listening for requests from the
host. Once running, features like clipboard sync will work automatically
when enabled in GhostVM's VM menu.

Requirements
------------

- macOS 14.0 or later (running as a guest in GhostVM)

For more information, visit: https://github.com/groundwater/GhostVM
