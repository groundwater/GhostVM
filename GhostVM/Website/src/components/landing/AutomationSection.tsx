import Link from "next/link";

const terminalLines = [
  { prompt: true, text: "vmctl init ~/VMs/dev.GhostVM --cpus 6 --memory 16" },
  { prompt: false, text: "Created ~/VMs/dev.GhostVM" },
  { prompt: false, text: "" },
  { prompt: true, text: "vmctl install ~/VMs/dev.GhostVM" },
  { prompt: false, text: "Installing macOS — this takes a few minutes." },
  { prompt: false, text: "Installation complete" },
  { prompt: false, text: "" },
  { prompt: true, text: "vmctl start ~/VMs/dev.GhostVM" },
  { prompt: false, text: "VM running (PID 4821)" },
  { prompt: false, text: "" },
  { prompt: true, text: "vmctl snapshot ~/VMs/dev.GhostVM create clean-install" },
  { prompt: false, text: 'Snapshot "clean-install" saved' },
  { prompt: false, text: "" },
  { prompt: true, text: "vmctl stop ~/VMs/dev.GhostVM" },
  { prompt: false, text: "VM stopped" },
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
    <section className="py-20 bg-gray-50 dark:bg-gray-900/50">
      <div className="max-w-6xl mx-auto px-4 sm:px-6 lg:px-8">
        <div className="grid grid-cols-1 lg:grid-cols-2 gap-12 items-start">
          {/* Left: heading + description */}
          <div>
            <h2 className="text-3xl font-bold mb-4">
              Terminal meets GUI
            </h2>
            <p className="text-gray-600 dark:text-gray-400 mb-6">
              Every action in the GUI is also available from the terminal via{" "}
              <code className="text-sm bg-gray-100 dark:bg-gray-800 px-1.5 py-0.5 rounded">vmctl</code>.
              Create, start, snapshot, clone, and manage workspaces
              programmatically.
            </p>
            <Link
              href="/docs/cli"
              className="inline-flex items-center text-ghost-600 dark:text-ghost-400 hover:underline font-medium"
            >
              Full CLI reference &rarr;
            </Link>
          </div>

          {/* Right: terminal block */}
          <div>
            <TerminalBlock />
          </div>
        </div>


      </div>
    </section>
  );
}
