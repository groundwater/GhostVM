import Image from "next/image";
import { type ReactNode } from "react";

export function DesktopFrame({ children }: { children: ReactNode }) {
  return (
    <div className="rounded-xl overflow-hidden border border-gray-200 dark:border-gray-700 shadow-xl">
      {/* macOS-style wallpaper gradient */}
      <div className="relative bg-gradient-to-br from-indigo-400 via-purple-400 to-pink-300 dark:from-indigo-900 dark:via-purple-900 dark:to-slate-900">
        {/* Menu bar */}
        <div className="flex items-center h-6 px-3 bg-white/60 dark:bg-black/40 backdrop-blur-sm">
          {/* Left: Apple + app menus */}
          <div className="flex items-center gap-3 text-[9px] text-black/80 dark:text-white/80">
            <svg className="w-2.5 h-2.5" viewBox="0 0 16 16" fill="currentColor">
              <path d="M11.182 4.146a3.48 3.48 0 0 0-2.306-.863c-1.08 0-1.56.516-2.322.516-.786 0-1.404-.513-2.37-.513A3.55 3.55 0 0 0 1.2 5.476c-1.252 2.16-.328 5.363.898 7.118.596.864 1.31 1.836 2.248 1.8.9-.036 1.242-.582 2.334-.582 1.086 0 1.392.582 2.34.564.972-.018 1.59-.876 2.184-1.746a8.14 8.14 0 0 0 .99-2.034 3.07 3.07 0 0 1-1.866-2.826 3.12 3.12 0 0 1 1.488-2.616A3.22 3.22 0 0 0 9.28 4.356c.69 0 1.266.33 1.902-.21zM9.096 2.85c.492-.6.852-1.434.756-2.268-.732.03-1.59.492-2.1 1.08-.462.528-.864 1.374-.714 2.184.798.024 1.566-.426 2.058-1.002" />
            </svg>
            <span className="font-semibold">GhostVM</span>
            <span className="text-black/60 dark:text-white/60">File</span>
            <span className="text-black/60 dark:text-white/60">Edit</span>
            <span className="text-black/60 dark:text-white/60">VM</span>
            <span className="text-black/60 dark:text-white/60">Window</span>
            <span className="text-black/60 dark:text-white/60">Help</span>
          </div>
          <div className="flex-1" />
          {/* Right: status icons */}
          <div className="flex items-center gap-2 text-[9px] text-black/60 dark:text-white/60">
            {/* Wi-Fi icon */}
            <svg className="w-3 h-3" viewBox="0 0 16 16" fill="currentColor" opacity="0.7">
              <path d="M8 11.5a1.25 1.25 0 1 1 0 2.5 1.25 1.25 0 0 1 0-2.5zm-2.8-2.1a3.97 3.97 0 0 1 5.6 0l-.9.9a2.77 2.77 0 0 0-3.8 0l-.9-.9zm-1.8-1.8a6.36 6.36 0 0 1 9.2 0l-.9.9a5.16 5.16 0 0 0-7.4 0l-.9-.9zM1.6 5.8a8.76 8.76 0 0 1 12.8 0l-.9.9a7.56 7.56 0 0 0-11 0l-.9-.9z" />
            </svg>
            {/* Battery icon */}
            <svg className="w-4 h-2.5" viewBox="0 0 22 12" fill="none" stroke="currentColor" opacity="0.7" strokeWidth="1">
              <rect x="0.5" y="1" width="18" height="10" rx="2" />
              <rect x="2" y="2.5" width="15" height="7" rx="1" fill="currentColor" opacity="0.5" />
              <path d="M20 4.5v3a1.5 1.5 0 0 0 0-3z" fill="currentColor" />
            </svg>
            <span>Sat 12:00 PM</span>
          </div>
        </div>

        {/* Desktop area with window screenshot */}
        <div className="p-6 sm:p-8 flex items-center justify-center">
          {children}
        </div>
      </div>
    </div>
  );
}

export function WindowScreenshot({
  src,
  alt,
}: {
  src: string;
  alt: string;
}) {
  return (
    <div className="rounded-lg overflow-hidden shadow-2xl ring-1 ring-black/10">
      <Image
        src={src}
        alt={alt}
        width={800}
        height={600}
        className="w-full h-auto block"
      />
    </div>
  );
}
