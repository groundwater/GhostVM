import type { Metadata } from "next";
import CodeBlock from "@/components/docs/CodeBlock";
import Callout from "@/components/docs/Callout";
import PrevNextNav from "@/components/docs/PrevNextNav";

export const metadata: Metadata = { title: "Snapshots - GhostVM Docs" };

export default function Snapshots() {
  return (
    <>
      <h1>Snapshots</h1>
      <p className="lead">
        Snapshots capture the full VM state — including disk — at a point in
        time. You can revert to a snapshot to restore the VM to its exact
        previous state.
      </p>

      <h2>CLI Usage</h2>

      <h3>List Snapshots</h3>
      <CodeBlock language="bash">{`vmctl snapshot ~/VMs/dev.GhostVM list`}</CodeBlock>

      <h3>Create a Snapshot</h3>
      <CodeBlock language="bash">{`vmctl snapshot ~/VMs/dev.GhostVM create clean-state`}</CodeBlock>
      <Callout variant="info">
        Creating a snapshot copies the full disk image, so it may take a while
        for large disks. The VM should be stopped before creating a snapshot.
      </Callout>

      <h3>Revert to a Snapshot</h3>
      <CodeBlock language="bash">{`vmctl snapshot ~/VMs/dev.GhostVM revert clean-state`}</CodeBlock>
      <Callout variant="warning">
        Reverting replaces the current disk image and saved state with the
        snapshot. Current state will be lost.
      </Callout>

      <h3>Delete a Snapshot</h3>
      <CodeBlock language="bash">{`vmctl snapshot ~/VMs/dev.GhostVM delete clean-state`}</CodeBlock>

      <h2>GUI Usage</h2>
      <p>
        In the GUI, right-click a VM and open the <strong>Snapshots</strong>{" "}
        submenu to:
      </p>
      <ul>
        <li>
          <strong>Create Snapshot</strong> — opens a dialog to name the snapshot
        </li>
        <li>
          <strong>Revert</strong> — select a snapshot to restore (with
          confirmation)
        </li>
        <li>
          <strong>Delete</strong> — permanently remove a snapshot
        </li>
      </ul>

      <h2>Storage</h2>
      <p>
        Snapshots are stored inside the VM bundle under the{" "}
        <code>Snapshots/</code> directory. Each snapshot is a subdirectory
        containing a copy of the disk image and saved state.
      </p>
      <CodeBlock language="bash">
        {`MyVM.GhostVM/
└── Snapshots/
    ├── clean-state/
    │   ├── disk.img
    │   └── SavedState/
    └── after-setup/
        ├── disk.img
        └── SavedState/`}
      </CodeBlock>

      <PrevNextNav currentHref="/docs/snapshots" />
    </>
  );
}
