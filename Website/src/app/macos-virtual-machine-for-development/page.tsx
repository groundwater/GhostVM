import type { Metadata } from "next";
import Link from "next/link";
import CodeBlock from "@/components/docs/CodeBlock";

export const metadata: Metadata = {
  title: "macOS Virtual Machine for Development - Secure Mac VM Guide",
  description:
    "Set up a macOS virtual machine for secure development on Apple Silicon. Isolate dev environments, test untrusted code, and protect your primary Mac.",
  openGraph: {
    title: "macOS Virtual Machine for Development",
    description:
      "Set up a macOS virtual machine for secure development on Apple Silicon. Isolate dev environments and protect your primary Mac.",
    url: "https://ghostvm.org/macos-virtual-machine-for-development",
    type: "article",
  },
};

export default function MacOSVirtualMachineForDevelopment() {
  return (
    <div className="max-w-4xl mx-auto px-4 sm:px-6 lg:px-8 py-16">
      <article className="prose prose-gray dark:prose-invert prose-lg max-w-none">
        <h1>macOS Virtual Machine for Development</h1>
        <p className="lead text-xl text-gray-600 dark:text-gray-400">
          A Mac virtual machine gives you an isolated macOS environment for
          development — separate from your main system, disposable when needed,
          and secure by default.
        </p>

        <nav className="not-prose my-8 p-6 bg-gray-50 dark:bg-gray-900 rounded-xl">
          <h2 className="text-sm font-semibold text-gray-500 dark:text-gray-400 uppercase tracking-wide mb-4">
            On this page
          </h2>
          <ul className="space-y-2 text-sm">
            <li>
              <a href="#what-is-mac-vm" className="text-ghost-600 dark:text-ghost-400 hover:underline">
                What Is a Mac Virtual Machine?
              </a>
            </li>
            <li>
              <a href="#why-devs-need-vms" className="text-ghost-600 dark:text-ghost-400 hover:underline">
                Why Developers Need Mac VMs
              </a>
            </li>
            <li>
              <a href="#apple-silicon" className="text-ghost-600 dark:text-ghost-400 hover:underline">
                Mac VMs on Apple Silicon
              </a>
            </li>
            <li>
              <a href="#use-cases" className="text-ghost-600 dark:text-ghost-400 hover:underline">
                Development Use Cases
              </a>
            </li>
            <li>
              <a href="#getting-started" className="text-ghost-600 dark:text-ghost-400 hover:underline">
                Getting Started
              </a>
            </li>
          </ul>
        </nav>

        <h2 id="what-is-mac-vm">What Is a Mac Virtual Machine?</h2>
        <p>
          A Mac virtual machine is a complete macOS installation running inside
          a window on your Mac. It has its own:
        </p>
        <ul>
          <li>
            <strong>Filesystem</strong> — separate from your host Mac
          </li>
          <li>
            <strong>User accounts</strong> — isolated credentials and settings
          </li>
          <li>
            <strong>Applications</strong> — install anything without affecting
            your main system
          </li>
          <li>
            <strong>Network identity</strong> — different MAC address and hostname
          </li>
        </ul>
        <p>
          The VM runs on top of a <em>hypervisor</em> — software that creates
          and manages virtual hardware. On Apple Silicon Macs, this is powered
          by Apple&apos;s Virtualization.framework, which provides
          near-native performance.
        </p>

        <h2 id="why-devs-need-vms">Why Developers Need Mac VMs</h2>
        <p>
          If you write code on a Mac, your development machine is constantly
          exposed to risk. Every package you install, every repo you clone,
          every build script you run has access to your entire user account.
        </p>

        <h3>The Problem with Development on Your Main Mac</h3>
        <p>Your primary Mac likely contains:</p>
        <ul>
          <li>SSH keys with access to production servers</li>
          <li>Cloud credentials (AWS, GCP, Azure)</li>
          <li>API tokens and secrets in environment variables</li>
          <li>Browser sessions with authenticated services</li>
          <li>Password manager databases</li>
          <li>Personal documents and photos</li>
        </ul>
        <p>
          When you run <code>npm install</code> or <code>pip install</code>,
          you&apos;re executing code from hundreds of packages — any of which
          could be compromised. A single malicious postinstall script can
          exfiltrate everything.
        </p>

        <h3>How VMs Solve This</h3>
        <p>A development VM creates a security boundary:</p>
        <ul>
          <li>
            <strong>No access to host files</strong> — the VM can only see what
            you explicitly share
          </li>
          <li>
            <strong>No access to host credentials</strong> — your SSH keys and
            tokens stay on the host
          </li>
          <li>
            <strong>Disposable environment</strong> — delete the VM and
            everything inside it is gone
          </li>
          <li>
            <strong>Snapshot and rollback</strong> — restore to a known-good
            state instantly
          </li>
        </ul>

        <div className="not-prose my-8 p-6 border-l-4 border-ghost-500 bg-ghost-50 dark:bg-ghost-950/30 rounded-r-xl">
          <h4 className="font-semibold text-ghost-800 dark:text-ghost-200 mb-2">
            Defense in depth
          </h4>
          <p className="text-ghost-900 dark:text-ghost-100 text-sm">
            Even if malware gains root access inside the VM, it cannot escape to
            your host Mac without exploiting a hypervisor vulnerability. This is
            a much higher bar than user-level compromise.
          </p>
        </div>

        <h2 id="apple-silicon">Mac VMs on Apple Silicon</h2>
        <p>
          Running macOS VMs on Apple Silicon is different from Intel Macs.
          Here&apos;s what you need to know:
        </p>

        <h3>Virtualization.framework</h3>
        <p>
          Apple provides a native virtualization API called
          Virtualization.framework. It&apos;s built into macOS and optimized for
          Apple Silicon. Key benefits:
        </p>
        <ul>
          <li>
            <strong>Near-native performance</strong> — VMs run at close to bare
            metal speed
          </li>
          <li>
            <strong>Low overhead</strong> — minimal CPU and memory overhead
          </li>
          <li>
            <strong>GPU acceleration</strong> — graphics work smoothly in the VM
          </li>
          <li>
            <strong>No third-party kernel extensions</strong> — everything runs
            in userspace
          </li>
        </ul>

        <h3>What Works in Apple Silicon Mac VMs</h3>
        <div className="not-prose my-8 overflow-x-auto">
          <table className="min-w-full text-sm">
            <thead>
              <tr className="border-b border-gray-200 dark:border-gray-800">
                <th className="text-left py-3 px-4 font-semibold">Feature</th>
                <th className="text-left py-3 px-4 font-semibold">Status</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-gray-100 dark:divide-gray-800">
              <tr>
                <td className="py-3 px-4">macOS guest</td>
                <td className="py-3 px-4 text-green-600 dark:text-green-400">
                  Full support (macOS 12+)
                </td>
              </tr>
              <tr>
                <td className="py-3 px-4">Xcode and iOS Simulator</td>
                <td className="py-3 px-4 text-green-600 dark:text-green-400">
                  Works
                </td>
              </tr>
              <tr>
                <td className="py-3 px-4">Homebrew</td>
                <td className="py-3 px-4 text-green-600 dark:text-green-400">
                  Works
                </td>
              </tr>
              <tr>
                <td className="py-3 px-4">Docker Desktop</td>
                <td className="py-3 px-4 text-green-600 dark:text-green-400">
                  Works (runs Linux VMs inside)
                </td>
              </tr>
              <tr>
                <td className="py-3 px-4">VS Code / JetBrains IDEs</td>
                <td className="py-3 px-4 text-green-600 dark:text-green-400">
                  Works
                </td>
              </tr>
              <tr>
                <td className="py-3 px-4">Node.js / Python / Ruby</td>
                <td className="py-3 px-4 text-green-600 dark:text-green-400">
                  Works
                </td>
              </tr>
              <tr>
                <td className="py-3 px-4">x86/Intel software</td>
                <td className="py-3 px-4 text-red-600 dark:text-red-400">
                  No (ARM only)
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <h3>Requirements</h3>
        <ul>
          <li>
            <strong>Mac with Apple Silicon</strong> (M1, M2, M3, M4, or later)
          </li>
          <li>
            <strong>macOS 15 Sequoia or later</strong>
          </li>
          <li>
            <strong>8GB+ RAM</strong> recommended (16GB+ for comfortable
            development)
          </li>
          <li>
            <strong>APFS volume</strong> for instant cloning
          </li>
        </ul>

        <h2 id="use-cases">Development Use Cases</h2>

        <h3>1. Isolated Project Environments</h3>
        <p>
          Create a separate VM for each client or project. Install
          project-specific dependencies without cluttering your main system.
          When the project ends, delete the VM.
        </p>

        <h3>2. Testing Untrusted Code</h3>
        <p>
          Before running <code>npm install</code> on a new project, clone it
          into a VM. If the dependencies do something malicious, your host is
          protected.{" "}
          <Link href="/sandboxed-macos-environment">
            Learn more about sandboxing untrusted code →
          </Link>
        </p>

        <h3>3. Clean Build Environments</h3>
        <p>
          Snapshot a VM with a fresh macOS install and your build tools. Before
          each release, revert to the snapshot for a guaranteed clean build.
          No &quot;works on my machine&quot; issues.
        </p>

        <h3>4. Testing macOS Versions</h3>
        <p>
          Run different macOS versions side by side. Test your app on Sonoma
          while your host runs Sequoia. No need for multiple physical machines.
        </p>

        <h3>5. AI Agent Workspaces</h3>
        <p>
          Give AI coding agents their own VM to work in. They can install
          packages, run tests, and modify code — all isolated from your host.
          If something goes wrong, revert to a snapshot.
        </p>

        <h3>6. Security Research</h3>
        <p>
          Analyze suspicious code or malware in a contained environment.
          The VM provides a safe boundary for investigating potentially
          dangerous software.
        </p>

        <h2 id="getting-started">Getting Started</h2>
        <p>
          Here&apos;s how to set up a macOS development VM:
        </p>

        <h3>1. Create the VM</h3>
        <CodeBlock language="bash">
          {`# Create a new macOS VM with 6 CPUs, 16GB RAM, 128GB disk
vmctl init ~/VMs/dev.GhostVM --cpus 6 --memory 16 --disk 128

# Install macOS from a restore image
vmctl install ~/VMs/dev.GhostVM

# Start the VM
vmctl start ~/VMs/dev.GhostVM`}
        </CodeBlock>

        <h3>2. Set Up Your Dev Environment</h3>
        <p>Inside the VM, install your tools:</p>
        <CodeBlock language="bash">
          {`# Install Xcode Command Line Tools
xcode-select --install

# Install Homebrew
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Install your stack
brew install node python go rust`}
        </CodeBlock>

        <h3>3. Create a Snapshot</h3>
        <p>
          Once your base environment is ready, create a snapshot. You can
          always return to this state:
        </p>
        <CodeBlock language="bash">
          {`vmctl stop ~/VMs/dev.GhostVM
vmctl snapshot ~/VMs/dev.GhostVM create dev-ready`}
        </CodeBlock>

        <h3>4. Clone for New Projects</h3>
        <p>
          When starting a new project, clone your template VM. APFS
          copy-on-write makes this instant:
        </p>
        <CodeBlock language="bash">
          {`# In the GUI: right-click VM → Clone
# The clone uses almost no additional disk space initially`}
        </CodeBlock>

        <h3>5. Share Files with the Host</h3>
        <p>
          Use shared folders to access project files from your host:
        </p>
        <CodeBlock language="bash">
          {`vmctl start ~/VMs/dev.GhostVM --headless \\
  --shared-folder ~/Projects/my-app --read-only`}
        </CodeBlock>

        <h2>Performance Tips</h2>
        <ul>
          <li>
            <strong>Allocate enough RAM</strong> — 8GB minimum for development,
            16GB for Xcode work
          </li>
          <li>
            <strong>Use multiple cores</strong> — 4-6 CPUs is a good balance
          </li>
          <li>
            <strong>Store VMs on fast storage</strong> — internal SSD, not
            external drives
          </li>
          <li>
            <strong>Use sparse disk images</strong> — only consumes actual used
            space
          </li>
          <li>
            <strong>Suspend instead of shutdown</strong> — resume is faster than
            cold boot
          </li>
        </ul>

        <div className="not-prose mt-12 p-8 bg-gradient-to-br from-ghost-50 to-ghost-100 dark:from-ghost-950 dark:to-gray-900 rounded-2xl">
          <h3 className="text-xl font-semibold mb-4">
            Try GhostVM
          </h3>
          <p className="text-gray-700 dark:text-gray-300 mb-6">
            GhostVM is a free, open-source Mac VM manager built for developers.
            Native macOS app, instant cloning, snapshots, and a scriptable CLI.
          </p>
          <div className="flex flex-col sm:flex-row gap-4">
            <Link
              href="/download"
              className="inline-flex items-center justify-center px-6 py-3 rounded-lg bg-ghost-600 hover:bg-ghost-700 text-white font-medium transition-colors"
            >
              Download GhostVM
            </Link>
            <Link
              href="/docs/getting-started"
              className="inline-flex items-center justify-center px-6 py-3 rounded-lg border border-gray-300 dark:border-gray-700 hover:bg-white dark:hover:bg-gray-800 font-medium transition-colors"
            >
              Read the Docs
            </Link>
          </div>
        </div>

        <h2>Related Resources</h2>
        <ul>
          <li>
            <Link href="/sandboxed-macos-environment">
              Sandboxing Untrusted Code on macOS
            </Link>
          </li>
          <li>
            <Link href="/docs/creating-vms/macos">Creating macOS VMs</Link>
          </li>
          <li>
            <Link href="/docs/vm-clone">Instant VM Cloning</Link>
          </li>
        </ul>
      </article>
    </div>
  );
}
