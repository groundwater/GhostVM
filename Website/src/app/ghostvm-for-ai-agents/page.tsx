import type { Metadata } from "next";
import Link from "next/link";
import CodeBlock from "@/components/docs/CodeBlock";

export const metadata: Metadata = {
  title: "GhostVM for AI Agents - Isolated macOS Workspaces for Autonomous Coding",
  description:
    "Give AI coding agents their own isolated Mac environment. GhostVM provides full macOS VMs with instant cloning, snapshots, and programmatic control for safe agentic workflows.",
  openGraph: {
    title: "GhostVM for AI Agents",
    description:
      "Give AI coding agents their own isolated Mac environment. Full macOS VMs with instant cloning, snapshots, and programmatic control.",
    url: "https://ghostvm.org/ghostvm-for-ai-agents",
    type: "article",
  },
};

export default function GhostVMForAIAgents() {
  return (
    <div className="max-w-4xl mx-auto px-4 sm:px-6 lg:px-8 py-16">
      <article className="prose prose-gray dark:prose-invert prose-lg max-w-none">
        <h1>GhostVM for AI Agents</h1>
        <p className="lead text-xl text-gray-600 dark:text-gray-400">
          AI coding agents need to install packages, run builds, execute tests,
          and modify files. Give them their own Mac — isolated, disposable, and
          under your control.
        </p>

        <nav className="not-prose my-8 p-6 bg-gray-50 dark:bg-gray-900 rounded-xl">
          <h2 className="text-sm font-semibold text-gray-500 dark:text-gray-400 uppercase tracking-wide mb-4">
            On this page
          </h2>
          <ul className="space-y-2 text-sm">
            <li>
              <a href="#the-agent-problem" className="text-ghost-600 dark:text-ghost-400 hover:underline">
                The Agent Problem
              </a>
            </li>
            <li>
              <a href="#why-not-containers" className="text-ghost-600 dark:text-ghost-400 hover:underline">
                Why Containers Don&apos;t Work
              </a>
            </li>
            <li>
              <a href="#why-not-sandboxing" className="text-ghost-600 dark:text-ghost-400 hover:underline">
                Why macOS Sandboxing Doesn&apos;t Help
              </a>
            </li>
            <li>
              <a href="#the-vm-solution" className="text-ghost-600 dark:text-ghost-400 hover:underline">
                The VM Solution: One Mac Per Agent
              </a>
            </li>
            <li>
              <a href="#ghostvm-workflow" className="text-ghost-600 dark:text-ghost-400 hover:underline">
                The GhostVM Agent Workflow
              </a>
            </li>
          </ul>
        </nav>

        <h2 id="the-agent-problem">The Agent Problem</h2>
        <p>
          AI coding agents like Claude, Cursor, Devin, and others are
          increasingly autonomous. They don&apos;t just suggest code — they
          execute it. A typical agent session might:
        </p>
        <ul>
          <li>
            Clone a repository and run <code>npm install</code>
          </li>
          <li>
            Install system dependencies via <code>brew</code>
          </li>
          <li>
            Execute build scripts and run tests
          </li>
          <li>
            Modify dozens of files across a codebase
          </li>
          <li>
            Run arbitrary shell commands to debug issues
          </li>
        </ul>
        <p>
          This is powerful, but it&apos;s also dangerous. When an agent runs on
          your Mac with your user privileges, it has access to everything you
          do:
        </p>
        <ul>
          <li>Your SSH keys and cloud credentials</li>
          <li>Your browser sessions and cookies</li>
          <li>Your password manager database</li>
          <li>Every file on your system</li>
        </ul>

        <div className="not-prose my-8 p-6 border-l-4 border-amber-500 bg-amber-50 dark:bg-amber-950/30 rounded-r-xl">
          <h4 className="font-semibold text-amber-800 dark:text-amber-200 mb-2">
            The trust problem
          </h4>
          <p className="text-amber-900 dark:text-amber-100 text-sm">
            You might trust the AI model, but do you trust every package it
            chooses to install? Every build script in every dependency? Agents
            amplify supply chain risk because they install and execute code
            without human review.
          </p>
        </div>

        <h2 id="why-not-containers">Why Containers Don&apos;t Work</h2>
        <p>
          Docker is a common suggestion for isolating agent workloads. But on
          macOS, containers have fundamental limitations:
        </p>

        <h3>Containers Run Linux, Not macOS</h3>
        <p>
          Docker on Mac runs a Linux VM under the hood. Your containers execute
          inside that Linux environment. This means:
        </p>
        <ul>
          <li>
            <strong>No macOS apps</strong> — can&apos;t run Xcode, Swift, or
            any native Mac software
          </li>
          <li>
            <strong>No GUI</strong> — agents can&apos;t interact with visual
            interfaces
          </li>
          <li>
            <strong>No Apple frameworks</strong> — no Core Data, SwiftUI,
            Metal, or any Apple SDK
          </li>
          <li>
            <strong>Different architecture behavior</strong> — Linux ARM64 is
            not the same as macOS ARM64
          </li>
        </ul>

        <h3>Many Development Tasks Require macOS</h3>
        <p>If an agent needs to:</p>
        <ul>
          <li>Build an iOS or macOS app</li>
          <li>Run the iOS Simulator</li>
          <li>Test macOS-specific behavior</li>
          <li>Use Homebrew packages that don&apos;t have Linux equivalents</li>
          <li>Work with macOS system APIs</li>
        </ul>
        <p>
          ...then containers are not an option. The agent needs a real macOS
          environment.
        </p>

        <h3>Container Isolation Is Weaker</h3>
        <p>
          Even for Linux workloads, Docker containers share a kernel with each
          other. A kernel exploit in one container can affect all others.
          Containers are designed for deployment density, not security
          isolation.
        </p>

        <h2 id="why-not-sandboxing">Why macOS Sandboxing Doesn&apos;t Help</h2>
        <p>
          macOS has a powerful sandboxing system — it&apos;s what keeps App
          Store apps from accessing your files without permission. But this
          doesn&apos;t apply to command-line development:
        </p>

        <h3>Terminal Runs with Full User Privileges</h3>
        <p>
          When an agent executes commands via Terminal, zsh, or any CLI tool,
          those commands run as your user. They have access to:
        </p>
        <ul>
          <li>
            <code>~/.ssh/</code> — your SSH keys
          </li>
          <li>
            <code>~/.aws/</code>, <code>~/.config/gcloud/</code> — cloud
            credentials
          </li>
          <li>
            <code>~/Library/</code> — app data, keychains, browser profiles
          </li>
          <li>Everything else your user account can access</li>
        </ul>

        <h3>No Sandbox for npm/pip/brew</h3>
        <p>
          Package managers don&apos;t run in sandboxes. When an agent runs{" "}
          <code>npm install</code>, every postinstall script executes with full
          user privileges. There&apos;s no prompt, no permission dialog, no
          protection.
        </p>

        <h3>You Can&apos;t Sandbox Development Tools</h3>
        <p>
          Development inherently requires broad system access: reading files,
          writing files, executing binaries, accessing the network. A
          meaningfully sandboxed development environment would be too
          restrictive to use.
        </p>

        <h2 id="the-vm-solution">The VM Solution: One Mac Per Agent</h2>
        <p>
          The answer is to give each agent its own complete Mac environment —
          a virtual machine running macOS. This provides:
        </p>

        <div className="not-prose my-8 overflow-x-auto">
          <table className="min-w-full text-sm">
            <thead>
              <tr className="border-b border-gray-200 dark:border-gray-800">
                <th className="text-left py-3 px-4 font-semibold">Property</th>
                <th className="text-left py-3 px-4 font-semibold">Your Mac</th>
                <th className="text-left py-3 px-4 font-semibold">Agent VM</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-gray-100 dark:divide-gray-800">
              <tr>
                <td className="py-3 px-4">SSH keys</td>
                <td className="py-3 px-4">Your production keys</td>
                <td className="py-3 px-4 text-green-600 dark:text-green-400">
                  None (or limited)
                </td>
              </tr>
              <tr>
                <td className="py-3 px-4">Cloud credentials</td>
                <td className="py-3 px-4">Full access</td>
                <td className="py-3 px-4 text-green-600 dark:text-green-400">
                  None (or scoped tokens)
                </td>
              </tr>
              <tr>
                <td className="py-3 px-4">Browser sessions</td>
                <td className="py-3 px-4">All your accounts</td>
                <td className="py-3 px-4 text-green-600 dark:text-green-400">
                  Fresh browser
                </td>
              </tr>
              <tr>
                <td className="py-3 px-4">Personal files</td>
                <td className="py-3 px-4">Everything</td>
                <td className="py-3 px-4 text-green-600 dark:text-green-400">
                  Only shared folders
                </td>
              </tr>
              <tr>
                <td className="py-3 px-4">If compromised</td>
                <td className="py-3 px-4 text-red-600 dark:text-red-400">
                  Total exposure
                </td>
                <td className="py-3 px-4 text-green-600 dark:text-green-400">
                  Delete VM, start fresh
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <h3>Real Kernel Isolation</h3>
        <p>
          Each VM runs its own macOS kernel. Even if malware gains root access
          inside the VM, it cannot escape to your host without exploiting a
          hypervisor vulnerability — a much higher bar than user-level
          compromise.
        </p>

        <h3>Full macOS Compatibility</h3>
        <p>
          Unlike containers, a macOS VM can run everything: Xcode, iOS
          Simulator, Swift, SwiftUI, Homebrew, any native Mac app. The agent
          has a complete development environment.
        </p>

        <h3>Disposable and Reproducible</h3>
        <p>
          VMs can be cloned instantly (thanks to APFS copy-on-write), snapshotted
          at any point, and deleted when done. If an agent makes a mess,
          revert to a clean state in seconds.
        </p>

        <h2 id="ghostvm-workflow">The GhostVM Agent Workflow</h2>
        <p>
          Here&apos;s how to set up isolated environments for AI agents using
          GhostVM:
        </p>

        <h3>1. Create a Template VM</h3>
        <p>
          Set up a macOS VM with your development tools installed. This becomes
          your template for agent workspaces.
        </p>
        <CodeBlock language="bash">
          {`# Create a VM with development-ready specs
vmctl init ~/VMs/agent-template.GhostVM --cpus 4 --memory 8 --disk 64
vmctl install ~/VMs/agent-template.GhostVM

# Start it and install your tools
vmctl start ~/VMs/agent-template.GhostVM

# Inside the VM: install Xcode CLI, Homebrew, Node, Python, etc.
# Then shut down and snapshot

vmctl stop ~/VMs/agent-template.GhostVM
vmctl snapshot ~/VMs/agent-template.GhostVM create ready`}
        </CodeBlock>

        <h3>2. Clone for Each Agent Session</h3>
        <p>
          When an agent needs a workspace, clone the template. APFS
          copy-on-write means the clone is instant and uses minimal disk space.
        </p>
        <CodeBlock language="bash">
          {`# Clone the template (instant, ~0 initial disk overhead)
# In GhostVM GUI: right-click VM → Clone

# Or duplicate the bundle in Finder
cp -c ~/VMs/agent-template.GhostVM ~/VMs/agent-session-001.GhostVM`}
        </CodeBlock>

        <h3>3. Start with Limited Access</h3>
        <p>
          Start the agent&apos;s VM with only the folders it needs, mounted
          read-only when possible.
        </p>
        <CodeBlock language="bash">
          {`# Share only the project folder, read-only
vmctl start ~/VMs/agent-session-001.GhostVM \\
  --shared-folder ~/Projects/my-app --read-only

# Or read-write if the agent needs to modify files
vmctl start ~/VMs/agent-session-001.GhostVM \\
  --shared-folder ~/Projects/my-app`}
        </CodeBlock>

        <h3>4. Let the Agent Work</h3>
        <p>
          The agent can now install packages, run builds, execute tests, and
          modify code — all within its isolated VM. It has no access to your
          host files, credentials, or accounts.
        </p>

        <h3>5. Snapshot Before Risky Operations</h3>
        <p>
          Before the agent does something potentially destructive, create a
          snapshot. If things go wrong, revert instantly.
        </p>
        <CodeBlock language="bash">
          {`# Create a checkpoint
vmctl snapshot ~/VMs/agent-session-001.GhostVM create before-refactor

# If things go wrong
vmctl snapshot ~/VMs/agent-session-001.GhostVM revert before-refactor`}
        </CodeBlock>

        <h3>6. Clean Up</h3>
        <p>
          When the session is done, either revert to the template state or
          delete the VM entirely. Nothing persists to your host.
        </p>
        <CodeBlock language="bash">
          {`# Option A: Restore to clean state for reuse
vmctl snapshot ~/VMs/agent-session-001.GhostVM revert ready

# Option B: Delete the VM entirely
rm -rf ~/VMs/agent-session-001.GhostVM`}
        </CodeBlock>

        <h2>Why This Matters</h2>
        <p>
          As AI agents become more capable, they&apos;ll need more access to
          do useful work. But more access means more risk. The solution
          isn&apos;t to limit agents — it&apos;s to give them powerful
          environments that are isolated from your critical systems.
        </p>
        <p>
          A macOS VM gives an agent everything it needs: a full operating
          system, native tools, GUI access, network connectivity. And it gives
          you everything you need: isolation, snapshots, disposability, and
          control.
        </p>
        <p>
          <strong>
            Give each agent its own Mac. Let it work freely. Keep your real Mac
            safe.
          </strong>
        </p>

        <div className="not-prose mt-12 p-8 bg-gradient-to-br from-ghost-50 to-ghost-100 dark:from-ghost-950 dark:to-gray-900 rounded-2xl">
          <h3 className="text-xl font-semibold mb-4">
            Get Started with GhostVM
          </h3>
          <p className="text-gray-700 dark:text-gray-300 mb-6">
            GhostVM is free, open-source, and built for exactly this workflow.
            Native macOS app with instant cloning, snapshots, and a scriptable
            CLI.
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
            <Link href="/sandboxed-macos-environment">
              Sandboxing Untrusted Code on macOS
            </Link>
          </li>
          <li>
            <Link href="/macos-virtual-machine-for-development">
              macOS Virtual Machines for Development
            </Link>
          </li>
          <li>
            <Link href="/docs/snapshots">Managing VM Snapshots</Link>
          </li>
        </ul>
      </article>
    </div>
  );
}
