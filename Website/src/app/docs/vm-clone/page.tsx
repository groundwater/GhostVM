import type { Metadata } from "next";
import CodeBlock from "@/components/docs/CodeBlock";
import Callout from "@/components/docs/Callout";
import PrevNextNav from "@/components/docs/PrevNextNav";

export const metadata: Metadata = { title: "VM Clone - GhostVM Docs" };

export default function VMClone() {
  return (
    <>
      <h1>VM Clone</h1>
      <p className="lead">
        Duplicate an existing workspace instantly using APFS copy-on-write.
        The clone gets a fresh identity but shares disk blocks with the
        original, so it uses near-zero additional disk space.
      </p>

      <h2>Overview</h2>
      <p>
        Cloning uses the macOS <code>clonefile()</code> system call to create
        APFS copy-on-write copies of the VM&apos;s disk image, hardware model,
        and auxiliary storage. Only blocks that are subsequently modified in
        either the original or the clone consume additional disk space.
      </p>

      <h2>What Gets Cloned vs. Regenerated</h2>
      <table>
        <thead>
          <tr>
            <th>Item</th>
            <th>Behavior</th>
          </tr>
        </thead>
        <tbody>
          <tr>
            <td>Disk image</td>
            <td>APFS COW clone (shared blocks)</td>
          </tr>
          <tr>
            <td>Hardware model</td>
            <td>APFS COW clone</td>
          </tr>
          <tr>
            <td>Auxiliary storage</td>
            <td>APFS COW clone</td>
          </tr>
          <tr>
            <td>Machine identifier</td>
            <td>Regenerated (new unique ID)</td>
          </tr>
          <tr>
            <td>MAC address</td>
            <td>Regenerated (new random address)</td>
          </tr>
          <tr>
            <td>config.json</td>
            <td>New file with same hardware settings, cleared per-instance state</td>
          </tr>
          <tr>
            <td>Shared folders</td>
            <td>Not carried over (cleared)</td>
          </tr>
          <tr>
            <td>Port forwards</td>
            <td>Not carried over (cleared)</td>
          </tr>
          <tr>
            <td>Snapshots</td>
            <td>Not carried over (empty directory)</td>
          </tr>
          <tr>
            <td>Suspend state</td>
            <td>Not carried over (clone boots fresh)</td>
          </tr>
        </tbody>
      </table>

      <h2>GUI Usage</h2>
      <p>
        Right-click any stopped VM in the main window and select{" "}
        <strong>Clone</strong>. You&apos;ll be prompted to enter a name for
        the new workspace. The clone appears in the VM list immediately.
      </p>

      <h2>Disk Efficiency</h2>
      <p>
        Because APFS copy-on-write shares underlying data blocks, cloning a
        64 GiB VM takes only milliseconds and uses almost no additional disk
        space initially. As you modify files inside the original or clone,
        only the changed blocks diverge and consume real storage.
      </p>
      <p>
        This makes cloning ideal for creating throwaway test environments,
        templating workflows, or spinning up multiple variations of a base
        workspace.
      </p>

      <Callout variant="warning" title="Stop the VM first">
        The source VM must be stopped before cloning. Cloning a running VM
        would produce an inconsistent disk image. The CLI and GUI both enforce
        this requirement.
      </Callout>

      <Callout variant="info" title="APFS Required">
        Copy-on-write cloning requires an APFS volume. If your VMs are stored
        on a non-APFS volume (e.g., external HFS+ drive), the clone will fail.
        Move your VMs to an APFS volume first.
      </Callout>

      <PrevNextNav currentHref="/docs/vm-clone" />
    </>
  );
}
