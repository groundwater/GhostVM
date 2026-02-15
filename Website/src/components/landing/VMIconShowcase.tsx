"use client";

import Image from "next/image";
import { useEffect, useState } from "react";

type DockItem = {
  name: string;
  src: string;
  running?: boolean;
  isVM?: boolean;
  stack?: { back: string; front: string };
  glassIcon?: string;
  content?: "terminal" | "chat" | "code" | "slack" | "browser" | "safari" | "finder";
};

const dockItems: DockItem[] = [
  { name: "Slack", src: "/images/dock-icons/slack.png", running: true, isVM: true, content: "slack" },
  { name: "VS Code", src: "/images/dock-icons/vscode.png", running: true, isVM: true, content: "code" },
  { name: "macOS Sequoia", src: "/images/vm-icons/icon-hipster.png", running: true, isVM: true, content: "chat" },
  { name: "Dev Server", src: "/images/vm-icons/icon-terminal.png", running: true, isVM: true, content: "terminal" },
  { name: "Default", src: "/images/dock-icons/glass-ghost.png", running: true, isVM: true },
  { name: "CI Runner", src: "/images/dock-icons/glass.png", running: true, isVM: true, glassIcon: "/images/dock-icons/firefox.png", content: "browser" },
  { name: "Staging", src: "/images/vm-icons/icon-nerd.png", running: true, isVM: true, stack: { back: "/images/dock-icons/finder.png", front: "/images/dock-icons/safari.png" }, content: "safari" },
  { name: "Testing", src: "/images/vm-icons/icon-banana.png", running: true, isVM: true, stack: { back: "/images/dock-icons/slack.png", front: "/images/dock-icons/finder.png" }, content: "finder" },
];

const totalDockSlots = dockItems.length;

const vmWallpapers = [
  "/images/wallpapers/sonoma.png",
  "/images/wallpapers/sky-blue.png",
  "/images/wallpapers/catalina-sunset.png",
];

function MiniTerminal() {
  return (
    <div className="w-full h-full bg-white dark:bg-gray-950 overflow-hidden">
      {/* Tab bar */}
      <div className="flex items-center h-3 sm:h-4 bg-gray-200 dark:bg-gray-800 border-b border-gray-300 dark:border-gray-700">
        <div className="px-2 h-full flex items-center bg-white dark:bg-gray-950 text-[4px] sm:text-[5px] text-gray-600 dark:text-gray-300 border-r border-gray-300 dark:border-gray-700">dev — zsh</div>
      </div>
      <div className="p-1.5 sm:p-2 overflow-hidden text-left">
        <div className="space-y-0 text-[5px] sm:text-[7px] font-mono leading-relaxed">
          <div><span className="text-green-600 dark:text-green-400">jake@dev</span><span className="text-gray-400">:</span><span className="text-blue-500 dark:text-blue-400">~</span><span className="text-gray-800 dark:text-gray-300">$ npm run build</span></div>
          <div className="text-gray-500">Compiled 47 modules in 2.3s</div>
          <div className="text-green-600 dark:text-green-400">Build complete.</div>
          <div>&nbsp;</div>
          <div><span className="text-green-600 dark:text-green-400">jake@dev</span><span className="text-gray-400">:</span><span className="text-blue-500 dark:text-blue-400">~</span><span className="text-gray-800 dark:text-gray-300">$ docker compose up -d</span></div>
          <div className="text-gray-500">Container postgres started</div>
          <div className="text-gray-500">Container redis started</div>
          <div className="text-gray-500">Container api started</div>
          <div>&nbsp;</div>
          <div><span className="text-green-600 dark:text-green-400">jake@dev</span><span className="text-gray-400">:</span><span className="text-blue-500 dark:text-blue-400">~</span><span className="text-gray-800 dark:text-gray-300">$ </span><span className="animate-pulse text-gray-800 dark:text-gray-300">▊</span></div>
        </div>
      </div>
    </div>
  );
}

