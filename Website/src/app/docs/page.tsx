import type { Metadata } from "next";
import Link from "next/link";
import { docsNav } from "@/lib/docs-nav";

export const metadata: Metadata = { title: "Documentation - GhostVM" };

export default function DocsIndex() {
  return (
    <>
      <h1>Documentation</h1>
      <p className="lead">
        Everything you need to know about GhostVM — from getting started to
        advanced configuration.
      </p>
      <div className="not-prose grid grid-cols-1 md:grid-cols-2 gap-4 mt-8">
        {docsNav.map((item) => (
          <Link
            key={item.href}
            href={item.href}
            className="block p-5 rounded-xl border border-gray-200 dark:border-gray-800 hover:border-ghost-300 dark:hover:border-ghost-700 transition-colors"
          >
            <h3 className="font-semibold mb-1">{item.title}</h3>
            {item.children && (
              <p className="text-sm text-gray-500 dark:text-gray-400">
                {item.children.map((c) => c.title).join(", ")}
              </p>
            )}
          </Link>
        ))}
      </div>
    </>
  );
}
