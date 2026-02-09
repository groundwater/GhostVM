import type { Metadata } from "next";
import CodeBlock from "@/components/docs/CodeBlock";
import Callout from "@/components/docs/Callout";
import PrevNextNav from "@/components/docs/PrevNextNav";

export const metadata: Metadata = { title: "macOS VMs - GhostVM Docs" };

export default function MacOSVMs() {
  return (
    <>
      <h1>Creating macOS VMs</h1>
      <p className="lead">
        macOS VMs are created from IPSW restore images and require a two-step
        process: initialization and installation.
      </p>

      <h2>Step 1: Initialize the VM bundle</h2>
      <CodeBlock language="bash">
        {`vmctl init ~/VMs/sandbox.GhostVM \\
  --cpus 6 \\
  --memory 16 \\
  --disk 128 \\
  --restore-image ~/Downloads/UniversalMac_15.2_Restore.ipsw`}
      </CodeBlock>
      <p>Options:</p>
      <table>
        <thead>
          <tr>
            <th>Option</th>
            <th>Default</th>
            <th>Description</th>
          </tr>
        </thead>
        <tbody>
          <tr>
            <td><code>--cpus</code></td>
            <td>4</td>
            <td>Number of virtual CPUs</td>
          </tr>
          <tr>
            <td><code>--memory</code></td>
            <td>8</td>
            <td>Memory in GiB</td>
          </tr>
          <tr>
            <td><code>--disk</code></td>
            <td>64</td>
            <td>Disk size in GiB (sparse file)</td>
          </tr>
          <tr>
            <td><code>--restore-image</code></td>
            <td>auto</td>
            <td>Path to IPSW file</td>
          </tr>
          <tr>
            <td><code>--shared-folder</code></td>
            <td>&mdash;</td>
            <td>Host folder to share with guest</td>
          </tr>
          <tr>
            <td><code>--writable</code></td>
            <td>false</td>
            <td>Make shared folder writable</td>
          </tr>
        </tbody>
      </table>

      <h2>Step 2: Install macOS</h2>
      <CodeBlock language="bash">{`vmctl install ~/VMs/sandbox.GhostVM`}</CodeBlock>
      <p>
        This installs macOS from the restore image onto the VM&apos;s disk.
        Installation takes several minutes and shows progress.
      </p>

      <h2>Step 3: Start the VM</h2>
      <CodeBlock language="bash">{`vmctl start ~/VMs/sandbox.GhostVM`}</CodeBlock>

      <Callout variant="info" title="Restore Image Discovery">
        If you don&apos;t specify <code>--restore-image</code>, GhostVM
        auto-discovers IPSW files from <code>~/Downloads/*.ipsw</code> and{" "}
        <code>/Applications/Install macOS*.app</code>.
      </Callout>

      <h2>Using the GUI</h2>
      <ol>
        <li>Click <strong>Create</strong> in the main window</li>
        <li>Select &ldquo;macOS&rdquo; as the guest OS</li>
        <li>Configure CPU, memory, and disk</li>
        <li>Select a restore image from the dropdown</li>
        <li>Optionally add shared folders</li>
        <li>Click <strong>Create</strong>, then <strong>Install</strong></li>
      </ol>

      <Callout variant="warning">
        Apple&apos;s EULA requires macOS guests to run on Apple-branded
        hardware.
      </Callout>

      <PrevNextNav currentHref="/docs/creating-vms/macos" />
    </>
  );
}