function MiniChat() {
  return (
    <div className="w-full h-full bg-white dark:bg-gray-900 flex flex-col overflow-hidden">
      {/* Chat header */}
      <div className="px-2 py-1 border-b border-gray-200 dark:border-gray-700 flex items-center gap-1">
        <div className="w-3 h-3 sm:w-4 sm:h-4 rounded-full bg-purple-400" />
        <span className="text-[6px] sm:text-[8px] font-medium text-gray-700 dark:text-gray-300">Messages</span>
      </div>
      {/* Messages */}
      <div className="flex-1 p-1.5 sm:p-2 space-y-1 sm:space-y-1.5 overflow-hidden">
        <div className="flex gap-1 items-start">
          <div className="w-2.5 h-2.5 sm:w-3 sm:h-3 rounded-full bg-blue-400 shrink-0 mt-0.5" />
          <div className="bg-gray-100 dark:bg-gray-800 rounded px-1.5 py-0.5 text-[5px] sm:text-[7px] text-gray-700 dark:text-gray-300">Hey, the new build looks great!</div>
        </div>
        <div className="flex gap-1 items-start justify-end">
          <div className="bg-blue-500 rounded-lg px-1.5 py-0.5 text-[5px] sm:text-[7px] text-white">Thanks! Deploying now.</div>
        </div>
        <div className="flex gap-1 items-start">
          <div className="w-2.5 h-2.5 sm:w-3 sm:h-3 rounded-full bg-green-400 shrink-0 mt-0.5" />
          <div className="bg-gray-100 dark:bg-gray-800 rounded px-1.5 py-0.5 text-[5px] sm:text-[7px] text-gray-700 dark:text-gray-300">Can you check the auth flow?</div>
        </div>
        <div className="flex gap-1 items-start justify-end">
          <div className="bg-blue-500 rounded-lg px-1.5 py-0.5 text-[5px] sm:text-[7px] text-white">On it</div>
        </div>
      </div>
      {/* Input */}
      <div className="px-1.5 py-1 border-t border-gray-200 dark:border-gray-700">
        <div className="bg-gray-100 dark:bg-gray-800 rounded-full h-2.5 sm:h-3" />
      </div>
    </div>
  );
}

