"use client";

import Image from "next/image";
import { useEffect, useState } from "react";

const icons = [
  { name: "Hipster", file: "icon-hipster.png" },
  { name: "Nerd", file: "icon-nerd.png" },
  { name: "80s Bro", file: "icon-80s-bro.png" },
  { name: "Terminal", file: "icon-terminal.png" },
  { name: "Quill", file: "icon-quill.png" },
  { name: "Typewriter", file: "icon-typewriter.png" },
  { name: "Kernel", file: "icon-kernel.png" },
  { name: "Banana", file: "icon-banana.png" },
  { name: "Papaya", file: "icon-papaya.png" },
  { name: "Daemon", file: "icon-daemon.png" },
];

type DockItem = {
  name: string;
  src: string;
  running?: boolean;
  isVM?: boolean;
};

const dockItems: DockItem[] = [
  { name: "Firefox", src: "/images/dock-icons/firefox.png", running: true },
  { name: "Slack", src: "/images/dock-icons/slack.png" },
  { name: "VS Code", src: "/images/dock-icons/vscode-bigsur.png", running: true },
  { name: "iTerm", src: "/images/dock-icons/iterm.png" },
  { name: "macOS Sequoia", src: "/images/vm-icons/icon-nerd.png", running: true, isVM: true },
  { name: "Dev Server", src: "/images/vm-icons/icon-banana.png", running: true, isVM: true },
  { name: "Ubuntu CI", src: "/images/vm-icons/icon-terminal.png", isVM: true },
];

// Total items including trash at the end
const totalDockSlots = dockItems.length + 1; // +1 for trash


function TrashIcon() {
  return (
    <div className="w-full h-full bg-white/40 dark:bg-white/10 flex items-center justify-center rounded-[22%]">
      <svg className="w-7 h-7 text-gray-500 dark:text-gray-400" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5">
        <path d="M3 6h18M8 6V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2m3 0v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6h14z" />
      </svg>
    </div>
  );
}

function DockIcon({ item, active }: { item: DockItem; active: boolean }) {
  return (
    <div className="flex flex-col items-center relative">
      {/* Tooltip */}
      <div
        className={`absolute -top-10 left-1/2 -translate-x-1/2 px-2.5 py-1 rounded-md bg-gray-800/95 text-white text-[11px] whitespace-nowrap transition-all duration-200 pointer-events-none ${
          active ? "opacity-100 -translate-y-0" : "opacity-0 translate-y-1"
        }`}
      >
        {item.name}
        {/* Tooltip arrow */}
        <div className="absolute top-full left-1/2 -translate-x-1/2 w-0 h-0 border-l-[5px] border-l-transparent border-r-[5px] border-r-transparent border-t-[5px] border-t-gray-800/95" />
      </div>
      <div
        className={`w-11 h-11 sm:w-13 sm:h-13 rounded-[22%] overflow-hidden shadow-md transition-transform duration-200 ease-out ${
          active ? "-translate-y-2.5" : "translate-y-0"
        }`}
      >
        <Image
          src={item.src}
          alt={item.name}
          width={56}
          height={56}
          className="w-full h-full object-cover"
        />
      </div>
      <div
        className={`w-1 h-1 rounded-full mt-1 ${
          item.running ? "bg-white/70" : ""
        }`}
      />
    </div>
  );
}

