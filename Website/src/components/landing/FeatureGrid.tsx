import {
  Package,
  Zap,
  Camera,
} from "lucide-react";

const features = [
  {
    icon: Zap,
    title: "Native Performance",
    description:
      "Built on Apple's Virtualization.framework for near-native performance on macOS. No emulation overhead.",
  },
  {
    icon: Package,
    title: "Self-Contained Bundles",
    description:
      "Each workspace lives in a single .GhostVM bundle. Copy, move, or back up entire environments as a folder.",
  },
  {
    icon: Camera,
    title: "Snapshots",
    description:
      "Checkpoint before risky changes. Create, revert, and delete snapshots to save and restore full workspace state.",
  },
];

export default function FeatureGrid() {
  return (
    <section className="py-20">
      <div className="max-w-6xl mx-auto px-4 sm:px-6 lg:px-8">
        <h2 className="text-3xl font-bold text-center mb-12">
          Built for speed, isolation, and portability
        </h2>
        <div className="grid grid-cols-1 md:grid-cols-3 gap-8">
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