function MiniCode() {
  return (
    <div className="w-full h-full bg-[#1e1e1e] flex overflow-hidden">
      {/* Activity bar */}
      <div className="w-4 sm:w-6 bg-[#333333] border-r border-[#252526] py-1 flex flex-col items-center gap-1">
        <div className="w-2.5 h-2.5 sm:w-3.5 sm:h-3.5 rounded-sm bg-white/20" />
        <div className="w-2.5 h-2.5 sm:w-3.5 sm:h-3.5 rounded-sm bg-white/10" />
        <div className="w-2.5 h-2.5 sm:w-3.5 sm:h-3.5 rounded-sm bg-white/10" />
      </div>
      {/* File tree */}
      <div className="w-14 sm:w-20 bg-[#252526] border-r border-[#1e1e1e] p-1 overflow-hidden text-left">
        <div className="text-[4px] sm:text-[6px] font-mono space-y-px">
          <div className="text-[#cccccc]/60 uppercase tracking-wider text-[3px] sm:text-[5px] mb-0.5">Explorer</div>
          <div className="text-[#cccccc] pl-0.5">▾ src</div>
          <div className="text-[#cccccc]/70 pl-2">app.tsx</div>
          <div className="text-[#cccccc] pl-2 bg-[#094771] rounded-sm px-0.5">index.ts</div>
          <div className="text-[#cccccc]/70 pl-2">utils.ts</div>
          <div className="text-[#cccccc]/70 pl-2">config.ts</div>
          <div className="text-[#cccccc] pl-0.5">▾ tests</div>
          <div className="text-[#cccccc]/70 pl-2">app.test.ts</div>
        </div>
      </div>
      {/* Editor */}
      <div className="flex-1 flex flex-col overflow-hidden">
        {/* Tabs */}
        <div className="flex h-3 sm:h-4 bg-[#252526] border-b border-[#1e1e1e]">
          <div className="px-1.5 h-full flex items-center bg-[#1e1e1e] text-[4px] sm:text-[5px] text-[#cccccc] border-t border-t-[#007acc]">index.ts</div>
          <div className="px-1.5 h-full flex items-center text-[4px] sm:text-[5px] text-[#cccccc]/50">app.tsx</div>
        </div>
        {/* Code */}
        <div className="flex-1 flex overflow-hidden">
          {/* Line numbers */}
          <div className="py-1 px-0.5 sm:px-1 text-[4px] sm:text-[6px] font-mono text-[#858585] text-right leading-relaxed select-none">
            <div>1</div><div>2</div><div>3</div><div>4</div><div>5</div><div>6</div><div>7</div><div>8</div><div>9</div>
          </div>
          <div className="flex-1 py-1 pl-1 overflow-hidden text-left">
            <div className="text-[4px] sm:text-[6px] font-mono leading-relaxed">
              <div><span className="text-[#c586c0]">import</span> <span className="text-[#9cdcfe]">express</span> <span className="text-[#c586c0]">from</span> <span className="text-[#ce9178]">&apos;express&apos;</span></div>
              <div>&nbsp;</div>
              <div><span className="text-[#569cd6]">const</span> <span className="text-[#4fc1ff]">app</span> <span className="text-[#d4d4d4]">=</span> <span className="text-[#dcdcaa]">express</span><span className="text-[#d4d4d4]">()</span></div>
              <div>&nbsp;</div>
              <div><span className="text-[#4fc1ff]">app</span><span className="text-[#d4d4d4]">.</span><span className="text-[#dcdcaa]">get</span><span className="text-[#d4d4d4]">(</span><span className="text-[#ce9178]">&apos;/api&apos;</span><span className="text-[#d4d4d4]">, (</span><span className="text-[#9cdcfe]">req</span><span className="text-[#d4d4d4]">,</span> <span className="text-[#9cdcfe]">res</span><span className="text-[#d4d4d4]">) =&gt; {"{"}</span></div>
              <div><span className="text-[#d4d4d4]">  </span><span className="text-[#9cdcfe]">res</span><span className="text-[#d4d4d4]">.</span><span className="text-[#dcdcaa]">json</span><span className="text-[#d4d4d4]">({"{"} </span><span className="text-[#9cdcfe]">ok</span><span className="text-[#d4d4d4]">:</span> <span className="text-[#569cd6]">true</span><span className="text-[#d4d4d4]"> {"}"})</span></div>
              <div><span className="text-[#d4d4d4]">{"}"})</span></div>
              <div>&nbsp;</div>
              <div><span className="text-[#4fc1ff]">app</span><span className="text-[#d4d4d4]">.</span><span className="text-[#dcdcaa]">listen</span><span className="text-[#d4d4d4]">(</span><span className="text-[#b5cea8]">3000</span><span className="text-[#d4d4d4]">)</span></div>
            </div>
          </div>
        </div>
        {/* Status bar */}
        <div className="h-2.5 sm:h-3 bg-[#007acc] flex items-center px-1 gap-1">
          <span className="text-[3px] sm:text-[5px] text-white/90">main</span>
          <div className="flex-1" />
          <span className="text-[3px] sm:text-[5px] text-white/70">TypeScript</span>
        </div>
      </div>
    </div>
  );
}

