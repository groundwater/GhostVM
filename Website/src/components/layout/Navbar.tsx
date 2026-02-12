"use client";

import Link from "next/link";
import { useState } from "react";
import { Menu, X } from "lucide-react";
import Logo from "@/components/shared/Logo";
import ThemeToggle from "./ThemeToggle";

export default function Navbar() {
  const [mobileOpen, setMobileOpen] = useState(false);

  return (
    <nav className="sticky top-0 z-50 border-b border-gray-200 dark:border-gray-800 bg-white/80 dark:bg-gray-950/80 backdrop-blur-sm">
      <div className="max-w-6xl mx-auto px-4 sm:px-6 lg:px-8">
        <div className="flex items-center justify-between h-14">
          <Link href="/" className="flex items-center gap-2">
            <Logo className="h-7 w-auto" />
          </Link>

          <div className="hidden md:flex items-center gap-6">
            <Link
              href="/docs/getting-started"
              className="text-sm text-gray-600 dark:text-gray-400 hover:text-gray-900 dark:hover:text-white transition-colors"
            >
              Docs
            </Link>
            <Link
              href="/blog"
              className="text-sm text-gray-600 dark:text-gray-400 hover:text-gray-900 dark:hover:text-white transition-colors"
            >
              Blog
            </Link>
            <Link
              href="/download"
              className="text-sm text-gray-600 dark:text-gray-400 hover:text-gray-900 dark:hover:text-white transition-colors"
            >
              Download
            </Link>
            <a
              href="https://github.com/groundwater/GhostVM"
              className="text-sm text-gray-600 dark:text-gray-400 hover:text-gray-900 dark:hover:text-white transition-colors"
              target="_blank"
              rel="noopener noreferrer"
            >
              GitHub
            </a>
            <ThemeToggle />
          </div>

          <button
            className="md:hidden p-2"
            onClick={() => setMobileOpen(!mobileOpen)}
            aria-label="Toggle menu"
          >
            {mobileOpen ? (
              <X className="w-5 h-5" />
            ) : (
              <Menu className="w-5 h-5" />
            )}
          </button>
        </div>
      </div>

      {mobileOpen && (
        <div className="md:hidden border-t border-gray-200 dark:border-gray-800 bg-white dark:bg-gray-950 px-4 py-3 space-y-2">
          <Link
            href="/docs/getting-started"
            className="block py-2 text-sm"
            onClick={() => setMobileOpen(false)}
          >
            Docs
          </Link>
          <Link
            href="/blog"
            className="block py-2 text-sm"
            onClick={() => setMobileOpen(false)}
          >
            Blog
          </Link>
          <Link
            href="/download"
            className="block py-2 text-sm"
            onClick={() => setMobileOpen(false)}
          >
            Download
          </Link>
          <a
            href="https://github.com/groundwater/GhostVM"
            className="block py-2 text-sm"
            target="_blank"
            rel="noopener noreferrer"
          >
            GitHub
          </a>
          <ThemeToggle />
        </div>
      )}
    </nav>
  );
}
