import type { Metadata } from "next";
import CodeBlock from "@/components/docs/CodeBlock";
import Callout from "@/components/docs/Callout";
import PrevNextNav from "@/components/docs/PrevNextNav";

export const metadata: Metadata = { title: "VM Bundles - GhostVM Docs" };

export default function VMBundles() {
  return (
    <>
      <h1>VM Bundles</h1>
      <p className="lead">
        GhostVM stores each virtual machine as a self-contained{" "}
        <code>.GhostVM</code> bundle — a macOS package (directory) that holds
        everything needed to run the VM.
      </p>

      <h2>Bundle Structure</h2>
      <CodeBlock language="bash">
        {`MyVM.GhostVM/
├── config.json          # VM configuration (CPU, memory, disk, etc.)
├── disk.img             # Main disk image (raw sparse file)
├── MachineIdentifier    # Unique hardware ID (macOS VMs)
├── HardwareModel        # Hardware model data (macOS VMs)
├── RestoreImage.ipsw    # macOS restore image (if attached)
├── AuxiliaryStorage     # NVRAM / EFI boot state
├── icon.png             # Custom VM icon (optional)
├── SavedState/          # Suspend/resume state (if suspended)
└── Snapshots/           # Named snapshots
    ├── clean-state/
    │   ├── disk.img
    │   └── SavedState/
    └── after-setup/
        ├── disk.img
        └── SavedState/`}
      </CodeBlock>

      <h2>Configuration (config.json)</h2>
      <p>
        The <code>config.json</code> file stores VM settings persisted between
        runs:
      </p>
      <CodeBlock language="json">
        {`{
  "cpus": 6,
  "memoryBytes": 17179869184,
  "diskBytes": 137438953472,
  "guestOSType": "macOS",
  "sharedFolders": [
    { "path": "/Users/jake/Shared", "readOnly": true }
  ],
  "portForwards": [
    { "hostPort": 8080, "guestPort": 80 }
  ]
}`}
      </CodeBlock>

      <h2>Disk Images</h2>
      <p>
        Disk images are raw sparse files. The default size is 256 GiB, but the
        file only consumes actual used space on the host filesystem. You can
        check actual disk usage with:
      </p>
      <CodeBlock language="bash">{`du -sh ~/VMs/MyVM.GhostVM/disk.img`}</CodeBlock>

      <Callout variant="info" title="Portability">
        Bundles are fully portable. You can copy, move, or back up a{" "}
        <code>.GhostVM</code> bundle to another Mac and it will work as-is
        (same architecture required).
      </Callout>

      <h2>Custom Icons</h2>
      <p>
        Each VM can have a custom icon stored as <code>icon.png</code> in the
        bundle root. The icon is shown in the VM list and in the Dock when the
        VM is running. You can set the icon from the Edit VM dialog in the GUI.
      </p>

      <PrevNextNav currentHref="/docs/vm-bundles" />
    </>
  );
}
