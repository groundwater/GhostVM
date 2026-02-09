import type { Metadata } from "next";
import CodeBlock from "@/components/docs/CodeBlock";
import Callout from "@/components/docs/Callout";
import PrevNextNav from "@/components/docs/PrevNextNav";

export const metadata: Metadata = { title: "Getting Started - GhostVM Docs" };

export default function GettingStarted() {
  return (
    <>
      <h1>Getting Started</h1>
      <p className="lead">
        GhostVM is a native macOS app and CLI tool for provisioning and managing
        macOS virtual machines on Apple Silicon using Apple&apos;s
        Virtualization.framework.
      </p>

      <h2>Requirements</h2>
      <ul>
        <li>macOS 15+ (Sequoia) on Apple Silicon (M1 or later)</li>
        <li>Xcode 15+ and XcodeGen for building from source</li>
      </ul>

      <h2>Installation</h2>
      <p>
        Download the latest DMG from the{" "}
        <a href="https://github.com/groundwater/GhostVM/releases/latest">
          releases page
        </a>
        , open it, and drag GhostVM.app into your Applications folder.
      </p>
      <p>Or build from source:</p>
      <CodeBlock language="bash">
        {`brew install xcodegen
git clone https://github.com/groundwater/GhostVM
cd GhostVM
make app`}
      </CodeBlock>

      <h2>Create your first VM</h2>

      <h3>Using the GUI</h3>
      <ol>
        <li>
          Open GhostVM.app and click <strong>Images</strong> to open the Restore
          Images window.
        </li>
        <li>Download a macOS restore image (IPSW).</li>
        <li>
          Click <strong>Create</strong> in the main window, configure CPU,
          memory, and disk, and select the restore image.
        </li>
        <li>
          The VM bundle will be created. Click <strong>Install</strong> to
          install macOS.
        </li>
        <li>
          Once installed, click the play button to start your VM.
        </li>
      </ol>

      <h3>Using the CLI</h3>
      <CodeBlock language="bash">
        {`# Create a macOS VM
vmctl init ~/VMs/sandbox.GhostVM --cpus 6 --memory 16 --disk 128

# Install macOS from a restore image
vmctl install ~/VMs/sandbox.GhostVM

# Start the VM
vmctl start ~/VMs/sandbox.GhostVM`}
      </CodeBlock>

      <Callout variant="info" title="Restore Images">
        Restore images (IPSW files) are auto-discovered from{" "}
        <code>~/Downloads/*.ipsw</code> and{" "}
        <code>/Applications/Install macOS*.app</code>. You can also manage them
        from the Restore Images window in the GUI.
      </Callout>

      <h2>Next steps</h2>
      <ul>
        <li>
          Learn about the <a href="/docs/gui-app">GUI App</a> features
        </li>
        <li>
          Explore the <a href="/docs/cli">CLI Reference</a>
        </li>
        <li>
          Set up <a href="/docs/services">host-guest services</a> like clipboard
          sync and file transfer
        </li>
      </ul>

      <PrevNextNav currentHref="/docs/getting-started" />
    </>
  );
}
