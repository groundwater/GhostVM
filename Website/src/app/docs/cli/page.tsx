import type { Metadata } from "next";
import CodeBlock from "@/components/docs/CodeBlock";
import PrevNextNav from "@/components/docs/PrevNextNav";

export const metadata: Metadata = { title: "CLI Reference - GhostVM Docs" };

export default function CLIReference() {
  return (
    <>
      <h1>CLI Reference</h1>
      <p className="lead">
        The <code>vmctl</code> command-line tool provides full control over
        GhostVM virtual machines from the terminal.
      </p>

      <CodeBlock language="bash">{`vmctl --help`}</CodeBlock>

      <h2>macOS VM Commands</h2>

      <h3>init</h3>
      <p>Create a new macOS VM bundle.</p>
      <CodeBlock language="bash">
        {`vmctl init <bundle-path> [options]

Options:
  --cpus N              Number of virtual CPUs (default: 4)
  --memory GiB          Memory in GiB (default: 8)
  --disk GiB            Disk size in GiB (default: 64)
  --restore-image PATH  Path to IPSW restore image
  --shared-folder PATH  Host folder to share with guest
  --writable            Make shared folder writable`}
      </CodeBlock>

      <h3>install</h3>
      <p>Install macOS from the restore image in the VM bundle.</p>
      <CodeBlock language="bash">{`vmctl install <bundle-path>`}</CodeBlock>

      <h2>Common Commands</h2>

      <h3>clone</h3>
      <p>
        Duplicate a VM using APFS copy-on-write. The clone gets a fresh machine
        identity and MAC address. Near-zero disk overhead.
      </p>
      <CodeBlock language="bash">{`vmctl clone <source-bundle> <new-name>`}</CodeBlock>

      <h3>start</h3>
      <p>Launch a VM.</p>
      <CodeBlock language="bash">
        {`vmctl start <bundle-path> [options]

Options:
  --recovery             Boot to Recovery mode`}
      </CodeBlock>

      <h3>stop</h3>
      <p>Graceful shutdown.</p>
      <CodeBlock language="bash">{`vmctl stop <bundle-path>`}</CodeBlock>

      <h3>status</h3>
      <p>Report running state and configuration.</p>
      <CodeBlock language="bash">{`vmctl status <bundle-path>`}</CodeBlock>

      <h3>resume</h3>
      <p>Resume from suspended state.</p>
      <CodeBlock language="bash">{`vmctl resume <bundle-path>`}</CodeBlock>

      <h3>discard-suspend</h3>
      <p>Discard the suspended state so the VM boots fresh.</p>
      <CodeBlock language="bash">{`vmctl discard-suspend <bundle-path>`}</CodeBlock>

      <h3>snapshot</h3>
      <p>Manage VM snapshots.</p>
      <CodeBlock language="bash">
        {`vmctl snapshot <bundle-path> list
vmctl snapshot <bundle-path> create <name>
vmctl snapshot <bundle-path> revert <name>
vmctl snapshot <bundle-path> delete <name>`}
      </CodeBlock>

      <h2>Examples</h2>
      <CodeBlock language="bash" title="Full macOS workflow">
        {`# Create and install a macOS VM
vmctl init ~/VMs/dev.GhostVM --cpus 6 --memory 16 --disk 128
vmctl install ~/VMs/dev.GhostVM
vmctl start ~/VMs/dev.GhostVM

# Create a checkpoint
vmctl snapshot ~/VMs/dev.GhostVM create clean-state

# Later: revert to clean state
vmctl snapshot ~/VMs/dev.GhostVM revert clean-state`}
      </CodeBlock>

      <CodeBlock language="bash" title="Clone and automate">
        {`# Clone an existing workspace
vmctl clone ~/VMs/dev.GhostVM staging
vmctl start ~/VMs/staging.GhostVM

# Run a command inside the guest
vmctl remote staging exec 'uname -a'`}
      </CodeBlock>
      <PrevNextNav currentHref="/docs/cli" />
    </>
  );
}
