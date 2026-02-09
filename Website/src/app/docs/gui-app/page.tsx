import type { Metadata } from "next";
import PrevNextNav from "@/components/docs/PrevNextNav";

export const metadata: Metadata = { title: "GUI App - GhostVM Docs" };

export default function GUIApp() {
  return (
    <>
      <h1>GUI App</h1>
      <p className="lead">
        GhostVM.app is a native SwiftUI application for managing your virtual
        machines with a visual interface.
      </p>

      <h2>Main Window</h2>
      <p>
        The main window shows all registered VM bundles with their name, OS
        version, status, and custom icon. From here you can:
      </p>
      <ul>
        <li>
          <strong>Create</strong> new macOS VMs
        </li>
        <li>
          <strong>Start</strong> a VM by clicking the play button
        </li>
        <li>
          <strong>Drag and drop</strong> <code>.GhostVM</code> bundles to add
          them to the list
        </li>
        <li>
          Access the <strong>Images</strong> window to manage restore images
        </li>
      </ul>

      <h2>VM Window</h2>
      <p>
        When a VM is running, it opens in a dedicated window with a toolbar
        providing:
      </p>
      <ul>
        <li>
          <strong>Guest Tools status</strong> &mdash; green dot when GhostTools
          is connected
        </li>
        <li>
          <strong>Port Forwards</strong> &mdash; view and edit active port
          mappings
        </li>
        <li>
          <strong>Clipboard Sync</strong> &mdash; toggle sync mode
          (bidirectional, host-to-guest, guest-to-host, or disabled)
        </li>
        <li>
          <strong>File receive</strong> &mdash; accept files queued by the guest
        </li>
        <li>
          <strong>Shut Down / Terminate</strong> &mdash; graceful shutdown or
          force stop
        </li>
      </ul>

      <h2>Context Menu</h2>
      <p>
        Right-click any VM in the list to access additional actions:
      </p>
      <ul>
        <li>Start / Boot to Recovery</li>
        <li>Stop / Terminate</li>
        <li>Edit Settings (CPU, memory, disk, shared folders, port forwards)</li>
        <li>Snapshot management (create, revert, delete)</li>
        <li>Show in Finder / Remove from List / Delete</li>
      </ul>

      <h2>VM Menu</h2>
      <p>
        The <strong>VM</strong> menu in the menu bar provides keyboard shortcuts
        for common actions when a VM window is focused:
      </p>
      <table>
        <thead>
          <tr>
            <th>Action</th>
            <th>Shortcut</th>
          </tr>
        </thead>
        <tbody>
          <tr>
            <td>Start</td>
            <td>
              <kbd>Cmd+R</kbd>
            </td>
          </tr>
          <tr>
            <td>Suspend</td>
            <td>
              <kbd>Cmd+Option+S</kbd>
            </td>
          </tr>
          <tr>
            <td>Shut Down</td>
            <td>
              <kbd>Cmd+Option+Q</kbd>
            </td>
          </tr>
        </tbody>
      </table>

      <h2>Settings</h2>
      <p>
        Open Settings (<kbd>Cmd+,</kbd>) to configure:
      </p>
      <ul>
        <li>IPSW cache location</li>
        <li>IPSW feed URL (for discovering restore images)</li>
        <li>App icon style (System / Light / Dark)</li>
      </ul>

      <h2>Restore Images</h2>
      <p>
        The Restore Images window lists available macOS versions from the
        configured IPSW feed. You can download, resume, cancel, or delete
        restore images. Downloads include SHA-1 verification.
      </p>

      <PrevNextNav currentHref="/docs/gui-app" />
    </>
  );
}
