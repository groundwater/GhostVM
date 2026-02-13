import type { Metadata } from "next";
import CodeBlock from "@/components/docs/CodeBlock";
import Callout from "@/components/docs/Callout";
import PrevNextNav from "@/components/docs/PrevNextNav";

export const metadata: Metadata = { title: "MCP Server - GhostVM Docs" };

export default function MCPServer() {
  return (
    <>
      <h1>MCP Server</h1>
      <p className="lead">
        GhostVM includes a built-in{" "}
        <a href="https://modelcontextprotocol.io">Model Context Protocol</a>{" "}
        (MCP) server that gives AI assistants full control of a virtual
        machine &mdash; screen, keyboard, mouse, files, clipboard, and
        lifecycle.
      </p>

      <h2>What is MCP?</h2>
      <p>
        MCP is an open protocol that lets AI assistants call external tools via
        JSON-RPC. GhostVM&apos;s MCP server turns a running VM into a set of
        tools that any compatible client can use. Point Claude Desktop (or any
        MCP client) at a workspace and the agent can operate it like a person
        sitting in front of the screen.
      </p>

      <h2>Quick Start</h2>
      <p>
        Add GhostVM to your MCP client configuration. For Claude Desktop, add
        this to <code>claude_desktop_config.json</code>:
      </p>
      <CodeBlock language="json" title="claude_desktop_config.json">
        {`{
  "mcpServers": {
    "ghostvm": {
      "command": "vmctl",
      "args": ["mcp", "/path/to/your.GhostVM"]
    }
  }
}`}
      </CodeBlock>
      <p>
        Replace the path with your actual VM bundle. Start the VM, restart your
        MCP client, and the agent can immediately see and control the workspace.
      </p>

      <h2>Prerequisites</h2>
      <ul>
        <li>
          The VM must be <strong>running</strong> with its Helper process active.
        </li>
        <li>
          <code>vmctl</code> must be on your <code>PATH</code> (or use the full
          path in the config).
        </li>
        <li>
          <strong>GhostTools</strong> must be installed in the guest.
        </li>
        <li>
          For screenshots, grant <strong>Screen Recording</strong> permission to
          GhostTools in the guest.
        </li>
        <li>
          For accessibility tree inspection, grant{" "}
          <strong>Accessibility</strong> permission to GhostTools in the guest.
        </li>
      </ul>

      <h2>What the Agent Can Do</h2>

      <h3>See the screen</h3>
      <p>
        The agent can capture screenshots of the focused window or the full
        desktop, and read the accessibility tree to understand what UI elements
        are on screen and where they are. This is how the agent &ldquo;sees&rdquo;
        the workspace.
      </p>

      <h3>Point, click, and drag</h3>
      <p>
        Click, double-click, right-click, and drag anywhere on screen. The agent
        can target elements by pixel coordinates or by accessibility label
        &mdash; no coordinates needed if the element has a label.
      </p>

      <h3>Type text and use keyboard shortcuts</h3>
      <p>
        Type arbitrary text, press special keys (Return, Tab, Escape, arrow
        keys), and combine them with modifiers (Command, Shift, Option, Control).
        The typing rate is configurable for apps that need time to process input.
      </p>

      <h3>Transfer and manage files</h3>
      <p>
        Send files from the host into the VM, or fetch files out. Browse
        directories, create folders, move and rename files, and delete items
        &mdash; all inside the guest filesystem.
      </p>

      <h3>Use the clipboard</h3>
      <p>
        Read and write the guest clipboard directly. This is the fastest way
        to pass text between the agent and a guest application without going
        through the filesystem.
      </p>

      <h3>Manage apps and the VM</h3>
      <p>
        List running apps, launch new ones by bundle ID, bring apps to the
        front, or quit them. Check the VM&apos;s health, request a graceful
        shutdown, or suspend it to save state.
      </p>

      <h2>Architecture</h2>
      <p>
        The MCP server (<code>vmctl mcp</code>) is a thin JSON-RPC bridge. It
        reads requests from stdin, translates them to{" "}
        <a href="/docs/host-api">Host API</a> calls over the VM&apos;s Unix
        socket, and writes responses to stdout. The server is stateless &mdash;
        each tool call maps to one Host API request.
      </p>

      <h2>Troubleshooting</h2>
      <ul>
        <li>
          <strong>&ldquo;socket not found&rdquo;</strong> &mdash; The VM is not
          running or the Helper process hasn&apos;t started yet. Start the VM
          first.
        </li>
        <li>
          <strong>&ldquo;Failed to connect to VM helper&rdquo;</strong> &mdash;
          The socket exists but the Helper isn&apos;t responding. Try restarting
          the VM.
        </li>
        <li>
          <strong>Screenshots return errors</strong> &mdash; Grant Screen
          Recording permission to GhostTools in the guest&apos;s System
          Settings &gt; Privacy &amp; Security.
        </li>
        <li>
          <strong>Accessibility tree empty</strong> &mdash; Grant Accessibility
          permission to GhostTools in the guest&apos;s System Settings.
        </li>
        <li>
          <strong>Guest tools not working</strong> &mdash; Ensure GhostTools is
          installed and running inside the guest. Use the health check to verify.
        </li>
      </ul>

      <Callout variant="info" title="Compatibility">
        Works with any MCP-compatible client &mdash; Claude Desktop, VS Code
        with MCP extensions, or your own tooling. Protocol version 2024-11-05.
      </Callout>

      <PrevNextNav currentHref="/docs/mcp" />
    </>
  );
}
