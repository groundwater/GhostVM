import type { Metadata } from "next";
import PrevNextNav from "@/components/docs/PrevNextNav";

export const metadata: Metadata = { title: "Architecture - GhostVM Docs" };

export default function Architecture() {
  return (
    <>
      <h1>Architecture</h1>
      <p className="lead">
        GhostVM is composed of several components that work together to provide
        a complete virtualization experience on Apple Silicon.
      </p>

      <h2>Components</h2>

      <h3>GhostVM.app (Main App)</h3>
      <p>
        The main SwiftUI application. Manages the VM list, creates new VMs,
        manages restore images, and launches VM instances. The main app does
        <em>not</em> run VMs directly — it delegates to GhostVMHelper.
      </p>

      <h3>GhostVMHelper</h3>
      <p>
        A separate process spawned for each running VM. Each helper gets its own
        Dock icon (showing the VM&apos;s custom icon) and runs the
        Virtualization.framework VM instance. This isolation ensures that a
        crashing VM doesn&apos;t take down the main app or other VMs.
      </p>

      <h3>GhostVMKit</h3>
      <p>
        A shared framework containing core types used by both the main app and
        the helper:
      </p>
      <ul>
        <li>
          <code>VMFileLayout</code> — resolves paths within a .GhostVM bundle
        </li>
        <li>
          <code>VMConfigStore</code> — reads/writes config.json
        </li>
        <li>
          <code>VMStoredConfig</code> — Codable VM configuration model
        </li>
        <li>
          <code>PortForwardConfig</code>, <code>SharedFolderConfig</code> —
          typed configurations
        </li>
      </ul>

      <h3>vmctl (CLI)</h3>
      <p>
        A command-line tool that provides the same capabilities as the GUI. Uses
        GhostVMKit for all VM operations. Supports headless operation for
        scripting and automation.
      </p>

      <h3>GhostTools (Guest Agent)</h3>
      <p>
        A companion app that runs inside the guest VM. Communicates with the
        host over virtio-vsock to provide clipboard sync, file transfer, port
        discovery, and health monitoring.
      </p>

      <h3>Host API Service</h3>
      <p>
        Each running VM&apos;s Helper process exposes a Unix domain socket at{" "}
        <code>~/Library/Application Support/GhostVM/api/</code>. The socket
        accepts standard HTTP/1.1 requests (with JSON bodies) and provides access
        to guest proxy operations (clipboard, exec, files, apps). Any HTTP client
        that supports Unix sockets can connect. See the{" "}
        <a href="/docs/host-api">Host API</a> docs for details.
      </p>

      <h2>Services Architecture</h2>
      <p>
        All host-guest services are located in <code>GhostVM/Services/</code>{" "}
        and are <code>@MainActor</code> isolated. They&apos;re shared between
        the main app and GhostVMHelper targets.
      </p>
      <table>
        <thead>
          <tr>
            <th>Service</th>
            <th>Description</th>
          </tr>
        </thead>
        <tbody>
          <tr>
            <td>
              <code>HealthCheckService</code>
            </td>
            <td>Persistent vsock connection on port 5002 to detect GhostTools</td>
          </tr>
          <tr>
            <td>
              <code>EventStreamService</code>
            </td>
            <td>Persistent vsock connection on port 5003 for guest events</td>
          </tr>
          <tr>
            <td>
              <code>ClipboardSyncService</code>
            </td>
            <td>Event-driven clipboard sync on window focus/blur</td>
          </tr>
          <tr>
            <td>
              <code>FileTransferService</code>
            </td>
            <td>Host-to-guest and guest-to-host file transfers</td>
          </tr>
          <tr>
            <td>
              <code>PortForwardService</code>
            </td>
            <td>TCP-to-vsock port forwarding via NIO</td>
          </tr>
          <tr>
            <td>
              <code>AutoPortMapService</code>
            </td>
            <td>Auto-detects guest listening ports and creates forwards</td>
          </tr>
          <tr>
            <td>
              <code>FolderShareService</code>
            </td>
            <td>Configures VirtioFS shared folder attachments</td>
          </tr>
        </tbody>
      </table>

      <h2>Communication</h2>
      <p>
        Host-guest communication uses <strong>virtio-vsock</strong>, a
        high-performance virtual socket transport provided by
        Virtualization.framework. This is faster and more reliable than network
        sockets and doesn&apos;t require guest networking to be configured.
      </p>
      <p>
        Services use <code>GhostClient(virtualMachine:vmQueue:)</code> to create
        vsock connections to the guest.
      </p>

      <h2>Networking</h2>
      <p>
        VMs use <code>VZNATNetworkDeviceAttachment</code> for network access.
        This provides NAT networking with zero configuration overhead — the
        guest gets internet access through the host&apos;s network connection.
      </p>

      <PrevNextNav currentHref="/docs/architecture" />
    </>
  );
}