export default function VMIconShowcase() {
  const [activeIndex, setActiveIndex] = useState(-1);

  useEffect(() => {
    // Cycle through dock items with pauses
    let timeout: ReturnType<typeof setTimeout>;
    let index = -1;

    function next() {
      index++;
      if (index >= totalDockSlots) {
        // Pause before restarting
        index = -1;
        timeout = setTimeout(next, 2000);
        setActiveIndex(-1);
        return;
      }
      setActiveIndex(index);
      timeout = setTimeout(next, 600);
    }

    // Start after a short delay
    timeout = setTimeout(next, 1000);
    return () => clearTimeout(timeout);
  }, []);

  return (
    <section className="py-20">
      <div className="max-w-6xl mx-auto px-4 sm:px-6 lg:px-8 text-center">
        <h2 className="text-3xl font-bold mb-4">
          Every workspace gets its own Dock icon
        </h2>
        <p className="text-gray-600 dark:text-gray-400 mb-10 max-w-xl mx-auto">
          Each running workspace appears in the macOS Dock as its own app.
          Pick from presets or use the toolbar icon chooser to switch between
          Generic, App, Stack, and Custom modes on the fly.
        </p>

        {/* Faux Desktop */}
        <div className="max-w-3xl mx-auto mb-4">
          <div className="rounded-xl overflow-hidden border border-gray-200 dark:border-gray-700 shadow-xl">
            {/* Desktop wallpaper area */}
            <div className="relative bg-gradient-to-br from-indigo-400 via-purple-400 to-pink-300 dark:from-indigo-900 dark:via-purple-900 dark:to-slate-900">
              {/* Menu bar */}
              <div className="flex items-center h-6 px-3 bg-white/60 dark:bg-black/40 backdrop-blur-sm">
                <div className="flex items-center gap-3 text-[9px] text-black/80 dark:text-white/80">
                  <svg className="w-2.5 h-2.5" viewBox="0 0 16 16" fill="currentColor">
                    <path d="M11.182 4.146a3.48 3.48 0 0 0-2.306-.863c-1.08 0-1.56.516-2.322.516-.786 0-1.404-.513-2.37-.513A3.55 3.55 0 0 0 1.2 5.476c-1.252 2.16-.328 5.363.898 7.118.596.864 1.31 1.836 2.248 1.8.9-.036 1.242-.582 2.334-.582 1.086 0 1.392.582 2.34.564.972-.018 1.59-.876 2.184-1.746a8.14 8.14 0 0 0 .99-2.034 3.07 3.07 0 0 1-1.866-2.826 3.12 3.12 0 0 1 1.488-2.616A3.22 3.22 0 0 0 9.28 4.356c.69 0 1.266.33 1.902-.21zM9.096 2.85c.492-.6.852-1.434.756-2.268-.732.03-1.59.492-2.1 1.08-.462.528-.864 1.374-.714 2.184.798.024 1.566-.426 2.058-1.002" />
                  </svg>
                  <span className="font-semibold">Finder</span>
                  <span className="text-black/60 dark:text-white/60">File</span>
                  <span className="text-black/60 dark:text-white/60">Edit</span>
                  <span className="text-black/60 dark:text-white/60">View</span>
                  <span className="text-black/60 dark:text-white/60">Go</span>
                  <span className="text-black/60 dark:text-white/60">Window</span>
                  <span className="text-black/60 dark:text-white/60">Help</span>
                </div>
                <div className="flex-1" />
                <div className="flex items-center gap-2 text-[9px] text-black/60 dark:text-white/60">
                  <svg className="w-3 h-3" viewBox="0 0 16 16" fill="currentColor" opacity="0.7">
                    <path d="M8 11.5a1.25 1.25 0 1 1 0 2.5 1.25 1.25 0 0 1 0-2.5zm-2.8-2.1a3.97 3.97 0 0 1 5.6 0l-.9.9a2.77 2.77 0 0 0-3.8 0l-.9-.9zm-1.8-1.8a6.36 6.36 0 0 1 9.2 0l-.9.9a5.16 5.16 0 0 0-7.4 0l-.9-.9zM1.6 5.8a8.76 8.76 0 0 1 12.8 0l-.9.9a7.56 7.56 0 0 0-11 0l-.9-.9z" />
                  </svg>
                  <svg className="w-4 h-2.5" viewBox="0 0 22 12" fill="none" stroke="currentColor" opacity="0.7" strokeWidth="1">
                    <rect x="0.5" y="1" width="18" height="10" rx="2" />
                    <rect x="2" y="2.5" width="15" height="7" rx="1" fill="currentColor" opacity="0.5" />
                    <path d="M20 4.5v3a1.5 1.5 0 0 0 0-3z" fill="currentColor" />
                  </svg>
                  <span>Sat 12:00 PM</span>
                </div>
              </div>

              {/* Empty desktop area */}
              <div className="h-48 sm:h-64" />

              {/* Dock at the bottom */}
              <div className="flex justify-center pb-2">
                <div className="inline-flex items-end gap-1.5 sm:gap-2 px-3 py-2 rounded-2xl bg-white/30 dark:bg-white/10 backdrop-blur-xl border border-white/40 dark:border-white/15 shadow-lg">
                  {dockItems.map((item, i) => (
                    <DockIcon key={item.name} item={item} active={activeIndex === i} />
                  ))}
                  {/* Separator */}
                  <div className="w-px h-9 sm:h-11 bg-white/30 dark:bg-white/10 mx-0.5 self-center" />
                  {/* Trash */}
                  <div className="flex flex-col items-center relative">
                    <div
                      className={`absolute -top-10 left-1/2 -translate-x-1/2 px-2.5 py-1 rounded-md bg-gray-800/95 text-white text-[11px] whitespace-nowrap transition-all duration-200 pointer-events-none ${
                        activeIndex === dockItems.length
                          ? "opacity-100 -translate-y-0"
                          : "opacity-0 translate-y-1"
                      }`}
                    >
                      Trash
                      <div className="absolute top-full left-1/2 -translate-x-1/2 w-0 h-0 border-l-[5px] border-l-transparent border-r-[5px] border-r-transparent border-t-[5px] border-t-gray-800/95" />
                    </div>
                    <div
                      className={`w-11 h-11 sm:w-13 sm:h-13 rounded-[22%] overflow-hidden transition-transform duration-200 ease-out ${
                        activeIndex === dockItems.length
                          ? "-translate-y-2.5"
                          : "translate-y-0"
                      }`}
                    >
                      <TrashIcon />
                    </div>
                    <div className="w-1 h-1 mt-1" />
                  </div>
                </div>
              </div>
            </div>
          </div>
        </div>

        {/* Full icon grid */}
        <p className="text-sm font-medium text-gray-500 dark:text-gray-400 mb-4 uppercase tracking-wide">
          10 built-in icons to choose from
        </p>
        <div className="grid grid-cols-5 gap-5 max-w-sm mx-auto">
          {icons.map((icon) => (
            <div key={icon.file} className="group flex flex-col items-center gap-1.5">
              <div className="w-14 h-14 sm:w-16 sm:h-16 rounded-[22%] overflow-hidden shadow-md group-hover:shadow-lg group-hover:scale-110 transition-all duration-200">
                <Image
                  src={`/images/vm-icons/${icon.file}`}
                  alt={icon.name}
                  width={64}
                  height={64}
                  className="w-full h-full object-cover"
                />
              </div>
              <span className="text-[11px] text-gray-500 dark:text-gray-400">
                {icon.name}
              </span>
            </div>
          ))}
        </div>
      </div>
    </section>
  );
}
