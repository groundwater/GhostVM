import { DesktopFrame, WindowScreenshot } from "./DesktopFrame";

const terminalLines = [
  { prompt: true, text: "vmctl init ~/VMs/dev.GhostVM --cpus 6 --memory 16 --disk 128" },
  { prompt: false, text: "Created macOS VM bundle at ~/VMs/dev.GhostVM" },
  { prompt: false, text: "" },
  { prompt: true, text: "vmctl install ~/VMs/dev.GhostVM" },
  { prompt: false, text: "Installing macOS from UniversalMac_15.2_24C101_Restore.ipsw..." },
  { prompt: false, text: "Installation complete." },
  { prompt: false, text: "" },
  { prompt: true, text: "vmctl start ~/VMs/dev.GhostVM" },
  { prompt: false, text: "Starting VM... (GUI window will appear)" },
  { prompt: false, text: "" },
  { prompt: true, text: "vmctl snapshot ~/VMs/dev.GhostVM create clean-state" },
  { prompt: false, text: 'Snapshot "clean-state" created.' },
  { prompt: false, text: "" },
  { prompt: true, text: "vmctl clone ~/VMs/dev.GhostVM staging" },
  { prompt: false, text: "Cloned to ~/VMs/staging.GhostVM (APFS copy-on-write)" },
  { prompt: false, text: "" },
  { prompt: true, text: "vmctl mcp ~/VMs/staging.GhostVM" },
  { prompt: false, text: "MCP server ready (stdin/stdout)" },
];

const bullets = [
  {
    title: "Scriptable CLI",
    description: "Agents can create, start, and snapshot workspaces programmatically with vmctl.",
  },
  {
    title: "Self-contained bundles",
    description: "Each workspace is a single .GhostVM folder — copy, move, or version-control entire environments.",
  },
  {
    title: "Snapshots",
    description: "Checkpoint a workspace before risky operations. Revert to a known-good state instantly.",
  },
  {
    title: "Headless mode",
    description: "Run workspaces without a GUI for background agents and automated tasks.",
  },
  {
    title: "CI/CD ready",
    description: "Provision isolated workspaces in build pipelines and testing workflows.",
  },
  {
    title: "Instant Clone",
    description: "Duplicate a workspace instantly with APFS copy-on-write. Fresh identity, minimal disk usage.",
  },
  {
    title: "MCP Server",
    description: "Expose tools to AI agents via JSON-RPC. Clipboard, files, and lifecycle — all programmatic.",
  },
];

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
          Terminal
        </span>
      </div>
      {/* Terminal content */}
      <div className="bg-gray-950 p-5 overflow-x-auto">
        {terminalLines.map((line, i) => (
          <div key={i} className="terminal-text text-sm leading-6">
            {line.prompt ? (
              <>
                <span className="text-green-400">$ </span>
                <span className="text-gray-200">{line.text}</span>
              </>
            ) : (
              <span className="text-gray-500">{line.text}</span>
            )}
          </div>
        ))}
      </div>
    </div>
  );
}

export default function AutomationSection() {
  return (
    <section className="py-20">
      <div className="max-w-6xl mx-auto px-4 sm:px-6 lg:px-8">
        <div className="grid grid-cols-1 lg:grid-cols-2 gap-12 items-start">
          {/* Left: heading + bullets */}
          <div>
            <h2 className="text-3xl font-bold mb-4">
              Automate workspace provisioning with vmctl
            </h2>
            <p className="text-gray-600 dark:text-gray-400 mb-8">
              Create, snapshot, and manage workspaces from the terminal.
              Perfect for agents that need to spin up their own environments.
            </p>
            <ul className="space-y-4">
              {bullets.map((b) => (
                <li key={b.title} className="flex gap-3">
                  <span className="mt-1 text-ghost-600 dark:text-ghost-400 shrink-0">
                    <svg className="w-5 h-5" viewBox="0 0 20 20" fill="currentColor">
                      <path fillRule="evenodd" d="M16.704 4.153a.75.75 0 0 1 .143 1.052l-8 10.5a.75.75 0 0 1-1.127.075l-4.5-4.5a.75.75 0 0 1 1.06-1.06l3.894 3.893 7.48-9.817a.75.75 0 0 1 1.05-.143Z" clipRule="evenodd" />
                    </svg>
                  </span>
                  <div>
                    <span className="font-semibold">{b.title}</span>
                    <span className="text-gray-600 dark:text-gray-400"> &mdash; {b.description}</span>
                  </div>
                </li>
              ))}
            </ul>
          </div>

          {/* Right: terminal block */}
          <div>
            <TerminalBlock />
          </div>
        </div>

        {/* Below: context-menu screenshot */}
        <div className="mt-14 max-w-3xl mx-auto">
          <DesktopFrame>
            <WindowScreenshot
              src="/images/screenshots/context-menu.png"
              alt="GhostVM context menu showing VM lifecycle actions"
            />
          </DesktopFrame>
          <p className="text-sm text-gray-600 dark:text-gray-400 mt-3 text-center">
            Full workspace lifecycle management from the GUI &mdash; start, stop, snapshot, and configure.
          </p>
        </div>
      </div>
    </section>
  );
}