function MiniSlack() {
  return (
    <div className="w-full h-full bg-[#1a1d21] flex overflow-hidden">
      {/* Workspace sidebar */}
      <div className="w-5 sm:w-7 bg-[#0e0e10] flex flex-col items-center py-1 gap-1">
        <div className="w-3 h-3 sm:w-4 sm:h-4 rounded-md bg-[#611f69]" />
        <div className="w-3 h-3 sm:w-4 sm:h-4 rounded-md bg-gray-700" />
      </div>
      {/* Channel sidebar */}
      <div className="w-14 sm:w-20 bg-[#19171d] p-1 overflow-hidden text-left">
        <div className="text-[4px] sm:text-[6px] space-y-px">
          <div className="text-white font-bold text-[5px] sm:text-[7px] mb-1 px-0.5">Acme Inc</div>
          <div className="text-white/40 uppercase tracking-wider text-[3px] sm:text-[5px] mb-0.5 px-0.5">Channels</div>
          <div className="text-white/70 px-0.5"># general</div>
          <div className="text-white bg-[#1164a3] rounded px-0.5 py-px"># dev</div>
          <div className="text-white/70 px-0.5"># design</div>
          <div className="text-white/70 px-0.5"># random</div>
          <div className="text-white/40 uppercase tracking-wider text-[3px] sm:text-[5px] mt-1 mb-0.5 px-0.5">DMs</div>
          <div className="text-white/70 px-0.5 flex items-center gap-0.5"><span className="w-1 h-1 rounded-full bg-green-500 inline-block" />alice</div>
          <div className="text-white/70 px-0.5 flex items-center gap-0.5"><span className="w-1 h-1 rounded-full bg-gray-500 inline-block" />bob</div>
        </div>
      </div>
      {/* Messages */}
      <div className="flex-1 bg-[#1a1d21] flex flex-col overflow-hidden text-left">
        <div className="px-1.5 py-0.5 sm:py-1 border-b border-[#313338] flex items-center">
          <span className="text-[6px] sm:text-[8px] font-bold text-white"># dev</span>
        </div>
        <div className="flex-1 p-1 sm:p-1.5 space-y-1 overflow-hidden">
          <div className="flex gap-1 items-start">
            <div className="w-3 h-3 sm:w-4 sm:h-4 rounded-md bg-green-700 shrink-0 text-[4px] sm:text-[5px] text-white flex items-center justify-center font-bold">A</div>
            <div>
              <div className="flex items-baseline gap-1"><span className="text-[5px] sm:text-[7px] font-bold text-white">alice</span><span className="text-[3px] sm:text-[5px] text-gray-500">11:42 AM</span></div>
              <div className="text-[5px] sm:text-[7px] text-[#d1d2d3]">Pushed fix for the login bug</div>
            </div>
          </div>
          <div className="flex gap-1 items-start">
            <div className="w-3 h-3 sm:w-4 sm:h-4 rounded-md bg-blue-700 shrink-0 text-[4px] sm:text-[5px] text-white flex items-center justify-center font-bold">B</div>
            <div>
              <div className="flex items-baseline gap-1"><span className="text-[5px] sm:text-[7px] font-bold text-white">bob</span><span className="text-[3px] sm:text-[5px] text-gray-500">11:45 AM</span></div>
              <div className="text-[5px] sm:text-[7px] text-[#d1d2d3]">CI is green, merging now</div>
            </div>
          </div>
        </div>
        {/* Message input */}
        <div className="px-1.5 pb-1">
          <div className="bg-[#22252a] border border-[#3b3d44] rounded h-3 sm:h-4 px-1 flex items-center">
            <span className="text-[4px] sm:text-[5px] text-gray-500">Message #dev</span>
          </div>
        </div>
      </div>
    </div>
  );
}

function MiniBrowser() {
  return (
    <div className="w-full h-full bg-white dark:bg-gray-900 flex flex-col overflow-hidden">
      {/* Tab bar */}
      <div className="flex items-center h-3 sm:h-4 bg-gray-100 dark:bg-gray-800 border-b border-gray-200 dark:border-gray-700 px-1">
        <div className="px-1.5 h-full flex items-center bg-white dark:bg-gray-900 text-[4px] sm:text-[5px] text-gray-600 dark:text-gray-300 rounded-t border-x border-t border-gray-200 dark:border-gray-700">localhost</div>
      </div>
      {/* URL bar */}
      <div className="px-1.5 py-0.5 sm:py-1 bg-gray-50 dark:bg-gray-850 border-b border-gray-200 dark:border-gray-700 flex items-center gap-1">
        <div className="flex gap-0.5 text-gray-400">
          <span className="text-[6px] sm:text-[8px]">‹</span>
          <span className="text-[6px] sm:text-[8px]">›</span>
        </div>
        <div className="flex-1 bg-white dark:bg-gray-700 border border-gray-200 dark:border-gray-600 rounded h-2.5 sm:h-3 px-1 flex items-center">
          <span className="text-[4px] sm:text-[6px] text-green-600 dark:text-green-400">🔒</span>
          <span className="text-[4px] sm:text-[6px] text-gray-600 dark:text-gray-400 ml-0.5">localhost:8080</span>
        </div>
      </div>
      {/* Page content */}
      <div className="flex-1 p-2 sm:p-3 overflow-hidden">
        <div className="h-2 sm:h-3 w-3/4 bg-gray-800 dark:bg-gray-200 rounded mb-1.5 sm:mb-2" />
        <div className="h-1 sm:h-1.5 w-full bg-gray-200 dark:bg-gray-700 rounded mb-0.5" />
        <div className="h-1 sm:h-1.5 w-5/6 bg-gray-200 dark:bg-gray-700 rounded mb-0.5" />
        <div className="h-1 sm:h-1.5 w-2/3 bg-gray-200 dark:bg-gray-700 rounded mb-2" />
        <div className="flex gap-1">
          <div className="h-6 sm:h-8 flex-1 bg-blue-50 dark:bg-blue-900/20 border border-blue-200 dark:border-blue-800 rounded" />
          <div className="h-6 sm:h-8 flex-1 bg-green-50 dark:bg-green-900/20 border border-green-200 dark:border-green-800 rounded" />
          <div className="h-6 sm:h-8 flex-1 bg-purple-50 dark:bg-purple-900/20 border border-purple-200 dark:border-purple-800 rounded" />
        </div>
      </div>
    </div>
  );
}

