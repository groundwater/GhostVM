"use client";

import { useState } from "react";
import { Download, Loader2 } from "lucide-react";
import { siteConfig } from "@/config/site";

export default function DownloadButton() {
  const [isLoading, setIsLoading] = useState(false);

  const handleDownload = async () => {
    setIsLoading(true);
    try {
      // Fetch latest release from GitHub API
      const response = await fetch(
        `https://api.github.com/repos/groundwater/GhostVM/releases/latest`
      );
      const release = await response.json();

      // Find the DMG asset
      const dmgAsset = release.assets?.find(
        (asset: { name: string }) => asset.name.endsWith(".dmg")
      );

      if (dmgAsset?.browser_download_url) {
        // Trigger download
        window.location.href = dmgAsset.browser_download_url;
      } else {
        // Fallback to releases page
        window.open(`${siteConfig.repo}/releases/latest`, "_blank");
      }
    } catch {
      // Fallback to releases page on error
      window.open(`${siteConfig.repo}/releases/latest`, "_blank");
    } finally {
      setIsLoading(false);
    }
  };

  return (
    <button
      onClick={handleDownload}
      disabled={isLoading}
      className="flex items-center justify-center gap-3 px-8 py-4 rounded-xl bg-ghost-600 hover:bg-ghost-700 disabled:bg-ghost-600/70 text-white font-semibold transition-colors shadow-lg w-full cursor-pointer"
    >
      {isLoading ? (
        <Loader2 className="w-5 h-5 animate-spin" />
      ) : (
        <Download className="w-5 h-5" />
      )}
      Download Latest Release
    </button>
  );
}
