import type { Metadata } from "next";
import PrevNextNav from "@/components/docs/PrevNextNav";

export const metadata: Metadata = { title: "File Transfer - GhostVM Docs" };

export default function FileTransfer() {
  return (
    <>
      <h1>File Transfer</h1>
      <p className="lead">
        Transfer files between the host Mac and the guest VM using drag-and-drop
        or the GhostTools event stream.
      </p>

      <h2>Host to Guest</h2>
      <p>
        Drag files from Finder onto the VM window to send them to the guest.
        GhostVM shows a transfer progress overlay with the filename, progress
        bar, and file size.
      </p>
      <p>
        Files are transferred over vsock and saved to the guest&apos;s Desktop
        (or a configured location in GhostTools).
      </p>

      <h2>Guest to Host</h2>
      <p>
        GhostTools can queue files for transfer from the guest to the host. When
        files are available, a badge appears in the VM toolbar showing the count
        of queued files. Click to receive them.
      </p>
      <p>
        Received files are saved to the host&apos;s Downloads folder by default.
      </p>

      <h2>Transfer Protocol</h2>
      <p>
        File transfer uses the vsock event stream (port 5003). Files are sent as
        binary data with a header containing the filename and size. The protocol
        supports:
      </p>
      <ul>
        <li>Simultaneous transfers of multiple files</li>
        <li>Progress tracking for each file</li>
        <li>Large file support (streamed in chunks)</li>
      </ul>

      <h2>Requirements</h2>
      <p>
        File transfer requires{" "}
        <a href="/docs/ghosttools">GhostTools</a> running in the guest VM.
      </p>

      <PrevNextNav currentHref="/docs/services/file-transfer" />
    </>
  );
}
