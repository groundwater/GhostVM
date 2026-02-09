import type { Metadata } from "next";
import PrevNextNav from "@/components/docs/PrevNextNav";

export const metadata: Metadata = { title: "Clipboard Sync - GhostVM Docs" };

export default function ClipboardSync() {
  return (
    <>
      <h1>Clipboard Sync</h1>
      <p className="lead">
        Clipboard sync enables seamless copy-paste between your Mac and the
        guest VM. Copy text on your Mac and paste it inside the VM, or vice
        versa.
      </p>

      <h2>Sync Modes</h2>
      <p>
        Clipboard sync supports four modes, configurable from the VM toolbar or
        the VM menu:
      </p>
      <table>
        <thead>
          <tr>
            <th>Mode</th>
            <th>Description</th>
          </tr>
        </thead>
        <tbody>
          <tr>
            <td>Bidirectional</td>
            <td>
              Sync clipboard in both directions. Changes on either side are
              reflected on the other.
            </td>
          </tr>
          <tr>
            <td>Host → Guest</td>
            <td>
              Only push clipboard from host to guest. Guest clipboard changes
              are not synced back.
            </td>
          </tr>
          <tr>
            <td>Guest → Host</td>
            <td>
              Only pull clipboard from guest to host. Host clipboard changes
              are not pushed.
            </td>
          </tr>
          <tr>
            <td>Disabled</td>
            <td>No clipboard syncing.</td>
          </tr>
        </tbody>
      </table>

      <h2>How it Works</h2>
      <p>
        Clipboard sync is event-driven — it activates when the VM window gains
        or loses focus, rather than polling continuously. This ensures minimal
        overhead.
      </p>
      <ul>
        <li>
          When the VM window <strong>gains focus</strong>: host clipboard is
          pushed to guest (if mode allows)
        </li>
        <li>
          When the VM window <strong>loses focus</strong>: guest clipboard is
          pulled to host (if mode allows)
        </li>
      </ul>

      <h2>Persistence</h2>
      <p>
        The selected sync mode is persisted per-VM in UserDefaults and restored
        automatically when the VM is started again.
      </p>

      <h2>Requirements</h2>
      <p>
        Clipboard sync requires{" "}
        <a href="/docs/ghosttools">GhostTools</a> to be running inside the
        guest VM. The Guest Tools indicator in the VM toolbar shows connection
        status.
      </p>

      <PrevNextNav currentHref="/docs/services/clipboard-sync" />
    </>
  );
}
