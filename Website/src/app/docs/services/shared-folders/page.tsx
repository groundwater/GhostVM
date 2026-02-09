import type { Metadata } from "next";
import CodeBlock from "@/components/docs/CodeBlock";
import Callout from "@/components/docs/Callout";
import PrevNextNav from "@/components/docs/PrevNextNav";

export const metadata: Metadata = { title: "Shared Folders - GhostVM Docs" };

export default function SharedFolders() {
  return (
    <>
      <h1>Shared Folders</h1>
      <p className="lead">
        Share directories from the host Mac with the guest VM using VirtioFS.
        Files appear instantly in the guest without any transfer step.
      </p>

      <h2>Configuring Shared Folders</h2>

      <h3>Via CLI</h3>
      <CodeBlock language="bash">
        {`# When creating a VM
vmctl init ~/VMs/dev.GhostVM --shared-folder ~/Projects --writable

# When starting a VM
vmctl start ~/VMs/dev.GhostVM --shared-folder ~/Projects --read-only`}
      </CodeBlock>

      <h3>Via GUI</h3>
      <p>
        In the Create VM dialog or Edit VM Settings, use the Shared Folders
        section to add host directories. Each folder can be configured as
        read-only or writable.
      </p>

      <h2>Mounting in the Guest</h2>

      <h3>macOS Guest</h3>
      <p>
        On macOS guests, shared folders appear automatically in the Finder
        sidebar under &ldquo;Locations&rdquo; as a VirtioFS volume.
      </p>

      <Callout variant="info" title="Multiple Folders">
        You can configure multiple shared folders per VM. Each folder is exposed
        as a separate VirtioFS share tag.
      </Callout>

      <h2>Read-Only vs Writable</h2>
      <p>
        Shared folders are <strong>read-only by default</strong> for safety. In
        read-only mode, the guest can read files but cannot modify, create, or
        delete them. Enable writable mode when you need the guest to write back
        to the host.
      </p>

      <Callout variant="warning">
        Writable shared folders allow the guest to modify files on the host.
        Use with caution, especially with untrusted guests.
      </Callout>

      <PrevNextNav currentHref="/docs/services/shared-folders" />
    </>
  );
}
