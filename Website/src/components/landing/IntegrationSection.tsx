import Image from "next/image";
import { Clipboard, Network, FileUp, FolderOpen } from "lucide-react";

const spotlights = [
  {
    icon: Clipboard,
    title: "Clipboard Sync",
    description:
      "Copy from your Mac, paste in the workspace — and vice versa. No friction.",
  },
  {
    icon: Network,
    title: "Port Forwarding",
    description:
      "Access services running in the workspace from localhost. Web servers, APIs, databases — all reachable.",
  },
  {
    icon: FileUp,
    title: "File Transfer",
    description:
      "Drag and drop files into the workspace window. Pull files back out with a click.",
  },
  {
    icon: FolderOpen,
    title: "Shared Folders",
    description:
      "Mount host directories inside the workspace for seamless file sharing.",
  },
];

export default function IntegrationSection() {
  return (
    <section className="py-20 bg-gray-50 dark:bg-gray-900/50">
      <div className="max-w-6xl mx-auto px-4 sm:px-6 lg:px-8">
        {/* Hero: full-width VM screenshot */}
        <h2 className="text-3xl font-bold text-center mb-4">
          Move in and out of workspaces like switching apps
        </h2>
        <p className="text-center text-gray-600 dark:text-gray-400 mb-10 max-w-2xl mx-auto">
          Deep host integration means each workspace feels native. Clipboard,
          files, and network stay connected — the only hint is a small toolbar
          at the top.
        </p>

        <div className="max-w-4xl mx-auto mb-16">
          <div className="rounded-xl overflow-hidden shadow-2xl ring-1 ring-black/10">
            <Image
              src="/images/screenshots/vm-integration.png"
              alt="VS Code running inside an agentic workspace — nearly indistinguishable from a native app"
              width={1200}
              height={800}
              className="w-full h-auto block"
            />
          </div>
          <p className="text-sm text-gray-600 dark:text-gray-400 mt-3 text-center">
            VS Code running inside an agentic workspace. Only the GhostVM toolbar gives it away.
          </p>
        </div>

        {/* Settings screenshot + spotlights side by side on desktop */}
        <div className="grid grid-cols-1 lg:grid-cols-2 gap-10 items-start max-w-5xl mx-auto">
          {/* Left: edit-vm-sheet screenshot */}
          <div>
            <div className="rounded-xl overflow-hidden shadow-xl ring-1 ring-black/10">
              <Image
                src="/images/screenshots/edit-vm-sheet.png"
                alt="GhostVM Edit VM sheet showing port forwards and shared folders"
                width={600}
                height={700}
                className="w-full h-auto block"
              />
            </div>
            <p className="text-sm text-gray-600 dark:text-gray-400 mt-3 text-center">
              Configure port forwards, shared folders, and more from a single panel.
            </p>
          </div>

          {/* Right: 2x1 feature spotlights */}
          <div className="grid grid-cols-1 gap-4">
            {spotlights.map((s) => (
              <div
                key={s.title}
                className="flex gap-4 p-5 rounded-xl bg-white dark:bg-gray-900 border border-gray-200 dark:border-gray-800"
              >
                <s.icon className="w-8 h-8 text-ghost-600 dark:text-ghost-400 shrink-0 mt-0.5" />
                <div>
                  <h3 className="font-semibold mb-1">{s.title}</h3>
                  <p className="text-sm text-gray-600 dark:text-gray-400">
                    {s.description}
                  </p>
                </div>
              </div>
            ))}
          </div>
        </div>
      </div>
    </section>
  );
}
