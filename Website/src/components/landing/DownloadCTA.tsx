import Link from "next/link";
import { Download, Cpu, Monitor } from "lucide-react";

export default function DownloadCTA() {
  return (
    <section className="py-20 bg-ghost-600 dark:bg-ghost-900">
      <div className="max-w-4xl mx-auto px-4 sm:px-6 lg:px-8 text-center">
        <h2 className="text-3xl font-bold text-white mb-4">
          Ready to get started?
        </h2>
        <p className="text-ghost-100 mb-8 max-w-lg mx-auto">
          Download GhostVM and start running isolated agentic workspaces on
          your Mac in minutes.
        </p>
        <Link
          href="/download"
          className="inline-flex items-center gap-2 px-8 py-4 rounded-lg bg-white text-ghost-700 font-semibold hover:bg-ghost-50 transition-colors shadow-lg"
        >
          <Download className="w-5 h-5" />
          Download GhostVM
        </Link>
        <div className="flex flex-col sm:flex-row items-center justify-center gap-6 mt-8 text-ghost-200 text-sm">
          <div className="flex items-center gap-2">
            <Monitor className="w-4 h-4" />
            macOS 15+ (Sequoia)
          </div>
          <div className="flex items-center gap-2">
            <Cpu className="w-4 h-4" />
            Apple Silicon (M1 or later)
          </div>
        </div>
      </div>
    </section>
  );
}
