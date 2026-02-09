import Image from "next/image"
import Link from "next/link"

export default function Hero() {
  return (
    <section className="py-20 sm:py-28">
      <div className="max-w-6xl mx-auto px-4 sm:px-6 lg:px-8 text-center">
        <h1 className="text-4xl sm:text-5xl lg:text-6xl font-bold tracking-tight mb-6">
          Agentic Workspaces
          <br />
          <span className="text-ghost-600 dark:text-ghost-400">
            Virtualization for macOS
          </span>
        </h1>
        <p className="text-lg sm:text-xl text-gray-600 dark:text-gray-400 max-w-2xl mx-auto mb-10">
          Each workspace is an isolated macOS VM with its own tools, files, and
          environment. Deep host integration means switching between them is as
          easy as switching apps. Run as many as you need in parallel.
        </p>
        <div className="flex flex-col sm:flex-row items-center justify-center gap-4 mb-14">
          <Link
            href="/download"
            className="inline-flex items-center px-6 py-3 rounded-lg bg-ghost-600 hover:bg-ghost-700 text-white font-medium transition-colors"
          >
            Download GhostVM
          </Link>
          <Link
            href="/docs/getting-started"
            className="inline-flex items-center px-6 py-3 rounded-lg border border-gray-300 dark:border-gray-700 hover:bg-gray-50 dark:hover:bg-gray-900 font-medium transition-colors"
          >
            Get Started
          </Link>
        </div>

        {/* Hero screenshot */}
        <div className="max-w-4xl mx-auto">
          <div className="rounded-xl overflow-hidden shadow-2xl ring-1 ring-black/10 dark:ring-white/10">
            <Image
              src="/images/hero-screenshot.png"
              alt="VS Code running inside a GhostVM virtual machine on macOS"
              width={2992}
              height={1934}
              className="w-full h-auto block"
              priority
            />
          </div>
        </div>
      </div>
    </section>
  )
}
