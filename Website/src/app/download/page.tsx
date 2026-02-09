import type { Metadata } from "next";
import Link from "next/link";
import { Download, Monitor, Cpu, Terminal } from "lucide-react";

export const metadata: Metadata = {
  title: "Download - GhostVM",
};

export default function DownloadPage() {
  return (
    <div className="max-w-4xl mx-auto px-4 sm:px-6 lg:px-8 py-20">
      <h1 className="text-4xl font-bold text-center mb-4">Download GhostVM</h1>
      <p className="text-center text-gray-600 dark:text-gray-400 mb-12 max-w-lg mx-auto">
        Get the latest release of GhostVM for macOS. Includes the GhostVM.app
        and the vmctl command-line tool.
      </p>

      <div className="max-w-md mx-auto mb-12">
        <a
          href="https://github.com/groundwater/GhostVM/releases/latest"
          className="flex items-center justify-center gap-3 px-8 py-4 rounded-xl bg-ghost-600 hover:bg-ghost-700 text-white font-semibold transition-colors shadow-lg w-full"
          target="_blank"
          rel="noopener noreferrer"
        >
          <Download className="w-5 h-5" />
          Download Latest Release
        </a>
        <p className="text-center text-sm text-gray-500 mt-3">
          or{" "}
          <a
            href="https://github.com/groundwater/GhostVM/releases"
            className="text-ghost-600 dark:text-ghost-400 hover:underline"
            target="_blank"
            rel="noopener noreferrer"
          >
            view all releases
          </a>
        </p>
      </div>

      <div className="grid grid-cols-1 md:grid-cols-2 gap-6 mb-16">
        <div className="p-6 rounded-xl border border-gray-200 dark:border-gray-800">
          <h3 className="font-semibold mb-4 flex items-center gap-2">
            <Monitor className="w-5 h-5 text-ghost-600" />
            System Requirements
          </h3>
          <ul className="space-y-2 text-sm text-gray-600 dark:text-gray-400">
            <li className="flex items-center gap-2">
              <Cpu className="w-4 h-4" />
              Apple Silicon (M1 or later)
            </li>
            <li className="flex items-center gap-2">
              <Monitor className="w-4 h-4" />
              macOS 15 Sequoia or later
            </li>
          </ul>
        </div>
        <div className="p-6 rounded-xl border border-gray-200 dark:border-gray-800">
          <h3 className="font-semibold mb-4 flex items-center gap-2">
            <Terminal className="w-5 h-5 text-ghost-600" />
            Build from Source
          </h3>
          <div className="text-sm text-gray-600 dark:text-gray-400 space-y-2">
            <p>Requires Xcode 15+ and XcodeGen:</p>
            <pre className="terminal-text bg-gray-100 dark:bg-gray-900 rounded-lg p-3 overflow-x-auto text-xs">
              <code>
                {`brew install xcodegen
git clone https://github.com/groundwater/GhostVM
cd GhostVM
make app`}
              </code>
            </pre>
          </div>
        </div>
      </div>

      <div className="text-center">
        <p className="text-gray-600 dark:text-gray-400 mb-4">
          New to GhostVM? Check out the getting started guide.
        </p>
        <Link
          href="/docs/getting-started"
          className="inline-flex items-center px-6 py-3 rounded-lg border border-gray-300 dark:border-gray-700 hover:bg-gray-50 dark:hover:bg-gray-900 font-medium transition-colors"
        >
          Get Started
        </Link>
      </div>
    </div>
  );
}
