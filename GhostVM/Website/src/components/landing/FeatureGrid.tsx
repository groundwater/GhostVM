import {
  Package,
  Zap,
  Camera,
  Shield,
  Pause,
  Wifi,
} from "lucide-react";

const features = [
  {
    icon: Zap,
    title: "Native Performance",
    description:
      "Built on Apple's Virtualization.framework. Near-native speed, no emulation.",
  },
  {
    icon: Package,
    title: "Self-Contained Bundles",
    description:
      "Each workspace is a single .GhostVM folder. Copy, move, or back it up like any file.",
  },
  {
    icon: Camera,
    title: "Snapshots & Clones",
    description:
      "Checkpoint before risky changes. Clone instantly with APFS copy-on-write.",
  },
  {
    icon: Shield,
    title: "Security Boundaries",
    description:
      "Isolated by default. File transfers are quarantined. Clipboard syncs require permission.",
  },
  {
    icon: Pause,
    title: "Suspend & Resume",
    description:
      "Suspend a workspace to disk and resume exactly where you left off.",
  },
  {
    icon: Wifi,
    title: "Bridged & NAT Networking",
    description:
      "NAT out of the box, or bridged mode for full network presence. Each workspace gets its own network stack.",
  },
];

export default function FeatureGrid() {
  return (
    <section className="py-20">
      <div className="max-w-6xl mx-auto px-4 sm:px-6 lg:px-8">
        <h2 className="text-3xl font-bold text-center mb-12">
          Built for speed, isolation, and security
        </h2>
        <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-8">
          {features.map((feature) => (
            <div
              key={feature.title}
              className="p-6 rounded-xl bg-white dark:bg-gray-900 border border-gray-200 dark:border-gray-800 hover:border-ghost-300 dark:hover:border-ghost-700 transition-colors"
            >
              <feature.icon className="w-8 h-8 text-ghost-600 dark:text-ghost-400 mb-4" />
              <h3 className="text-lg font-semibold mb-2">{feature.title}</h3>
              <p className="text-sm text-gray-600 dark:text-gray-400">
                {feature.description}
              </p>
            </div>
          ))}
        </div>
      </div>
    </section>
  );
}
