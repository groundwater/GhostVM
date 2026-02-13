import Link from "next/link"
import { siteConfig } from "@/config/site"

export default function Footer() {
  return (
    <footer className="border-t border-gray-200 dark:border-gray-800 bg-gray-50 dark:bg-gray-950">
      <div className="max-w-6xl mx-auto px-4 sm:px-6 lg:px-8 py-12">
        <div className="grid grid-cols-1 md:grid-cols-3 gap-8">
          <div>
            <h3 className="text-sm font-semibold text-gray-900 dark:text-white mb-3">
              Product
            </h3>
            <ul className="space-y-2">
              <li>
                <Link
                  href="/download"
                  className="text-sm text-gray-600 dark:text-gray-400 hover:text-gray-900 dark:hover:text-white"
                >
                  Download
                </Link>
              </li>
              <li>
                <Link
                  href="/docs/getting-started"
                  className="text-sm text-gray-600 dark:text-gray-400 hover:text-gray-900 dark:hover:text-white"
                >
                  Documentation
                </Link>
              </li>
              <li>
                <Link
                  href="/docs/cli"
                  className="text-sm text-gray-600 dark:text-gray-400 hover:text-gray-900 dark:hover:text-white"
                >
                  CLI Reference
                </Link>
              </li>
              <li>
                <Link
                  href="/docs/mcp"
                  className="text-sm text-gray-600 dark:text-gray-400 hover:text-gray-900 dark:hover:text-white"
                >
                  MCP Server
                </Link>
              </li>
            </ul>
          </div>
          <div>
            <h3 className="text-sm font-semibold text-gray-900 dark:text-white mb-3">
              Resources
            </h3>
            <ul className="space-y-2">
              <li>
                <Link
                  href="/blog"
                  className="text-sm text-gray-600 dark:text-gray-400 hover:text-gray-900 dark:hover:text-white"
                >
                  Blog
                </Link>
              </li>
              <li>
                <a
                  href={siteConfig.repo}
                  className="text-sm text-gray-600 dark:text-gray-400 hover:text-gray-900 dark:hover:text-white"
                  target="_blank"
                  rel="noopener noreferrer"
                >
                  GitHub
                </a>
              </li>
              <li>
                <a
                  href={`${siteConfig.repo}/issues`}
                  className="text-sm text-gray-600 dark:text-gray-400 hover:text-gray-900 dark:hover:text-white"
                  target="_blank"
                  rel="noopener noreferrer"
                >
                  Issues
                </a>
              </li>
            </ul>
          </div>
          <div>
            <h3 className="text-sm font-semibold text-gray-900 dark:text-white mb-3">
              Legal
            </h3>
            <p className="text-sm text-gray-600 dark:text-gray-400">
              Apple&apos;s EULA requires macOS guests to run on Apple-branded hardware.
            </p>
          </div>
        </div>
        <div className="mt-8 pt-8 border-t border-gray-200 dark:border-gray-800 text-center text-sm text-gray-500 space-y-1">
          <p>GhostVM &mdash; Native macOS Virtual Machines for Apple Silicon</p>
          <p className="text-gray-400 dark:text-gray-600">
            Designed by Humans in California. Assembled by AI.
          </p>
        </div>
      </div>
    </footer>
  )
}
