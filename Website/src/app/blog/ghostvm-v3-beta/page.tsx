import type { Metadata } from "next";
import Link from "next/link";
import CodeBlock from "@/components/docs/CodeBlock";

export const metadata: Metadata = {
  title:
    "GhostVM v3 Beta: Interactive Terminal, ASIF Disks, SwiftNIO - GhostVM",
  description:
    "GhostVM v3 beta: interactive terminal over vsock, ASIF disk images, SwiftNIO guest agent, macOS 26, Swift 6.",
  openGraph: {
    title: "GhostVM v3 Beta",
    description:
      "Interactive terminal, ASIF disks, SwiftNIO, macOS 26.",
    url: "https://ghostvm.org/blog/ghostvm-v3-beta",
    type: "article",
  },
};

function PlaceholderImage({
  alt,
  caption,
}: {
  alt: string;
  caption: string;
}) {
  return (
    <figure className="not-prose my-8">
      <div className="rounded-xl overflow-hidden border border-gray-200 dark:border-gray-800 bg-gray-100 dark:bg-gray-900 flex items-center justify-center aspect-video">
        <p className="text-sm text-gray-500 dark:text-gray-400">{alt}</p>
      </div>
      <figcaption className="mt-2 text-center text-sm text-gray-500 dark:text-gray-400">
        {caption}
      </figcaption>
    </figure>
  );
}

