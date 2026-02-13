import type { Metadata } from "next";
import Link from "next/link";
import Callout from "@/components/docs/Callout";
import CodeBlock from "@/components/docs/CodeBlock";

export const metadata: Metadata = {
  title:
    "The Unexpected Challenges of virtio-vsock on macOS - GhostVM",
};

export default function VirtioVsockSurprises() {
  return (
    <>
      <div className="not-prose mb-8">
        <Link
          href="/blog"
          className="text-sm text-ghost-600 dark:text-ghost-400 hover:underline"
        >
          &larr; Back to blog
        </Link>
      </div>

      <div className="flex items-center gap-3 text-sm text-gray-500 dark:text-gray-400 mb-2 not-prose">
        <time dateTime="2025-02-07">February 7, 2025</time>
        <span>&middot;</span>
        <span>8 min read</span>
      </div>

      <h1>The Unexpected Challenges of virtio-vsock on macOS</h1>
      <p className="lead">
        Real bugs we hit building host-guest communication with
        virtio-vsock — from silently closed file descriptors to broken kqueue
        notifications.
      </p>

      <h2>Why virtio-vsock?</h2>
      <p>
        When a host application needs to communicate with a guest VM, the
        obvious choice might be networking — just use TCP over the virtual
        network interface. But Apple&apos;s Virtualization.framework offers a
        better option: <strong>virtio-vsock</strong>.
      </p>
      <p>
        Vsock is a virtual socket transport that provides direct, low-latency
        communication between the host and guest without going through the
        network stack. It doesn&apos;t require the guest to have networking
        configured, doesn&apos;t need IP addresses or port forwarding, and
        has less overhead than TCP/IP. It&apos;s essentially a Unix domain
        socket that crosses the VM boundary.
      </p>
      <p>
        GhostVM uses vsock for all host-guest services: health checks, clipboard
        sync, file transfer, event streaming, and port discovery. On the host
        side, the framework provides <code>VZVirtioSocketDevice</code>. On the
        guest side, the macOS kernel exposes <code>AF_VSOCK</code> sockets.
      </p>
      <p>
        It works well — once you get past the surprises.
      </p>

      <h2>Gotcha 1: The Connection Object Must Stay Alive</h2>
      <p>
        On the host side, you connect to a guest vsock port through the
        framework:
      </p>

      <CodeBlock language="swift" title="Connecting to a guest vsock port">
        {`let device = vm.socketDevices.first as! VZVirtioSocketDevice
device.connect(toPort: 5002) { result in
    switch result {
    case .success(let connection):
        let fd = connection.fileDescriptor
        // Use fd for reading/writing...
    case .failure(let error):
        // Handle error
    }
}`}
      </CodeBlock>

      <p>
        See the bug? The <code>connection</code> object is a{" "}
        <code>VZVirtioSocketConnection</code>. When it goes out of scope — when
        the closure returns, or when no strong reference holds it — ARC
        deallocates it. And its <code>deinit</code> closes the underlying file
        descriptor.
      </p>
      <p>
        If you only extract the <code>fileDescriptor</code> and let the
        connection object get released, the fd is immediately closed. The guest
        sees the connection drop, tries to reconnect, the host accepts a new
        connection, the fd closes again, and you end up in a tight
        reconnect loop that pegs the CPU at 100%.
      </p>

      <Callout variant="warning" title="The fix">
        Always store the <code>VZVirtioSocketConnection</code> object itself,
        not just the file descriptor. The caller must keep a strong reference to
        the connection for as long as the fd is in use.
      </Callout>

      <p>
        The correct pattern returns both the connection and the fd (or just the
        connection, and reads the fd from it when needed):
      </p>

      <CodeBlock language="swift" title="Keeping the connection alive">
        {`class GhostClient {
    // Store the connection object to keep the fd alive
    private var connection: VZVirtioSocketConnection?

    func connect(port: UInt32) async throws -> FileHandle {
        let conn = try await device.connect(toPort: port)
        self.connection = conn  // Strong reference prevents dealloc
        return FileHandle(fileDescriptor: conn.fileDescriptor)
    }
}`}
      </CodeBlock>

      <p>
        This is documented nowhere in Apple&apos;s Virtualization.framework
        documentation. The <code>fileDescriptor</code> property exists and works,
        but there&apos;s no mention that it becomes invalid when the parent
        object is deallocated. It&apos;s consistent with how file descriptors
        work in Unix (the owner closes them on cleanup), but the API surface
        makes it easy to get wrong.
      </p>

      <h2>Gotcha 2: kqueue Doesn&apos;t Work for AF_VSOCK on macOS</h2>
      <p>
        The second surprise is worse, and it only manifests on the guest side.
      </p>
      <p>
        When GhostTools (the guest agent) wants to accept incoming vsock
        connections from the host, the natural approach is to create a server
        socket, bind it, listen, and use some event notification mechanism to
        know when a connection arrives. On macOS, the standard options are:
      </p>
      <ul>
        <li>
          <strong>kqueue</strong> — The kernel event notification system (used by
          libdispatch under the hood)
        </li>
        <li>
          <strong>DispatchSourceRead</strong> — GCD&apos;s wrapper around kqueue
        </li>
        <li>
          <strong>poll()</strong> — POSIX polling
        </li>
      </ul>

      <p>
        None of them work for <code>AF_VSOCK</code> server sockets in a macOS
        guest.
      </p>
      <p>
        More precisely: you can set up kqueue with an <code>EVFILT_READ</code>{" "}
        filter on the vsock listening socket, and it will register without error.
        But the event never fires. Incoming connections queue up silently, and
        your event handler never runs. The same is true for{" "}
        <code>DispatchSourceRead</code> (which uses kqueue internally) and{" "}
        <code>poll()</code>. All three accept the socket, register the
        notification, and then simply never notify.
      </p>

      <Callout variant="info" title="This only affects server sockets">
        Regular connected vsock sockets (after <code>accept()</code>) work
        normally with kqueue and GCD. The bug is specific to the listening socket
        not generating readable events when new connections arrive.
      </Callout>

      <h3>The Only Thing That Works: Blocking accept()</h3>
      <p>
        After discovering that no async notification mechanism works, we found
        exactly one pattern that reliably accepts vsock connections in a macOS
        guest:
      </p>

      <CodeBlock language="swift" title="Blocking accept on a dedicated thread">
        {`// Create a non-blocking socket? NO. Must be blocking.
let serverFd = socket(AF_VSOCK, SOCK_STREAM, 0)
// Do NOT set O_NONBLOCK

// Bind and listen as usual
var addr = sockaddr_vm(/* ... */)
bind(serverFd, &addr, socklen_t(MemoryLayout<sockaddr_vm>.size))
listen(serverFd, 5)

// Accept on a dedicated GCD thread — this blocks
DispatchQueue(label: "vsock-accept").async {
    while true {
        let clientFd = accept(serverFd, nil, nil)
        if clientFd < 0 { break }
        // Handle clientFd on another queue
        handleConnection(clientFd)
    }
}`}
      </CodeBlock>

      <p>
        The key requirements:
      </p>
      <ul>
        <li>
          The socket must <strong>not</strong> have <code>O_NONBLOCK</code> set
        </li>
        <li>
          <code>accept()</code> must block on a <strong>dedicated thread</strong>{" "}
          (not the main thread, not a cooperative GCD queue)
        </li>
        <li>
          The thread does nothing but block in <code>accept()</code> and dispatch
          the resulting connections
        </li>
      </ul>

      <p>
        This is the opposite of how you&apos;d normally write a server on macOS.
        The standard pattern — non-blocking socket, kqueue/GCD for event
        notification — is broken for vsock. You have to go back to the
        simplest possible Unix server pattern: a blocking accept loop on its own
        thread.
      </p>

      <h2>Why Does This Happen?</h2>
      <p>
        The <code>AF_VSOCK</code> implementation in macOS&apos;s kernel likely
        doesn&apos;t fully integrate with the kqueue notification path. This
        isn&apos;t an issue on Linux, where vsock works with epoll. It appears
        to be specific to macOS&apos;s kernel implementation of the vsock
        address family.
      </p>
      <p>
        Since vsock in macOS guests is a relatively niche use case (most
        Virtualization.framework users are either running Linux guests or
        connecting from the host side), this hasn&apos;t gotten the attention
        that TCP or Unix domain socket support has.
      </p>

      <h2>Lessons Learned</h2>
      <p>
        Building on virtio-vsock taught us a few broader lessons:
      </p>

      <ol>
        <li>
          <strong>Test your assumptions about familiar APIs.</strong> Vsock
          sockets look like Unix sockets, use the same syscalls, and accept the
          same flags. But the kernel support isn&apos;t identical. Just because{" "}
          <code>setsockopt</code> succeeds doesn&apos;t mean the feature works.
        </li>
        <li>
          <strong>Object lifetime matters in bridged APIs.</strong> When a
          framework gives you a raw resource (like a file descriptor) from a
          managed object, the resource&apos;s lifetime is tied to the object.
          This is obvious in retrospect, but easy to miss when the API surface
          suggests the fd is independent.
        </li>
        <li>
          <strong>Blocking I/O isn&apos;t always wrong.</strong> Modern
          frameworks push you toward non-blocking, event-driven I/O. But when
          the event notification system is broken for your socket type, a
          dedicated blocking thread is simpler and more reliable than any
          workaround.
        </li>
      </ol>

      <p>
        Vsock is a great transport once you know the pitfalls. It&apos;s faster
        than networking, requires no configuration, and provides clean
        host-guest communication. These quirks are the tax you pay for using a
        transport that&apos;s still relatively new to macOS.
      </p>

      <hr />

      <div className="not-prose mt-8">
        <Link
          href="/blog"
          className="text-sm text-ghost-600 dark:text-ghost-400 hover:underline"
        >
          &larr; Back to blog
        </Link>
      </div>
    </>
  );
}
