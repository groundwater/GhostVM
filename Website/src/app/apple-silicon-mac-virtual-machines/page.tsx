import type { Metadata } from "next";
import Link from "next/link";
import CodeBlock from "@/components/docs/CodeBlock";

export const metadata: Metadata = {
  title: "Apple Silicon Mac Virtual Machines (M1/M2/M3/M4) - Complete Guide",
  description:
    "Run macOS virtual machines on Apple Silicon M1, M2, M3, and M4 Macs. Native performance with Virtualization.framework. What works, what doesn't, and how to get started.",
  openGraph: {
    title: "Apple Silicon Mac Virtual Machines (M1/M2/M3/M4)",
    description:
      "Run macOS virtual machines on Apple Silicon. Native performance with Virtualization.framework. Complete guide for M1, M2, M3, and M4 Macs.",
    url: "https://ghostvm.org/apple-silicon-mac-virtual-machines",
    type: "article",
  },
};

export default function AppleSiliconMacVirtualMachines() {
  return (
    <div className="max-w-4xl mx-auto px-4 sm:px-6 lg:px-8 py-16">
      <article className="prose prose-gray dark:prose-invert prose-lg max-w-none">
        <h1>Apple Silicon Mac Virtual Machines</h1>
        <p className="lead text-xl text-gray-600 dark:text-gray-400">
          Everything you need to know about running macOS virtual machines on
          M1, M2, M3, and M4 Macs. Native ARM performance, no emulation
          required.
        </p>

        <nav className="not-prose my-8 p-6 bg-gray-50 dark:bg-gray-900 rounded-xl">
          <h2 className="text-sm font-semibold text-gray-500 dark:text-gray-400 uppercase tracking-wide mb-4">
            On this page
          </h2>
          <ul className="space-y-2 text-sm">
            <li>
              <a href="#new-era" className="text-ghost-600 dark:text-ghost-400 hover:underline">
                A New Era for Mac Virtualization
              </a>
            </li>
            <li>
              <a href="#how-it-works" className="text-ghost-600 dark:text-ghost-400 hover:underline">
                How Apple Silicon VMs Work
              </a>
            </li>
            <li>
              <a href="#what-works" className="text-ghost-600 dark:text-ghost-400 hover:underline">
                What Works (and What Doesn&apos;t)
              </a>
            </li>
            <li>
              <a href="#performance" className="text-ghost-600 dark:text-ghost-400 hover:underline">
                Performance Guide
              </a>
            </li>
            <li>
              <a href="#chip-comparison" className="text-ghost-600 dark:text-ghost-400 hover:underline">
                M1 vs M2 vs M3 vs M4 for VMs
              </a>
            </li>
            <li>
              <a href="#getting-started" className="text-ghost-600 dark:text-ghost-400 hover:underline">
                Getting Started
              </a>
            </li>
          </ul>
        </nav>

        <h2 id="new-era">A New Era for Mac Virtualization</h2>
        <p>
          When Apple transitioned from Intel to Apple Silicon in 2020,
          everything about Mac virtualization changed. The old approaches —
          VMware Fusion, Parallels running x86 Windows, VirtualBox — either
          stopped working or required fundamental redesigns.
        </p>
        <p>
          But Apple also introduced something new:{" "}
          <strong>Virtualization.framework</strong>, a native API for running
          virtual machines on Apple Silicon. This wasn&apos;t just a port of
          Intel virtualization — it was built from the ground up for ARM.
        </p>

        <div className="not-prose my-8 p-6 border-l-4 border-ghost-500 bg-ghost-50 dark:bg-ghost-950/30 rounded-r-xl">
          <h4 className="font-semibold text-ghost-800 dark:text-ghost-200 mb-2">
            Why most Intel VM guides are obsolete
          </h4>
          <p className="text-ghost-900 dark:text-ghost-100 text-sm">
            If you&apos;re searching for Mac VM tutorials and finding old
            content about VMware or VirtualBox on Intel Macs, that
            information doesn&apos;t apply to Apple Silicon. The architecture,
            tools, and constraints are completely different.
          </p>
        </div>

        <h2 id="how-it-works">How Apple Silicon VMs Work</h2>

        <h3>Virtualization.framework</h3>
        <p>
          Apple&apos;s Virtualization.framework is a first-party hypervisor API
          introduced in macOS 11 Big Sur. It provides:
        </p>
        <ul>
          <li>
            <strong>Hardware-accelerated virtualization</strong> — uses the
            CPU&apos;s virtualization extensions directly
          </li>
          <li>
            <strong>Paravirtualized devices</strong> — efficient virtual
            network, storage, and display
          </li>
          <li>
            <strong>macOS guest support</strong> — run macOS inside macOS
            (starting with macOS 12)
          </li>
          <li>
            <strong>Linux guest support</strong> — run ARM64 Linux distributions
          </li>
        </ul>

        <h3>ARM64 Architecture</h3>
        <p>
          Apple Silicon Macs use ARM64 (AArch64) processors. This means:
        </p>
        <ul>
          <li>
            <strong>Guest VMs must be ARM64</strong> — you can&apos;t run x86
            Windows or Linux
          </li>
          <li>
            <strong>No Intel emulation</strong> — unlike Rosetta 2 for apps,
            there&apos;s no x86 emulation for VMs
          </li>
          <li>
            <strong>Native macOS performance</strong> — ARM macOS guests run at
            near bare-metal speed
          </li>
        </ul>

        <h3>IPSW Restore Images</h3>
        <p>
          Unlike Intel Macs where you could boot from a macOS installer, Apple
          Silicon VMs use IPSW restore images — the same format used for iOS
          and Apple Silicon Mac recovery. You download an IPSW file and
          &quot;restore&quot; it to create a new VM.
        </p>

        <h2 id="what-works">What Works (and What Doesn&apos;t)</h2>

        <h3>What Works Great</h3>
        <div className="not-prose my-8 overflow-x-auto">
          <table className="min-w-full text-sm">
            <thead>
              <tr className="border-b border-gray-200 dark:border-gray-800">
                <th className="text-left py-3 px-4 font-semibold">Feature</th>
                <th className="text-left py-3 px-4 font-semibold">Details</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-gray-100 dark:divide-gray-800">
              <tr>
                <td className="py-3 px-4 font-medium">macOS guests</td>
                <td className="py-3 px-4">
                  Full support. Run macOS 12 Monterey through macOS 15 Sequoia.
                </td>
              </tr>
              <tr>
                <td className="py-3 px-4 font-medium">Xcode</td>
                <td className="py-3 px-4">
                  Works perfectly, including iOS Simulator.
                </td>
              </tr>
              <tr>
                <td className="py-3 px-4 font-medium">Development tools</td>
                <td className="py-3 px-4">
                  Homebrew, Node.js, Python, Ruby, Go, Rust — all native ARM.
                </td>
              </tr>
              <tr>
                <td className="py-3 px-4 font-medium">Docker</td>
                <td className="py-3 px-4">
                  Docker Desktop works. Runs ARM64 Linux containers.
                </td>
              </tr>
              <tr>
                <td className="py-3 px-4 font-medium">GUI apps</td>
                <td className="py-3 px-4">
                  Full GPU acceleration. Smooth graphics and animations.
                </td>
              </tr>
              <tr>
                <td className="py-3 px-4 font-medium">Networking</td>
                <td className="py-3 px-4">
                  NAT networking out of the box. Internet access works.
                </td>
              </tr>
              <tr>
                <td className="py-3 px-4 font-medium">Shared folders</td>
                <td className="py-3 px-4">
                  VirtioFS for high-performance file sharing.
                </td>
              </tr>
              <tr>
                <td className="py-3 px-4 font-medium">ARM64 Linux</td>
                <td className="py-3 px-4">
                  Ubuntu, Debian, Fedora ARM editions work well.
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <h3>What Doesn&apos;t Work</h3>
        <div className="not-prose my-8 overflow-x-auto">
          <table className="min-w-full text-sm">
            <thead>
              <tr className="border-b border-gray-200 dark:border-gray-800">
                <th className="text-left py-3 px-4 font-semibold">Feature</th>
                <th className="text-left py-3 px-4 font-semibold">Why</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-gray-100 dark:divide-gray-800">
              <tr>
                <td className="py-3 px-4 font-medium">x86 Windows</td>
                <td className="py-3 px-4">
                  Requires x86 emulation. Use Windows 11 ARM instead (Parallels).
                </td>
              </tr>
              <tr>
                <td className="py-3 px-4 font-medium">x86 Linux</td>
                <td className="py-3 px-4">
                  No x86 emulation. Use ARM64 Linux distributions.
                </td>
              </tr>
              <tr>
                <td className="py-3 px-4 font-medium">Nested virtualization</td>
                <td className="py-3 px-4">
                  Can&apos;t run VMs inside VMs (hardware limitation).
                </td>
              </tr>
              <tr>
                <td className="py-3 px-4 font-medium">USB passthrough</td>
                <td className="py-3 px-4">
                  Not supported in Virtualization.framework.
                </td>
              </tr>
              <tr>
                <td className="py-3 px-4 font-medium">iCloud / Apple ID in guest</td>
                <td className="py-3 px-4">
                  Works but may cause issues. Best to use separate Apple ID.
                </td>
              </tr>
              <tr>
                <td className="py-3 px-4 font-medium">FileVault in guest</td>
                <td className="py-3 px-4">
                  Technically works but not recommended.
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <h3>The &quot;Works, With Caveats&quot; List</h3>
        <ul>
          <li>
            <strong>Windows 11 ARM</strong> — runs via Parallels Desktop
            (commercial). Can use x86 emulation inside Windows for some apps.
          </li>
          <li>
            <strong>Android emulator</strong> — ARM Android emulator works in
            Android Studio, but performance varies.
          </li>
          <li>
            <strong>Multiple displays</strong> — supported but depends on the VM
            software.
          </li>
        </ul>

        <h2 id="performance">Performance Guide</h2>

        <h3>CPU Performance</h3>
        <p>
          macOS VMs on Apple Silicon run at near-native speed. The hypervisor
          overhead is minimal — typically less than 5% for CPU-bound workloads.
          This is because:
        </p>
        <ul>
          <li>No instruction translation (unlike x86 emulation)</li>
          <li>Hardware virtualization extensions in Apple Silicon</li>
          <li>Efficient paravirtualized devices</li>
        </ul>

        <h3>Memory Considerations</h3>
        <p>
          Apple Silicon Macs have unified memory (shared between CPU and GPU).
          When allocating memory to a VM:
        </p>
        <ul>
          <li>
            <strong>8GB Mac</strong> — 4GB for VM is comfortable for light work
          </li>
          <li>
            <strong>16GB Mac</strong> — 8GB for VM allows serious development
          </li>
          <li>
            <strong>32GB+ Mac</strong> — 16GB for VM enables Xcode + Simulator
          </li>
        </ul>

        <div className="not-prose my-8 p-6 border-l-4 border-amber-500 bg-amber-50 dark:bg-amber-950/30 rounded-r-xl">
          <h4 className="font-semibold text-amber-800 dark:text-amber-200 mb-2">
            Memory pressure
          </h4>
          <p className="text-amber-900 dark:text-amber-100 text-sm">
            If your Mac starts swapping heavily, reduce VM memory allocation.
            It&apos;s better to have a VM with less RAM than to have both host
            and guest fighting for memory.
          </p>
        </div>

        <h3>Storage Performance</h3>
        <p>
          Apple Silicon Macs have fast NVMe storage. VMs benefit from:
        </p>
        <ul>
          <li>
            <strong>Sparse disk images</strong> — only consume actual used space
          </li>
          <li>
            <strong>APFS cloning</strong> — instant copy-on-write duplicates
          </li>
          <li>
            <strong>VirtioFS shared folders</strong> — near-native file access
            speed
          </li>
        </ul>

        <h2 id="chip-comparison">M1 vs M2 vs M3 vs M4 for VMs</h2>
        <p>
          All Apple Silicon chips support Virtualization.framework equally.
          The differences are in raw performance:
        </p>

        <div className="not-prose my-8 overflow-x-auto">
          <table className="min-w-full text-sm">
            <thead>
              <tr className="border-b border-gray-200 dark:border-gray-800">
                <th className="text-left py-3 px-4 font-semibold">Chip</th>
                <th className="text-left py-3 px-4 font-semibold">VM Recommendation</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-gray-100 dark:divide-gray-800">
              <tr>
                <td className="py-3 px-4 font-medium">M1 / M1 Pro / M1 Max</td>
                <td className="py-3 px-4">
                  Great for VMs. The baseline for Apple Silicon virtualization.
                </td>
              </tr>
              <tr>
                <td className="py-3 px-4 font-medium">M2 / M2 Pro / M2 Max</td>
                <td className="py-3 px-4">
                  ~15-20% faster than M1. Better memory bandwidth.
                </td>
              </tr>
              <tr>
                <td className="py-3 px-4 font-medium">M3 / M3 Pro / M3 Max</td>
                <td className="py-3 px-4">
                  ~20-30% faster than M2. Dynamic caching improves efficiency.
                </td>
              </tr>
              <tr>
                <td className="py-3 px-4 font-medium">M4 / M4 Pro / M4 Max</td>
                <td className="py-3 px-4">
                  Latest generation. Best performance and efficiency.
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <p>
          <strong>Bottom line:</strong> Any Apple Silicon Mac can run macOS VMs
          well. If you&apos;re buying new and plan to run multiple VMs
          simultaneously, prioritize RAM over CPU tier.
        </p>

        <h2 id="getting-started">Getting Started</h2>

        <h3>Requirements</h3>
        <ul>
          <li>Mac with Apple Silicon (M1, M2, M3, M4, or later)</li>
          <li>macOS 13 Ventura or later for guest VMs</li>
          <li>At least 8GB RAM (16GB+ recommended)</li>
          <li>20GB+ free disk space per VM</li>
        </ul>

        <h3>Create Your First VM</h3>
        <CodeBlock language="bash">
          {`# Download a macOS restore image (IPSW)
# Available from Apple or via the GhostVM Restore Images window

# Create a new VM
vmctl init ~/VMs/my-vm.GhostVM \\
  --cpus 4 \\
  --memory 8 \\
  --disk 64

# Install macOS
vmctl install ~/VMs/my-vm.GhostVM

# Start the VM
vmctl start ~/VMs/my-vm.GhostVM`}
        </CodeBlock>

        <h3>Running Multiple VMs</h3>
        <p>
          Apple Silicon is efficient enough to run multiple VMs simultaneously,
          but be mindful of memory:
        </p>
        <CodeBlock language="bash">
          {`# Clone an existing VM for instant duplication
# Uses APFS copy-on-write — near-zero disk overhead

# In GUI: right-click VM → Clone

# Each clone gets a unique identity (MAC address, machine ID)`}
        </CodeBlock>

        <div className="not-prose mt-12 p-8 bg-gradient-to-br from-ghost-50 to-ghost-100 dark:from-ghost-950 dark:to-gray-900 rounded-2xl">
          <h3 className="text-xl font-semibold mb-4">
            GhostVM for Apple Silicon
          </h3>
          <p className="text-gray-700 dark:text-gray-300 mb-6">
            GhostVM is built specifically for Apple Silicon Macs. Native
            Virtualization.framework integration, instant cloning, snapshots,
            and a scriptable CLI. Free and open source.
          </p>
          <div className="flex flex-col sm:flex-row gap-4">
            <Link
              href="/download"
              className="inline-flex items-center justify-center px-6 py-3 rounded-lg bg-ghost-600 hover:bg-ghost-700 text-white font-medium transition-colors"
            >
              Download for Apple Silicon
            </Link>
            <Link
              href="/docs/getting-started"
              className="inline-flex items-center justify-center px-6 py-3 rounded-lg border border-gray-300 dark:border-gray-700 hover:bg-white dark:hover:bg-gray-800 font-medium transition-colors"
            >
              Get Started Guide
            </Link>
          </div>
        </div>

        <h2>Related Resources</h2>
        <ul>
          <li>
            <Link href="/macos-virtual-machine-for-development">
              macOS Virtual Machine for Development
            </Link>
          </li>
          <li>
            <Link href="/sandboxed-macos-environment">
              Sandboxing Untrusted Code on macOS
            </Link>
          </li>
          <li>
            <Link href="/docs/creating-vms/macos">Creating macOS VMs</Link>
          </li>
          <li>
            <Link href="/docs/architecture">GhostVM Architecture</Link>
          </li>
        </ul>
      </article>
    </div>
  );
}
