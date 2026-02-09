import { ShieldCheck, Clipboard, Box } from "lucide-react";

const cards = [
  {
    icon: ShieldCheck,
    title: "File Quarantine",
    description:
      "Files received from the guest are tagged with the com.apple.quarantine extended attribute. macOS Gatekeeper verifies them before they can run — the same protection you get from web downloads.",
  },
  {
    icon: Clipboard,
    title: "Clipboard Permissions",
    description:
      "When a workspace tries to sync the clipboard, a permission panel appears. Choose to deny, allow once, or always allow — giving you full control over what crosses the boundary.",
  },
  {
    icon: Box,
    title: "Isolated by Default",
    description:
      "Each workspace runs in its own VM with no shared filesystem or network access to the host unless you explicitly enable it. Integration services only activate with your consent.",
  },
];

export default function SecuritySection() {
  return (
    <section className="py-20 bg-gray-50 dark:bg-gray-900/50">
      <div className="max-w-6xl mx-auto px-4 sm:px-6 lg:px-8">
        <h2 className="text-3xl font-bold text-center mb-4">
          Security boundaries you can see
        </h2>
        <p className="text-center text-gray-600 dark:text-gray-400 mb-12 max-w-2xl mx-auto">
          Workspaces are isolated VMs, but integration still needs guardrails.
          GhostVM makes every cross-boundary action visible and controllable.
        </p>

        <div className="grid grid-cols-1 md:grid-cols-3 gap-8 max-w-5xl mx-auto">
          {cards.map((card) => (
            <div
              key={card.title}
              className="p-6 rounded-xl bg-white dark:bg-gray-900 border border-gray-200 dark:border-gray-800"
            >
              <card.icon className="w-8 h-8 text-ghost-600 dark:text-ghost-400 mb-4" />
              <h3 className="text-lg font-semibold mb-2">{card.title}</h3>
              <p className="text-sm text-gray-600 dark:text-gray-400">
                {card.description}
              </p>
            </div>
          ))}
        </div>
      </div>
    </section>
  );
}
