"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { docsNav, type NavItem } from "@/lib/docs-nav";
import { ChevronRight } from "lucide-react";
import { useState } from "react";

function SidebarItem({ item, depth = 0 }: { item: NavItem; depth?: number }) {
  const pathname = usePathname();
  const isActive = pathname === item.href;
  const hasChildren = item.children && item.children.length > 0;
  const isChildActive = item.children?.some((c) => pathname === c.href);
  const [expanded, setExpanded] = useState(isActive || isChildActive || false);

  return (
    <li>
      <div className="flex items-center">
        <Link
          href={item.href}
          className={`flex-1 block py-1.5 text-sm transition-colors ${
            depth > 0 ? "pl-6" : "pl-3"
          } ${
            isActive
              ? "text-ghost-600 dark:text-ghost-400 font-medium border-l-2 border-ghost-500 -ml-px"
              : "text-gray-600 dark:text-gray-400 hover:text-gray-900 dark:hover:text-white"
          }`}
        >
          {item.title}
        </Link>
        {hasChildren && (
          <button
            onClick={() => setExpanded(!expanded)}
            className="p-1 hover:bg-gray-100 dark:hover:bg-gray-800 rounded"
            aria-label={expanded ? "Collapse" : "Expand"}
          >
            <ChevronRight
              className={`w-3.5 h-3.5 transition-transform ${expanded ? "rotate-90" : ""}`}
            />
          </button>
        )}
      </div>
      {hasChildren && expanded && (
        <ul className="mt-0.5">
          {item.children!.map((child) => (
            <SidebarItem key={child.href} item={child} depth={depth + 1} />
          ))}
        </ul>
      )}
    </li>
  );
}

export default function DocsSidebar() {
  return (
    <aside className="w-64 shrink-0 hidden lg:block">
      <nav className="sticky top-20 sidebar-scroll overflow-y-auto max-h-[calc(100vh-5rem)] pr-4">
        <ul className="space-y-0.5 border-l border-gray-200 dark:border-gray-800">
          {docsNav.map((item) => (
            <SidebarItem key={item.href} item={item} />
          ))}
        </ul>
      </nav>
    </aside>
  );
}
