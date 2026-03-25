import Link from "next/link";
import { ChevronLeft, ChevronRight } from "lucide-react";
import { getPrevNext } from "@/lib/docs-nav";

export default function PrevNextNav({ currentHref }: { currentHref: string }) {
  const { prev, next } = getPrevNext(currentHref);

  return (
    <div className="mt-12 pt-6 border-t border-gray-200 dark:border-gray-800 flex justify-between">
      {prev ? (
        <Link
          href={prev.href}
          className="group flex items-center gap-2 text-sm text-gray-600 dark:text-gray-400 hover:text-ghost-600 dark:hover:text-ghost-400 transition-colors"
        >
          <ChevronLeft className="w-4 h-4 group-hover:-translate-x-0.5 transition-transform" />
          {prev.title}
        </Link>
      ) : (
        <div />
      )}
      {next ? (
        <Link
          href={next.href}
          className="group flex items-center gap-2 text-sm text-gray-600 dark:text-gray-400 hover:text-ghost-600 dark:hover:text-ghost-400 transition-colors"
        >
          {next.title}
          <ChevronRight className="w-4 h-4 group-hover:translate-x-0.5 transition-transform" />
        </Link>
      ) : (
        <div />
      )}
    </div>
  );
}
