import Link from "next/link";
import {
  Monitor,
  MousePointerClick,
  Keyboard,
  FolderTree,
  Clipboard,
  Power,
} from "lucide-react";

const capabilities = [
  {
    icon: Monitor,
    title: "See the screen",
    description:
      "Capture screenshots of the focused window or the full desktop. Read the accessibility tree to understand what's on screen.",
  },
  {
    icon: MousePointerClick,
    title: "Point and click",
    description:
      "Click, double-click, right-click, drag. Target elements by coordinates or accessibility label.",
  },
  {
    icon: Keyboard,
    title: "Type and use shortcuts",
    description:
      "Type text, press special keys, and use modifier combos like Command+S. Control the typing rate for apps that need it.",
  },
  {
    icon: FolderTree,
    title: "Manage files",
    description:
      "Send files into the VM, fetch files out. Browse, create, move, and delete files and directories inside the guest.",
  },
  {
    icon: Clipboard,
    title: "Read and write the clipboard",
    description:
      "Get and set the guest clipboard. Pass data between the agent and guest apps without touching the filesystem.",
  },
  {
    icon: Power,
    title: "Control the VM lifecycle",
    description:
      "Check status, request shutdown, or suspend the VM. Launch, activate, and quit apps running inside the guest.",
  },
];

const configSnippet = `{
  "mcpServers": {
    "ghostvm": {
      "command": "vmctl",
      "args": ["mcp", "~/VMs/dev.GhostVM"]
    }
  }
}`;

function TerminalBlock() {
  return (
    <div className="rounded-xl overflow-hidden border border-gray-800 shadow-2xl">
      {/* Title bar */}
      <div className="bg-gray-800 px-4 py-2.5 flex items-center gap-2">
        <div className="flex gap-1.5">
          <div className="w-3 h-3 rounded-full bg-red-500" />
          <div className="w-3 h-3 rounded-full bg-yellow-500" />
          <div className="w-3 h-3 rounded-full bg-green-500" />
        </div>
        <span className="ml-2 text-xs text-gray-400 terminal-text">
          claude_desktop_config.json
        </span>
      </div>
      {/* Content */}
      <div className="bg-gray-950 p-5">
        <pre className="text-sm text-gray-300 terminal-text leading-5">
          {configSnippet}
        </pre>
      </div>
    </div>
  );
}

export default function MCPSection() {
  return (
    <section className="py-20 bg-gray-50 dark:bg-gray-900/50">
      <div className="max-w-6xl mx-auto px-4 sm:px-6 lg:px-8">
        <div className="text-center mb-12">
          <h2 className="text-3xl font-bold mb-4">
            Give AI agents a full computer to work with
          </h2>
          <p className="text-gray-600 dark:text-gray-400 max-w-2xl mx-auto">
            The built-in{" "}
            <Link
              href="/docs/mcp"
              className="text-ghost-600 dark:text-ghost-400 hover:underline"
            >
              MCP server
            </Link>{" "}
            lets any AI assistant see the screen, click, type, and manage files
            inside a workspace &mdash; no custom integration required. Point
            Claude Desktop at a VM and it just works.
          </p>
        </div>

        <div className="grid grid-cols-1 lg:grid-cols-3 gap-8 items-start">
          {/* Left: capabilities */}
          <div className="lg:col-span-2 grid grid-cols-1 sm:grid-cols-2 gap-4">
            {capabilities.map((cap) => (
              <div
                key={cap.title}
                className="flex gap-4 p-5 rounded-xl bg-white dark:bg-gray-900 border border-gray-200 dark:border-gray-800"
              >
                <cap.icon className="w-6 h-6 text-ghost-600 dark:text-ghost-400 shrink-0 mt-0.5" />
                <div>
                  <h3 className="font-semibold mb-1">{cap.title}</h3>
                  <p className="text-sm text-gray-600 dark:text-gray-400">
                    {cap.description}
                  </p>
                </div>
              </div>
            ))}
          </div>

          {/* Right: config snippet */}
          <div>
            <TerminalBlock />
            <p className="text-sm text-gray-500 dark:text-gray-400 mt-3 text-center">
              Add this to your MCP client config. That&apos;s it.
            </p>
          </div>
        </div>

        {/* Below: callout */}
        <div className="mt-10 text-center">
          <p className="text-gray-600 dark:text-gray-400">
            Works with any MCP-compatible client &mdash; Claude Desktop, VS
            Code, or your own tooling.
          </p>
        </div>
      </div>
    </section>
  );
}
