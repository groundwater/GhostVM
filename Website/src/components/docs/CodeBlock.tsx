"use client";

import { Copy, Check } from "lucide-react";
import { useState } from "react";

export default function CodeBlock({
  children,
  language = "bash",
  title,
}: {
  children: string;
  language?: string;
  title?: string;
}) {
  const [copied, setCopied] = useState(false);

  const copy = () => {
    navigator.clipboard.writeText(children.trim());
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  };

  return (
    <div className="relative group rounded-lg overflow-hidden my-4 bg-gray-900 dark:bg-gray-950 border border-gray-800">
      {title && (
        <div className="px-4 py-2 text-xs text-gray-400 border-b border-gray-800 bg-gray-900/50">
          {title}
        </div>
      )}
      <button
        onClick={copy}
        className="absolute top-2 right-2 p-1.5 rounded-md bg-gray-800 hover:bg-gray-700 text-gray-400 hover:text-white opacity-0 group-hover:opacity-100 transition-all"
        aria-label="Copy code"
      >
        {copied ? (
          <Check className="w-4 h-4" />
        ) : (
          <Copy className="w-4 h-4" />
        )}
      </button>
      <pre className="p-4 overflow-x-auto">
        <code className={`terminal-text text-sm text-green-400 language-${language}`}>
          {children.trim()}
        </code>
      </pre>
    </div>
  );
}