function MiniSafari() {
  return (
    <div className="w-full h-full bg-white dark:bg-[#1c1c1e] flex flex-col overflow-hidden">
      {/* Safari unified bar */}
      <div className="px-1 py-0.5 sm:py-1 bg-[#f2f2f7] dark:bg-[#2c2c2e] border-b border-gray-300 dark:border-gray-600 flex items-center gap-1">
        <span className="text-[5px] sm:text-[7px] text-gray-400">‹</span>
        <span className="text-[5px] sm:text-[7px] text-gray-400">›</span>
        <div className="flex-1 bg-white dark:bg-[#3a3a3c] border border-gray-300 dark:border-gray-500 rounded-md h-2.5 sm:h-3.5 px-1 flex items-center justify-center">
          <span className="text-[4px] sm:text-[6px] text-gray-500 dark:text-gray-400">github.com/ghostvm</span>
        </div>
        <span className="text-[5px] sm:text-[7px] text-blue-500">⊕</span>
      </div>
      {/* Page — GitHub-ish readme */}
      <div className="flex-1 p-2 sm:p-3 overflow-hidden text-left">
        <div className="flex items-center gap-1 mb-1.5">
          <div className="w-3 h-3 sm:w-4 sm:h-4 rounded-full bg-gray-300 dark:bg-gray-600" />
          <span className="text-[5px] sm:text-[7px] font-bold text-gray-800 dark:text-gray-200">ghostvm / GhostVM</span>
        </div>
        <div className="h-1 sm:h-1.5 w-full bg-gray-200 dark:bg-gray-700 rounded mb-0.5" />
        <div className="h-1 sm:h-1.5 w-4/5 bg-gray-200 dark:bg-gray-700 rounded mb-0.5" />
        <div className="h-1 sm:h-1.5 w-3/5 bg-gray-200 dark:bg-gray-700 rounded mb-1.5" />
        <div className="flex gap-0.5 mb-1.5">
          <div className="px-1 py-0.5 bg-green-100 dark:bg-green-900/30 border border-green-300 dark:border-green-700 rounded text-[3px] sm:text-[5px] text-green-700 dark:text-green-400">Swift</div>
          <div className="px-1 py-0.5 bg-gray-100 dark:bg-gray-800 border border-gray-300 dark:border-gray-600 rounded text-[3px] sm:text-[5px] text-gray-600 dark:text-gray-400">macOS</div>
        </div>
        <div className="h-1 sm:h-1.5 w-full bg-gray-100 dark:bg-gray-800 rounded mb-0.5" />
        <div className="h-1 sm:h-1.5 w-5/6 bg-gray-100 dark:bg-gray-800 rounded" />
      </div>
    </div>
  );
}

