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

      <h3>list</h3>
      <p>
        List all VMs in the current root directory with their state. Running VMs
        show their socket path.
      </p>
      <CodeBlock language="bash">{`vmctl list`}</CodeBlock>

      <h3>start</h3>
      <p>Launch a VM.</p>
      <CodeBlock language="bash">
        {`vmctl start <bundle-path> [options]

Options:
  --headless             Run without a GUI window
  --shared-folder PATH   Host folder to share with guest
  --writable             Make shared folder writable (use with --shared-folder)
  --read-only            Make shared folder read-only (use with --shared-folder)`}
      </CodeBlock>

      <h3>stop</h3>
      <p>Graceful shutdown.</p>
      <CodeBlock language="bash">{`vmctl stop <bundle-path>`}</CodeBlock>

      <h3>status</h3>
      <p>Report running state and configuration.</p>
      <CodeBlock language="bash">{`vmctl status <bundle-path>`}</CodeBlock>

      <h3>resume</h3>
      <p>Resume from suspended state.</p>
      <CodeBlock language="bash">
        {`vmctl resume <bundle-path> [options]

Options:
  --headless             Run without a GUI window
  --shared-folder PATH   Host folder to share with guest
  --writable             Make shared folder writable (use with --shared-folder)
  --read-only            Make shared folder read-only (use with --shared-folder)`}
      </CodeBlock>

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

      <h3>socket</h3>
      <p>
        Print the Unix socket path for a running VM. Useful for command
        substitution with other tools.
      </p>
      <CodeBlock language="bash">{`vmctl socket <bundle-path>`}</CodeBlock>

      <h3>remote</h3>
      <p>
        Execute commands against a running VM via its Host API socket. Requires{" "}
        <code>--name</code> or <code>--socket</code> to identify the VM.
      </p>
      <CodeBlock language="bash">
        {`vmctl remote --name <VMName> [--json] <subcommand> [args...]
vmctl remote --socket <path> [--json] <subcommand> [args...]

Subcommands:
  health                     Check VM connection status
  exec <command> [args...]   Run a command in the guest
  clipboard get              Get guest clipboard contents
  clipboard set <text>       Set guest clipboard contents
  apps                       List running guest applications
  interactive                Start interactive REPL`}
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

      <CodeBlock language="bash" title="Remote commands">
        {`# Run a command inside the guest
vmctl remote --name dev exec uname -a

# Get the guest clipboard
vmctl remote --name dev clipboard get

# List running apps
vmctl remote --name dev apps

# Use socket path with command substitution
vmctl remote --socket $(vmctl socket ~/VMs/dev.GhostVM) interactive`}
      </CodeBlock>
      <PrevNextNav currentHref="/docs/cli" />
    </>
  );
}