export default function GhostVMV3BetaPost() {
  return (
    <>
      <div className="not-prose mb-8">
        <Link
          href="/blog"
          className="text-sm text-ghost-600 dark:text-ghost-400 hover:underline"
        >
          &larr; Back to blog
        </Link>
      </div>

      <div className="flex items-center gap-3 text-sm text-gray-500 dark:text-gray-400 mb-2 not-prose">
        <time dateTime="2026-04-28">April 28, 2026</time>
        <span>&middot;</span>
        <span>4 min read</span>
      </div>

      <h1>GhostVM v3 Beta</h1>

      <p className="lead">
        v3 is a rewrite on macOS 26 and Swift 6. Shell into VMs without SSH,
        near-native disk performance, non-blocking guest communication.
      </p>

      {/* ── Interactive Terminal ─────────────────────────────── */}

      <h2>vmctl shell</h2>

      <p>
        Full PTY session into any running VM. Connects over virtio-vsock &mdash;
        no SSH daemon, no port forwarding, no network config.
      </p>

      <CodeBlock language="bash">
        {`$ vmctl shell ~/VMs/dev.GhostVM
Connecting to 'dev' via vsock...

dev ~ % whoami
admin
dev ~ % exit
Connection closed.`}
      </CodeBlock>

      <p>
        Terminal resize, Ctrl-C, signal forwarding all work. Feels like SSH
        without the setup.
      </p>

      <p>
        The GUI gets an <strong>Open Terminal</strong> toolbar button that
        launches Terminal.app with a shell session already connected.
      </p>

      <PlaceholderImage
        alt="Open Terminal toolbar button"
        caption="One-click terminal access from the VM window toolbar."
      />

      {/* ── ASIF Disk Images ────────────────────────────────── */}

      <h2>ASIF Disk Images</h2>

      <p>
        v3 switches from raw sparse images to Apple Sparse Image Format.
        Near-native SSD performance &mdash; most noticeable on Xcode builds,{" "}
        <code>npm install</code>, large git checkouts.
      </p>

      <PlaceholderImage
        alt="ASIF vs raw sparse disk performance"
        caption="ASIF delivers near-native SSD performance for VM workloads."
      />

      <p>
        Legacy VMs auto-migrate on first launch. Non-destructive &mdash; your
        original disk is preserved until the new image is verified.
      </p>

      {/* ── SwiftNIO ────────────────────────────────────────── */}

      <h2>SwiftNIO Guest Agent</h2>

      <p>
        All blocking server code replaced with a SwiftNIO event loop.
        Auto-detects HTTP/1.1 and HTTP/2. File uploads stream directly to disk
        instead of buffering in memory.
      </p>

      <div className="not-prose my-8 overflow-x-auto">
        <table className="w-full text-sm border border-gray-200 dark:border-gray-800 rounded-lg overflow-hidden">
          <thead className="bg-gray-50 dark:bg-gray-900">
            <tr>
              <th className="text-left px-4 py-3 font-semibold text-gray-900 dark:text-white border-b border-gray-200 dark:border-gray-800">
                Server
              </th>
              <th className="text-left px-4 py-3 font-semibold text-gray-900 dark:text-white border-b border-gray-200 dark:border-gray-800">
                Port
              </th>
              <th className="text-left px-4 py-3 font-semibold text-gray-900 dark:text-white border-b border-gray-200 dark:border-gray-800">
                Role
              </th>
            </tr>
          </thead>
          <tbody className="divide-y divide-gray-200 dark:divide-gray-800">
            <tr>
              <td className="px-4 py-3 font-mono text-ghost-600 dark:text-ghost-400">NIOVsockServer</td>
              <td className="px-4 py-3 text-gray-600 dark:text-gray-400">5000</td>
              <td className="px-4 py-3 text-gray-600 dark:text-gray-400">HTTP/1.1 + HTTP/2 requests, streaming file uploads</td>
            </tr>
            <tr>
              <td className="px-4 py-3 font-mono text-ghost-600 dark:text-ghost-400">TunnelServer</td>
              <td className="px-4 py-3 text-gray-600 dark:text-gray-400">5001</td>
              <td className="px-4 py-3 text-gray-600 dark:text-gray-400">CONNECT-based TCP tunneling</td>
            </tr>
            <tr>
              <td className="px-4 py-3 font-mono text-ghost-600 dark:text-ghost-400">HealthServer</td>
              <td className="px-4 py-3 text-gray-600 dark:text-gray-400">5002</td>
              <td className="px-4 py-3 text-gray-600 dark:text-gray-400">JSON health status</td>
            </tr>
            <tr>
              <td className="px-4 py-3 font-mono text-ghost-600 dark:text-ghost-400">EventPushServer</td>
              <td className="px-4 py-3 text-gray-600 dark:text-gray-400">5003</td>
              <td className="px-4 py-3 text-gray-600 dark:text-gray-400">NDJSON event streaming</td>
            </tr>
          </tbody>
        </table>
      </div>

      {/* ── Platform ────────────────────────────────────────── */}

      <h2>macOS 26 + Swift 6</h2>

      <p>
        macOS 26 gives us native AF_VSOCK in kqueue &mdash; the polling-based
        vsock probe from v2 is gone. Swift 6 strict concurrency enforces{" "}
        <code>Sendable</code> at compile time across every actor boundary.
      </p>

      <p>
        v2.x stays on macOS 15 and continues to get bug fixes.
      </p>

      {/* ── Network ─────────────────────────────────────────── */}

      <h2>Network Bridge Monitoring</h2>

      <p>
        Bridged VMs now survive host network changes. Switch Wi-Fi, wake from
        sleep on a different network &mdash; GhostVM detects the change via{" "}
        <code>NWPathMonitor</code>, cycles the bridge attachment, and triggers
        guest DHCP renewal automatically.
      </p>

      {/* ── Migration ───────────────────────────────────────── */}

      <h2>Upgrading</h2>

      <ul>
        <li>
          <strong>macOS 26 required.</strong> Stay on v2.x for macOS 15.
        </li>
        <li>
          <strong>Disk migration is automatic.</strong> Prompted on first launch,
          non-destructive, cancellable.
        </li>
        <li>
          <strong>Update GhostTools.</strong> The guest agent needs the v3
          version for terminal and SwiftNIO features.
        </li>
        <li>
          <strong>VM bundles carry over.</strong> Configs, clones, and snapshots
          are unchanged.
        </li>
      </ul>

      <h2>Try It</h2>

      <p>
        <Link href="/download">Download the beta</Link> or build from source:
      </p>

      <CodeBlock language="bash">
        {`git clone https://github.com/groundwater/GhostVM
cd GhostVM && git checkout experiment/nio-http2
make app`}
      </CodeBlock>

      <p>
        Bugs and feedback:{" "}
        <a
          href="https://github.com/groundwater/GhostVM/issues"
          target="_blank"
          rel="noopener noreferrer"
        >
          GitHub Issues
        </a>
      </p>

      <hr />

      <div className="not-prose mt-8">
        <Link
          href="/blog"
          className="text-sm text-ghost-600 dark:text-ghost-400 hover:underline"
        >
          &larr; Back to blog
        </Link>
      </div>
    </>
  );
}
