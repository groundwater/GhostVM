import type { Metadata } from "next";
import Link from "next/link";
import PrevNextNav from "@/components/docs/PrevNextNav";

export const metadata: Metadata = { title: "Services - GhostVM Docs" };

export default function Services() {
  return (
    <>
      <h1>Services</h1>
      <p className="lead">
        GhostVM provides several host-guest integration services that communicate
        over virtio-vsock — a high-performance virtual socket transport that
        doesn&apos;t require networking.
      </p>

      <h2>How it Works</h2>
      <p>
        When a VM is running, the host creates a <code>GhostClient</code> that
        connects to the guest via vsock. The guest runs{" "}
        <a href="/docs/ghosttools">GhostTools</a>, a companion app that
        provides the server-side of these services.
      </p>
      <p>
        Services are activated automatically when GhostTools is detected (shown
        by the green &ldquo;Guest Tools&rdquo; indicator in the VM toolbar).
      </p>

      <h2>Available Services</h2>
      <div className="grid grid-cols-1 md:grid-cols-2 gap-6 not-prose my-8">
        <Link
          href="/docs/services/clipboard-sync"
          className="block p-6 rounded-xl border border-gray-200 dark:border-gray-800 hover:border-ghost-300 dark:hover:border-ghost-700 transition-colors"
        >
          <h3 className="text-lg font-semibold mb-2">Clipboard Sync</h3>
          <p className="text-sm text-gray-600 dark:text-gray-400">
            Bidirectional clipboard sharing between host and guest.
          </p>
        </Link>
        <Link
          href="/docs/services/file-transfer"
          className="block p-6 rounded-xl border border-gray-200 dark:border-gray-800 hover:border-ghost-300 dark:hover:border-ghost-700 transition-colors"
        >
          <h3 className="text-lg font-semibold mb-2">File Transfer</h3>
          <p className="text-sm text-gray-600 dark:text-gray-400">
            Drag-and-drop files into the VM or receive files from the guest.
          </p>
        </Link>
        <Link
          href="/docs/services/port-forwarding"
          className="block p-6 rounded-xl border border-gray-200 dark:border-gray-800 hover:border-ghost-300 dark:hover:border-ghost-700 transition-colors"
        >
          <h3 className="text-lg font-semibold mb-2">Port Forwarding</h3>
          <p className="text-sm text-gray-600 dark:text-gray-400">
            Map guest ports to localhost for accessing services running in VMs.
          </p>
        </Link>
        <Link
          href="/docs/services/shared-folders"
          className="block p-6 rounded-xl border border-gray-200 dark:border-gray-800 hover:border-ghost-300 dark:hover:border-ghost-700 transition-colors"
        >
          <h3 className="text-lg font-semibold mb-2">Shared Folders</h3>
          <p className="text-sm text-gray-600 dark:text-gray-400">
            Share host directories with the guest via VirtioFS.
          </p>
        </Link>
      </div>

      <h2>Vsock Port Map</h2>
      <table>
        <thead>
          <tr>
            <th>Port</th>
            <th>Service</th>
          </tr>
        </thead>
        <tbody>
          <tr>
            <td>5002</td>
            <td>Health Check (persistent connection)</td>
          </tr>
          <tr>
            <td>5003</td>
            <td>Event Stream (files, URLs, logs from guest)</td>
          </tr>
        </tbody>
      </table>

      <PrevNextNav currentHref="/docs/services" />
    </>
  );
}