function MiniFinder() {
  return (
    <div className="w-full h-full bg-[#f6f6f6] dark:bg-[#2b2b2b] flex overflow-hidden">
      {/* Sidebar */}
      <div className="w-14 sm:w-20 bg-[#e8e8e8] dark:bg-[#323232] border-r border-gray-300 dark:border-gray-600 p-1 overflow-hidden text-left">
        <div className="text-[4px] sm:text-[6px] space-y-px">
          <div className="text-gray-400 uppercase tracking-wider text-[3px] sm:text-[5px] mb-0.5">Favorites</div>
          <div className="text-gray-700 dark:text-gray-200 px-0.5 py-px flex items-center gap-0.5"><span className="text-blue-500">🏠</span> Desktop</div>
          <div className="text-gray-700 dark:text-gray-200 px-0.5 py-px bg-blue-500/20 rounded flex items-center gap-0.5"><span className="text-blue-500">📁</span> Documents</div>
          <div className="text-gray-700 dark:text-gray-200 px-0.5 py-px flex items-center gap-0.5"><span className="text-blue-500">⬇</span> Downloads</div>
          <div className="text-gray-400 uppercase tracking-wider text-[3px] sm:text-[5px] mt-1 mb-0.5">Locations</div>
          <div className="text-gray-700 dark:text-gray-200 px-0.5 py-px flex items-center gap-0.5"><span className="text-gray-400">💻</span> Macintosh HD</div>
        </div>
      </div>
      {/* File list */}
      <div className="flex-1 flex flex-col overflow-hidden text-left">
        {/* Path bar */}
        <div className="h-3 sm:h-4 bg-[#e8e8e8] dark:bg-[#323232] border-b border-gray-300 dark:border-gray-600 flex items-center px-1.5 gap-0.5">
          <span className="text-[4px] sm:text-[6px] text-gray-500">◂</span>
          <span className="text-[4px] sm:text-[6px] text-gray-500">▸</span>
          <div className="flex-1" />
          <span className="text-[4px] sm:text-[6px] text-gray-500">⊞</span>
          <span className="text-[4px] sm:text-[6px] text-gray-500">≡</span>
        </div>
        {/* Files */}
        <div className="flex-1 p-1 overflow-hidden">
          <div className="text-[4px] sm:text-[6px] space-y-px">
            <div className="flex items-center gap-1 px-0.5 py-px rounded bg-blue-500 text-white"><span>📁</span> Projects</div>
            <div className="flex items-center gap-1 px-0.5 py-px text-gray-700 dark:text-gray-300"><span>📁</span> Screenshots</div>
            <div className="flex items-center gap-1 px-0.5 py-px text-gray-700 dark:text-gray-300"><span>📄</span> notes.md</div>
            <div className="flex items-center gap-1 px-0.5 py-px text-gray-700 dark:text-gray-300"><span>📄</span> todo.txt</div>
            <div className="flex items-center gap-1 px-0.5 py-px text-gray-700 dark:text-gray-300"><span>🖼</span> wallpaper.png</div>
          </div>
        </div>
        {/* Status bar */}
        <div className="h-2 sm:h-2.5 bg-[#e8e8e8] dark:bg-[#323232] border-t border-gray-300 dark:border-gray-600 flex items-center px-1.5">
          <span className="text-[3px] sm:text-[5px] text-gray-500">5 items</span>
        </div>
      </div>
    </div>
  );
}

function AppContent({ type }: { type?: string }) {
  switch (type) {
    case "terminal": return <MiniTerminal />;
    case "chat": return <MiniChat />;
    case "code": return <MiniCode />;
    case "slack": return <MiniSlack />;
    case "browser": return <MiniBrowser />;
    case "safari": return <MiniSafari />;
    case "finder": return <MiniFinder />;
    default: return null;
  }
}

