import type { Metadata } from "next";
import Callout from "@/components/docs/Callout";
import PrevNextNav from "@/components/docs/PrevNextNav";
import Image from "next/image";

export const metadata: Metadata = { title: "GhostTools - GhostVM Docs" };

export default function GhostTools() {
  return (
    <>
      <h1>GhostTools</h1>
      <p className="lead">
        GhostTools is a companion app that runs inside the guest VM, providing
        the server-side of GhostVM&apos;s host-guest integration services.
      </p>

      <div className="not-prose my-6 flex items-center gap-4">
        <Image
          src="/images/ghosttools-icon.webp"
          alt="GhostTools icon"
          width={64}
          height={64}
          className="rounded-xl"
        />
        <div>
          <h3 className="font-semibold">GhostTools.app</h3>
          <p className="text-sm text-gray-600 dark:text-gray-400">
            Guest-side companion for GhostVM
          </p>
        </div>
      </div>

      <h2>Installation</h2>
      <p>
        GhostTools is bundled with GhostVM as a DMG. To install it in a guest
        VM:
      </p>
      <ol>
        <li>
          The GhostTools.dmg is located inside GhostVM.app at{" "}
          <code>Contents/Resources/GhostTools.dmg</code>
        </li>
        <li>Transfer the DMG to the guest VM — drag and drop onto the VM window, use a shared folder, or copy via the file transfer feature</li>
        <li>Open the DMG and drag GhostTools.app to the guest&apos;s Applications folder</li>
        <li>Launch GhostTools — it will appear as a menu bar app</li>
      </ol>

      <Callout variant="info" title="Auto-Launch">
        Configure GhostTools to launch at login in the guest&apos;s System
        Settings → General → Login Items for seamless integration.
      </Callout>

      <h2>What GhostTools Provides</h2>
      <p>
        GhostTools runs an HTTP/1.1 server over vsock that handles requests
        from the host:
      </p>
      <ul>
        <li>
          <strong>Clipboard</strong> — get/set the guest clipboard
        </li>
        <li>
          <strong>File Transfer</strong> — receive files from host, queue files
          for host
        </li>
        <li>
          <strong>Health Check</strong> — persistent connection on port 5002 so
          the host knows GhostTools is alive
        </li>
        <li>
          <strong>Event Stream</strong> — push events (port notifications, URLs,
          log entries) on port 5003
        </li>
        <li>
          <strong>Port Discovery</strong> — report listening TCP ports with
          process names to enable auto port detection
        </li>
        <li>
          <strong>Foreground App Tracking</strong> — report the current
          foreground app to help the host identify workspace context
        </li>
      </ul>

      <h2>Status Indicator</h2>
      <p>
        The VM toolbar shows a three-state Guest Tools indicator with a
        scramble-decode animation:
      </p>
      <ul>
        <li>
          <strong>Connecting</strong> — amber dot, the host is attempting to
          reach GhostTools
        </li>
        <li>
          <strong>Connected</strong> — green dot, GhostTools is active and all
          services are available
        </li>
        <li>
          <strong>Not Found</strong> — gray dot, GhostTools is not running or
          unreachable
        </li>
      </ul>

      <PrevNextNav currentHref="/docs/ghosttools" />
    </>
  );
}
