import type { Metadata } from "next";
import Link from "next/link";
import CodeBlock from "@/components/docs/CodeBlock";

export const metadata: Metadata = {
  title: "Sandboxing Untrusted Code on macOS - Secure Dev Environment Guide",
  description:
    "How to safely run untrusted code on Mac. Isolate npm packages, GitHub repos, and AI agents in sandboxed macOS environments. Threat models and VM workflows.",
  openGraph: {
    title: "Sandboxing Untrusted Code on macOS",
    description:
      "How to safely run untrusted code on Mac. Isolate npm packages, GitHub repos, and AI agents in sandboxed macOS environments.",
    url: "https://ghostvm.org/sandboxed-macos-environment",
    type: "article",
  },
};

export default function SandboxedMacOSEnvironment() {
  return (
    <div className="max-w-4xl mx-auto px-4 sm:px-6 lg:px-8 py-16">
      <article className="prose prose-gray dark:prose-invert prose-lg max-w-none">
        <h1>Sandboxing Untrusted Code on macOS</h1>
        <p className="lead text-xl text-gray-600 dark:text-gray-400">
          Every <code>npm install</code>, every cloned repo, every AI-generated
          script is a potential attack vector. Here&apos;s how to run untrusted
          code on your Mac without risking your data, credentials, or sanity.
        </p>

        <nav className="not-prose my-8 p-6 bg-gray-50 dark:bg-gray-900 rounded-xl">
          <h2 className="text-sm font-semibold text-gray-500 dark:text-gray-400 uppercase tracking-wide mb-4">
            On this page
          </h2>
          <ul className="space-y-2 text-sm">
            <li>
              <a href="#threat-model" className="text-ghost-600 dark:text-ghost-400 hover:underline">
                The Threat Model
              </a>
            </li>
            <li>
              <a href="#isolation-options" className="text-ghost-600 dark:text-ghost-400 hover:underline">
                Isolation Options on macOS
              </a>
            </li>
            <li>
              <a href="#why-vms" className="text-ghost-600 dark:text-ghost-400 hover:underline">
                Why VMs Beat Containers for macOS Isolation
              </a>
            </li>
            <li>
              <a href="#real-world-scenarios" className="text-ghost-600 dark:text-ghost-400 hover:underline">
                Real-World Scenarios
              </a>
            </li>
            <li>
              <a href="#workflow" className="text-ghost-600 dark:text-ghost-400 hover:underline">
                A Practical Sandboxing Workflow
              </a>
            </li>
          </ul>
        </nav>

        <h2 id="threat-model">The Threat Model</h2>
        <p>
          Before choosing an isolation strategy, you need to understand what
          you&apos;re protecting against. Most developers face three categories
          of risk:
        </p>

        <h3>1. Supply Chain Attacks</h3>
        <p>
          That innocent-looking npm package? It might run arbitrary code during
          installation. In 2024 alone, thousands of malicious packages were
          discovered on npm, PyPI, and other registries. The{" "}
          <code>postinstall</code> script in a dependency&apos;s dependency can:
        </p>
        <ul>
          <li>Read your SSH keys and environment variables</li>
          <li>Exfiltrate browser cookies and credentials</li>
          <li>Install persistent backdoors</li>
          <li>Encrypt files for ransom</li>
        </ul>

        <h3>2. Untrusted Repositories</h3>
        <p>
          Cloning a GitHub repo to &quot;just try it out&quot; means running
          someone else&apos;s build scripts, test runners, and git hooks. Even
          reviewing code in VS Code can trigger malicious extensions or
          workspace settings.
        </p>

        <h3>3. AI-Generated Code</h3>
        <p>
          AI coding assistants and agents produce code you haven&apos;t
          reviewed. When an agent runs <code>npm install</code> or executes
          shell commands, you&apos;re trusting both the AI and every package it
          chose to depend on. This is a rapidly growing attack surface.
        </p>

        <div className="not-prose my-8 p-6 border-l-4 border-amber-500 bg-amber-50 dark:bg-amber-950/30 rounded-r-xl">
          <h4 className="font-semibold text-amber-800 dark:text-amber-200 mb-2">
            The uncomfortable truth
          </h4>
          <p className="text-amber-900 dark:text-amber-100 text-sm">
            If malicious code runs on your Mac with your user privileges, it has
            access to everything you do: your documents, your browser sessions,
            your cloud credentials, your SSH keys. macOS sandboxing for
            App Store apps doesn&apos;t help here — you&apos;re running code
            directly.
          </p>
        </div>

        <h2 id="isolation-options">Isolation Options on macOS</h2>
        <p>
          Let&apos;s evaluate the realistic options for isolating untrusted code
          on macOS:
        </p>

        <h3>Separate User Accounts</h3>
        <p>
          <strong>Isolation level: Low</strong>
        </p>
        <p>
          You can create a separate macOS user for untrusted work. This provides
          filesystem isolation but shares the same kernel, network stack, and
          hardware. Malware can still:
        </p>
        <ul>
          <li>Exploit kernel vulnerabilities</li>
          <li>Access network resources</li>
          <li>Interact with other processes via IPC</li>
        </ul>
        <p>
          <em>Verdict: Better than nothing, but not real isolation.</em>
        </p>

        <h3>Docker Containers</h3>
        <p>
          <strong>Isolation level: Medium (on Linux), Low (on macOS)</strong>
        </p>
        <p>
          Docker on macOS runs a Linux VM under the hood (via Apple&apos;s
          Virtualization.framework or QEMU). Your containers run inside that
          Linux VM, which means:
        </p>
        <ul>
          <li>You can&apos;t run macOS software in containers</li>
          <li>GUI apps don&apos;t work</li>
          <li>
            You&apos;re isolated from macOS, but you&apos;re sharing a Linux
            kernel with all other containers
          </li>
        </ul>
        <p>
          Docker is great for deploying Linux services, but it&apos;s not a
          macOS sandbox. If you need to test macOS-specific behavior, run Xcode,
          or use native Mac tools, containers won&apos;t help.
        </p>
        <p>
          <em>
            Verdict: Good for Linux workloads. Not a macOS isolation solution.
          </em>
        </p>

        <h3>macOS Virtual Machines</h3>
        <p>
          <strong>Isolation level: High</strong>
        </p>
        <p>
          A full macOS VM provides the strongest isolation available on Apple
          Silicon. Each VM has:
        </p>
        <ul>
          <li>Its own kernel instance</li>
          <li>Separate filesystem and user data</li>
          <li>Isolated network identity</li>
          <li>No access to host files (unless explicitly shared)</li>
        </ul>
        <p>
          Even if malware achieves root access inside the VM, it cannot escape
          to the host without a hypervisor vulnerability (extremely rare).
        </p>
        <p>
          <em>
            Verdict: The right choice for running untrusted macOS code.
          </em>
        </p>

        <h2 id="why-vms">Why VMs Beat Containers for macOS Isolation</h2>

        <div className="not-prose my-8 overflow-x-auto">
          <table className="min-w-full text-sm">
            <thead>
              <tr className="border-b border-gray-200 dark:border-gray-800">
                <th className="text-left py-3 px-4 font-semibold">Capability</th>
                <th className="text-left py-3 px-4 font-semibold">Docker</th>
                <th className="text-left py-3 px-4 font-semibold">macOS VM</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-gray-100 dark:divide-gray-800">
              <tr>
                <td className="py-3 px-4">Run macOS apps</td>
                <td className="py-3 px-4 text-red-600 dark:text-red-400">No</td>
                <td className="py-3 px-4 text-green-600 dark:text-green-400">Yes</td>
              </tr>
              <tr>
                <td className="py-3 px-4">Run Xcode / Swift</td>
                <td className="py-3 px-4 text-red-600 dark:text-red-400">No</td>
                <td className="py-3 px-4 text-green-600 dark:text-green-400">Yes</td>
              </tr>
              <tr>
                <td className="py-3 px-4">GUI support</td>
                <td className="py-3 px-4 text-red-600 dark:text-red-400">No</td>
                <td className="py-3 px-4 text-green-600 dark:text-green-400">Yes</td>
              </tr>
              <tr>
                <td className="py-3 px-4">Kernel isolation</td>
                <td className="py-3 px-4 text-amber-600 dark:text-amber-400">Shared Linux kernel</td>
                <td className="py-3 px-4 text-green-600 dark:text-green-400">Separate kernel</td>
              </tr>
              <tr>
                <td className="py-3 px-4">Network isolation</td>
                <td className="py-3 px-4 text-amber-600 dark:text-amber-400">Configurable</td>
                <td className="py-3 px-4 text-green-600 dark:text-green-400">Full NAT isolation</td>
              </tr>
              <tr>
                <td className="py-3 px-4">Snapshot / rollback</td>
                <td className="py-3 px-4 text-amber-600 dark:text-amber-400">Image layers</td>
                <td className="py-3 px-4 text-green-600 dark:text-green-400">Full disk snapshots</td>
              </tr>
              <tr>
                <td className="py-3 px-4">Startup time</td>
                <td className="py-3 px-4 text-green-600 dark:text-green-400">Seconds</td>
                <td className="py-3 px-4 text-amber-600 dark:text-amber-400">~10 seconds</td>
              </tr>
            </tbody>
          </table>
        </div>

        <p>
          The startup time tradeoff is real, but for security-sensitive work,
          it&apos;s worth it. And with modern Apple Silicon, VM boot times are
          fast enough for practical use.
        </p>

        <h2 id="real-world-scenarios">Real-World Scenarios</h2>

        <h3>Scenario 1: Evaluating a Random GitHub Project</h3>
        <p>
          You found a cool tool on GitHub. The README says &quot;just run{" "}
          <code>make install</code>&quot;. But you&apos;ve never heard of this
          developer, and the repo has 47 stars.
        </p>
        <p>
          <strong>Safe approach:</strong> Clone and build inside a sandboxed VM.
          If the Makefile does something sketchy, your host Mac is unaffected.
          If it&apos;s legit, you can either keep using the VM or install it on
          your host with confidence.
        </p>

        <h3>Scenario 2: Running npm install on a New Project</h3>
        <p>
          You&apos;re about to work on a client&apos;s codebase. The{" "}
          <code>package.json</code> has 200+ dependencies, and you have no idea
          what&apos;s in the dependency tree.
        </p>
        <p>
          <strong>Safe approach:</strong> Run <code>npm install</code> in a VM
          with no access to your SSH keys, credentials, or sensitive files.
          Share only the project folder (read-only if possible).
        </p>

        <h3>Scenario 3: Letting an AI Agent Code for You</h3>
        <p>
          You&apos;re using an AI coding agent that can execute shell commands
          and install packages. The agent is helpful, but you don&apos;t want it
          to have access to your entire system.
        </p>
        <p>
          <strong>Safe approach:</strong> Give the agent access to a sandboxed
          VM workspace. It can install packages, run tests, and modify code —
          all isolated from your host. If something goes wrong, revert to a
          clean snapshot.
        </p>

        <h2 id="workflow">A Practical Sandboxing Workflow</h2>
        <p>
          Here&apos;s a workflow for running untrusted code using macOS VMs:
        </p>

        <h3>1. Create a Base VM</h3>
        <p>
          Set up a clean macOS VM with your development tools: Xcode CLI, Node,
          Python, Homebrew, etc. This is your template.
        </p>

        <CodeBlock language="bash">
          {`# Create a new VM
vmctl init ~/VMs/dev-template.GhostVM --cpus 4 --memory 8 --disk 64
vmctl install ~/VMs/dev-template.GhostVM
vmctl start ~/VMs/dev-template.GhostVM

# Install your tools inside the VM, then shut down
vmctl stop ~/VMs/dev-template.GhostVM

# Create a "clean" snapshot
vmctl snapshot ~/VMs/dev-template.GhostVM create clean-state`}
        </CodeBlock>

        <h3>2. Clone for Each Untrusted Project</h3>
        <p>
          When you need to work on something untrusted, clone the template.
          APFS copy-on-write makes this instant and space-efficient.
        </p>

        <CodeBlock language="bash">
          {`# Clone the template (instant, ~0 disk overhead)
# In the GUI: right-click the VM → Clone

# Or use Finder to duplicate the .GhostVM bundle`}
        </CodeBlock>

        <h3>3. Work in Isolation</h3>
        <p>
          Start the cloned VM and do your untrusted work there. Use shared
          folders (read-only) to access project files if needed.
        </p>

        <CodeBlock language="bash">
          {`# Start with a shared folder
vmctl start ~/VMs/untrusted-project.GhostVM \\
  --shared-folder ~/Projects/client-repo --read-only`}
        </CodeBlock>

        <h3>4. Revert or Dispose</h3>
        <p>
          When you&apos;re done, either revert to the clean snapshot or delete
          the VM entirely. Nothing persists to your host.
        </p>

        <CodeBlock language="bash">
          {`# Option A: Revert to clean state
vmctl snapshot ~/VMs/untrusted-project.GhostVM revert clean-state

# Option B: Delete the VM entirely
rm -rf ~/VMs/untrusted-project.GhostVM`}
        </CodeBlock>

        <h2>The Bottom Line</h2>
        <p>
          If you&apos;re a developer on macOS, you&apos;re running untrusted
          code regularly — every <code>npm install</code>, every{" "}
          <code>pip install</code>, every <code>brew install</code>. Most of the
          time it&apos;s fine. But when it&apos;s not, the consequences can be
          severe.
        </p>
        <p>
          macOS virtual machines give you real isolation: separate kernel,
          separate filesystem, separate network identity. They&apos;re the
          practical answer to &quot;how do I run this without risking my
          machine?&quot;
        </p>

        <div className="not-prose mt-12 p-8 bg-gradient-to-br from-ghost-50 to-ghost-100 dark:from-ghost-950 dark:to-gray-900 rounded-2xl">
          <h3 className="text-xl font-semibold mb-4">
            GhostVM: Built for This
          </h3>
          <p className="text-gray-700 dark:text-gray-300 mb-6">
            GhostVM is a free, open-source Mac VM app designed for exactly this
            workflow. Instant cloning, snapshots, shared folders, and a
            scriptable CLI for automation.
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
              Get Started
            </Link>
          </div>
        </div>

        <h2>Related Resources</h2>
        <ul>
          <li>
            <Link href="/docs/vm-clone">Instant VM Cloning with APFS</Link>
          </li>
          <li>
            <Link href="/docs/snapshots">Managing VM Snapshots</Link>
          </li>
          <li>
            <Link href="/docs/services/shared-folders">
              Shared Folders Configuration
            </Link>
          </li>
          <li>
            <Link href="/docs/cli">CLI Reference for Automation</Link>
          </li>
        </ul>
      </article>
    </div>
  );
}