function VMWindowPreview({ name, wallpaper, visible, content }: { name: string; wallpaper: string; visible: boolean; content?: string }) {
  const iconClass = "w-2.5 h-2.5 sm:w-3 sm:h-3 text-gray-500 dark:text-gray-400";
  return (
    <div
      className={`absolute bottom-full left-1/2 -translate-x-1/2 mb-6 h-36 sm:h-48 aspect-[4/3] rounded-lg overflow-hidden shadow-2xl transition-all duration-300 pointer-events-none ${
        visible ? "opacity-100 scale-100" : "opacity-0 scale-95"
      }`}
    >
      {/* Titlebar with integrated toolbar */}
      <div className="flex items-center h-6 sm:h-8 px-2 sm:px-3 bg-gray-200/90 dark:bg-gray-700/90 backdrop-blur-sm gap-1.5 sm:gap-2">
        <div className="flex gap-1 sm:gap-1.5 shrink-0">
          <div className="w-2 h-2 sm:w-2.5 sm:h-2.5 rounded-full bg-red-500/80" />
          <div className="w-2 h-2 sm:w-2.5 sm:h-2.5 rounded-full bg-yellow-500/80" />
          <div className="w-2 h-2 sm:w-2.5 sm:h-2.5 rounded-full bg-green-500/80" />
        </div>
        {/* Title */}
        <span className="text-[8px] sm:text-[10px] text-gray-600 dark:text-gray-300 font-medium truncate">{name}</span>
        <div className="flex-1" />
        {/* Toolbar icons */}
        {/* Status dot */}
        <div className="w-1.5 h-1.5 rounded-full bg-green-500 shrink-0" />
        {/* Photo */}
        <svg className={iconClass} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
          <rect x="3" y="3" width="18" height="18" rx="2" />
          <circle cx="8.5" cy="8.5" r="1.5" />
          <path d="m21 15-5-5L5 21" />
        </svg>
        {/* Folder */}
        <svg className={iconClass} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
          <path d="M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2z" />
        </svg>
        {/* Clipboard */}
        <svg className={iconClass} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
          <path d="M16 4h2a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2h2" />
          <rect x="8" y="2" width="8" height="4" rx="1" />
        </svg>
        {/* Power */}
        <svg className={iconClass} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
          <path d="M18.36 6.64a9 9 0 1 1-12.73 0M12 2v10" />
        </svg>
      </div>
      {/* Content */}
      {content ? (
        <AppContent type={content} />
      ) : (
        <div className="relative w-full h-full">
          <Image src={wallpaper} alt="" fill className="object-cover" />
        </div>
      )}
    </div>
  );
}

function GlassIcon({ glass, inner }: { glass: string; inner: string }) {
  return (
    <div className="relative w-full h-full">
      <Image src={inner} alt="" fill className="object-contain p-[20%]" />
      <Image src={glass} alt="" fill className="object-cover" />
    </div>
  );
}

function StackIcon({ back, front }: { back: string; front: string }) {
  return (
    <div className="relative w-full h-full">
      {/* Back icon — shifted down-right */}
      <div className="absolute bottom-0 right-0 w-[70%] h-[70%] rounded-[22%] overflow-hidden opacity-80">
        <Image src={back} alt="" fill className="object-cover" />
      </div>
      {/* Front icon — shifted up-left, on top */}
      <div className="absolute -top-1 -left-1 w-[90%] h-[90%] rounded-[22%] overflow-hidden">
        <Image src={front} alt="" fill className="object-cover" />
      </div>
    </div>
  );
}

