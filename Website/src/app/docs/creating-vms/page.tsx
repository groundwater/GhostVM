import type { Metadata } from "next";
import Link from "next/link";
import PrevNextNav from "@/components/docs/PrevNextNav";

export const metadata: Metadata = { title: "Creating VMs - GhostVM Docs" };

export default function CreatingVMs() {
  return (
    <>
      <h1>Creating Virtual Machines</h1>
      <p className="lead">
        GhostVM supports creating macOS virtual machines on Apple Silicon.
      </p>

      <div className="grid grid-cols-1 md:grid-cols-2 gap-6 not-prose my-8">
        <Link
          href="/docs/creating-vms/macos"
          className="block p-6 rounded-xl border border-gray-200 dark:border-gray-800 hover:border-ghost-300 dark:hover:border-ghost-700 transition-colors"
        >
          <h3 className="text-lg font-semibold mb-2">macOS VMs</h3>
          <p className="text-sm text-gray-600 dark:text-gray-400">
            Create macOS virtual machines using IPSW restore images. Supports
            macOS 13 Ventura and later.
          </p>
        </Link>
      </div>

      <h2>Key Concepts</h2>
      <ul>
        <li>
          VMs are stored as self-contained <code>.GhostVM</code> bundles (
          <Link href="/docs/vm-bundles">learn more</Link>)
        </li>
        <li>
          Each bundle contains the disk image, configuration, snapshots, and
          optional custom icon
        </li>
        <li>
          You can create VMs using either the GUI app or the{" "}
          <code>vmctl</code> CLI
        </li>
      </ul>

      <PrevNextNav currentHref="/docs/creating-vms" />
    </>
  );
}
