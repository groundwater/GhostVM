import type { Metadata } from "next";
import Link from "next/link";

export const metadata: Metadata = { title: "Blog - GhostVM" };

const posts = [
  {
    slug: "why-you-cant-clone-your-mac",
    title: "Why You Can't Clone Your Mac Into a VM",
    date: "2025-01-24",
    readingTime: "6 min read",
    summary:
      "Apple's Virtualization.framework doesn't let you snapshot a running Mac into a VM. Here's why that's a fundamental limitation, not a missing feature.",
  },
];

export default function BlogIndex() {
  return (
    <>
      <h1>Blog</h1>
      <p className="lead">
        Technical deep dives into macOS virtualization, Apple&apos;s
        Virtualization.framework, and the lessons learned building GhostVM.
      </p>

      <div className="not-prose space-y-8 mt-8">
        {posts.map((post) => (
          <Link
            key={post.slug}
            href={`/blog/${post.slug}`}
            className="block group"
          >
            <article className="border border-gray-200 dark:border-gray-800 rounded-lg p-6 hover:border-ghost-500 dark:hover:border-ghost-500 transition-colors">
              <div className="flex items-center gap-3 text-sm text-gray-500 dark:text-gray-400 mb-2">
                <time dateTime={post.date}>
                  {new Date(post.date).toLocaleDateString("en-US", {
                    year: "numeric",
                    month: "long",
                    day: "numeric",
                  })}
                </time>
                <span>&middot;</span>
                <span>{post.readingTime}</span>
              </div>
              <h2 className="text-lg font-semibold text-gray-900 dark:text-white group-hover:text-ghost-600 dark:group-hover:text-ghost-400 transition-colors">
                {post.title}
              </h2>
              <p className="mt-2 text-sm text-gray-600 dark:text-gray-400">
                {post.summary}
              </p>
            </article>
          </Link>
        ))}
      </div>
    </>
  );
}
