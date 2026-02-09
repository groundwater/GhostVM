const lines = [
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
];

export default function TerminalDemo() {
  return (
    <section className="py-20">
      <div className="max-w-6xl mx-auto px-4 sm:px-6 lg:px-8">
        <h2 className="text-3xl font-bold text-center mb-4">
          Powerful CLI included
        </h2>
        <p className="text-center text-gray-600 dark:text-gray-400 mb-10 max-w-xl mx-auto">
          Create, install, and manage VMs from the terminal with{" "}
          <code className="terminal-text text-ghost-600 dark:text-ghost-400">
            vmctl
          </code>
          . Perfect for automation and scripting.
        </p>
        <div className="max-w-3xl mx-auto rounded-xl overflow-hidden border border-gray-800 shadow-2xl">
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
            {lines.map((line, i) => (
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
      </div>
    </section>
  );
}
