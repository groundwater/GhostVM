import Image from "next/image";
import { Clipboard, Network, FileUp, FolderOpen } from "lucide-react";

const spotlights = [
  {
    icon: Clipboard,
    title: "Clipboard Sync",
    description:
      "Copy-paste flows between host and workspace. A permission prompt gives you control.",
    image: "/images/screenshots/clipboard-permission.png",
    alt: "Clipboard sync permission prompt",
  },
  {
    icon: Network,
    title: "Port Forwarding",
    description:
      "Listening ports are auto-detected with process names. Manage them from the toolbar.",
    image: "/images/screenshots/port-forward-notification.png",
    alt: "Auto port-forward notification showing detected ports",
  },
  {
    icon: FileUp,
    title: "File Transfer",
    description:
      "Drag files in, pull them out. Transferred files are quarantined by default.",
    image: "/images/screenshots/file-transfer-prompt.png",
    alt: "File transfer prompt for guest to host download",
  },
  {
    icon: FolderOpen,
    title: "Shared Folders",
    description: "Mount host directories inside the workspace.",
    image: "/images/screenshots/shared-folders.png",
    alt: "Shared folder configuration panel",
  },
];

export default function IntegrationSection() {
  return (
    <section className="py-20">
      <div className="max-w-6xl mx-auto px-4 sm:px-6 lg:px-8">
        {/* Hero: full-width VM screenshot */}
        <h2 className="text-3xl font-bold text-center mb-4">
          Move in and out of workspaces like switching apps
        </h2>
        <p className="text-center text-gray-600 dark:text-gray-400 mb-10 max-w-2xl mx-auto">
          Deep host integration means each workspace feels native. Clipboard,
          files, and network stay connected.
        </p>

        <div className="max-w-4xl mx-auto mb-16">
          <div className="rounded-xl overflow-hidden shadow-2xl ring-1 ring-black/10">
            <Image
              src="/images/screenshots/vm-integration.jpg"
              alt="VS Code running inside an agentic workspace — nearly indistinguishable from a native app"
              width={1200}
              height={800}
              className="w-full h-auto block"
            />
          </div>
        </div>

        {/* Feature spotlights */}
        <div className="grid grid-cols-1 sm:grid-cols-2 gap-4 max-w-3xl mx-auto">
          {spotlights.map((s) => (
            <div
              key={s.title}
              className="p-5 rounded-xl bg-white dark:bg-gray-900 border border-gray-200 dark:border-gray-800"
            >
              <div className="flex gap-4">
                <s.icon className="w-8 h-8 text-ghost-600 dark:text-ghost-400 shrink-0 mt-0.5" />
                <div>
                  <h3 className="font-semibold mb-1">{s.title}</h3>
                  <p className="text-sm text-gray-600 dark:text-gray-400">
                    {s.description}
                  </p>
                </div>
              </div>
              <div className="mt-4 rounded-lg overflow-hidden border border-gray-200 dark:border-gray-700">
                <Image
                  src={s.image}
                  alt={s.alt}
                  width={600}
                  height={400}
                  className="w-full h-auto block"
                />
              </div>
            </div>
          ))}
        </div>
      </div>
    </section>
  );
}