function DockIcon({ item, active, wallpaper }: { item: DockItem; active: boolean; wallpaper?: string }) {
  return (
    <div className="flex flex-col items-center relative">
      {/* VM Window Preview */}
      {item.isVM && wallpaper && (
        <VMWindowPreview name={item.name} wallpaper={wallpaper} visible={active} content={item.content} />
      )}
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
        className={`w-11 h-11 sm:w-13 sm:h-13 transition-transform duration-200 ease-out ${
          active ? "-translate-y-2.5" : "translate-y-0"
        } ${item.stack ? "" : "rounded-[22%] overflow-hidden"} ${item.glassIcon ? "rounded-[22%] overflow-hidden" : ""}`}
      >
        {item.glassIcon ? (
          <GlassIcon glass={item.src} inner={item.glassIcon} />
        ) : item.stack ? (
          <StackIcon back={item.stack.back} front={item.stack.front} />
        ) : (
          <Image
            src={item.src}
            alt={item.name}
            width={56}
            height={56}
            className="w-full h-full object-cover"
          />
        )}
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
    let timeout: ReturnType<typeof setTimeout>;
    let index = -1;

    function next() {
      index++;
      if (index >= totalDockSlots) {
        index = -1;
        timeout = setTimeout(next, 2000);
        setActiveIndex(-1);
        return;
      }
      setActiveIndex(index);
      timeout = setTimeout(next, 600);
    }

    timeout = setTimeout(next, 1000);
    return () => clearTimeout(timeout);
  }, []);

  return (
    <section className="py-20 bg-gray-50 dark:bg-gray-900/50">
      <div className="max-w-6xl mx-auto px-4 sm:px-6 lg:px-8 text-center">
        <h2 className="text-3xl font-bold mb-4">
          Customize each workspace&apos;s icon
        </h2>
        <p className="text-gray-600 dark:text-gray-400 mb-10 max-w-2xl mx-auto">
          Every workspace appears in the Dock and App Switcher with its own
          icon. Choose a mode, pick a preset, or upload your own image.
        </p>

        {/* Faux Desktop with Dock animation */}
        <div className="max-w-3xl mx-auto mb-12">
          <div className="rounded-xl overflow-hidden border border-gray-200 dark:border-gray-700 shadow-xl">
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

              {/* Desktop area */}
              <div className="h-48 sm:h-64" />

              {/* Dock at the bottom */}
              <div className="flex justify-center pb-2">
                <div className="inline-flex items-end gap-1.5 sm:gap-2 px-3 py-2 rounded-2xl bg-white/30 dark:bg-white/10 backdrop-blur-xl border border-white/40 dark:border-white/15 shadow-lg">
                  {dockItems.map((item, i) => {
                    const vmIndex = dockItems.filter((d, j) => d.isVM && j < i).length;
                    return (
                      <DockIcon
                        key={item.name}
                        item={item}
                        active={activeIndex === i}
                        wallpaper={item.isVM ? vmWallpapers[vmIndex % vmWallpapers.length] : undefined}
                      />
                    );
                  })}
                </div>
              </div>
            </div>
          </div>
        </div>

        {/* Icon type grid */}
        <div className="grid grid-cols-2 gap-4 sm:gap-6 max-w-2xl mx-auto">
          {/* Clone */}
          <div className="flex items-start gap-4 p-4 sm:p-5 rounded-xl bg-white dark:bg-gray-800/50 border border-gray-200 dark:border-gray-700 text-left">
            <div className="w-12 h-12 sm:w-14 sm:h-14 shrink-0 rounded-[22%] overflow-hidden">
              <Image src="/images/dock-icons/slack.png" alt="Clone" width={56} height={56} className="w-full h-full object-cover" />
            </div>
            <div>
              <h3 className="font-semibold text-sm sm:text-base">Clone</h3>
              <p className="text-xs sm:text-sm text-gray-500 dark:text-gray-400">Mirror an existing app&apos;s icon so the workspace looks like the real thing.</p>
            </div>
          </div>

          {/* Stack */}
          <div className="flex items-start gap-4 p-4 sm:p-5 rounded-xl bg-white dark:bg-gray-800/50 border border-gray-200 dark:border-gray-700 text-left">
            <div className="w-12 h-12 sm:w-14 sm:h-14 shrink-0 relative">
              <StackIcon back="/images/dock-icons/finder.png" front="/images/dock-icons/safari.png" />
            </div>
            <div>
              <h3 className="font-semibold text-sm sm:text-base">Stack</h3>
              <p className="text-xs sm:text-sm text-gray-500 dark:text-gray-400">Layer two app icons together to show what&apos;s running inside the workspace.</p>
            </div>
          </div>

          {/* Custom */}
          <div className="flex items-start gap-4 p-4 sm:p-5 rounded-xl bg-white dark:bg-gray-800/50 border border-gray-200 dark:border-gray-700 text-left">
            <div className="w-12 h-12 sm:w-14 sm:h-14 shrink-0 rounded-[22%] overflow-hidden">
              <Image src="/images/vm-icons/icon-hipster.png" alt="Custom" width={56} height={56} className="w-full h-full object-cover" />
            </div>
            <div>
              <h3 className="font-semibold text-sm sm:text-base">Custom</h3>
              <p className="text-xs sm:text-sm text-gray-500 dark:text-gray-400">Pick from 10 built-in presets or upload your own image.</p>
            </div>
          </div>

          {/* Glass */}
          <div className="flex items-start gap-4 p-4 sm:p-5 rounded-xl bg-white dark:bg-gray-800/50 border border-gray-200 dark:border-gray-700 text-left">
            <div className="w-12 h-12 sm:w-14 sm:h-14 shrink-0 rounded-[22%] overflow-hidden relative">
              <GlassIcon glass="/images/dock-icons/glass.png" inner="/images/dock-icons/firefox.png" />
            </div>
            <div>
              <h3 className="font-semibold text-sm sm:text-base">Glass</h3>
              <p className="text-xs sm:text-sm text-gray-500 dark:text-gray-400">Wrap any app icon in the GhostVM glass frame for a unified look.</p>
            </div>
          </div>
        </div>

      </div>
    </section>
  );
}
