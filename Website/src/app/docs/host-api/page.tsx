import type { Metadata } from "next";
import CodeBlock from "@/components/docs/CodeBlock";
import Callout from "@/components/docs/Callout";
import PrevNextNav from "@/components/docs/PrevNextNav";

export const metadata: Metadata = { title: "Host API - GhostVM Docs" };

export default function HostAPI() {
  return (
    <>
      <h1>Host API</h1>
      <p className="lead">
        Each running VM exposes a Unix domain socket on the host for
        programmatic access to VM operations. This enables custom integrations
        and scripted automation.
      </p>

      <h2>Overview</h2>
      <p>
        When a VM starts, the GhostVMHelper process creates a Unix socket at:
      </p>
      <CodeBlock language="text">
        {`~/Library/Application Support/GhostVM/api/<VMName>.GhostVM.sock`}
      </CodeBlock>
      <p>
        The socket name is derived from the VM name (e.g. a VM named
        &ldquo;dev&rdquo; gets <code>dev.GhostVM.sock</code>). Any process on
        the host can connect to this socket to query or control the VM.
      </p>

      <h2>Wire Protocol</h2>
      <p>
        The Host API uses <strong>standard HTTP/1.1</strong> over the Unix
        socket. Send a normal HTTP request and read an HTTP response.
      </p>
      <CodeBlock language="text" title="Request format">
        {`GET /health HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\n\r\n`}
      </CodeBlock>
      <CodeBlock language="text" title="Response format">
        {`HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 15\r\n\r\n{"status":"ok"}`}
      </CodeBlock>
      <p>
        Any HTTP client that supports Unix domain sockets works &mdash;{" "}
        <code>curl --unix-socket</code>, Python&apos;s{" "}
        <code>requests_unixsocket</code>, or a raw socket connection.
      </p>

      <h2>Endpoints</h2>
      <p>
        All requests are proxied through the vsock connection to the GhostTools
        agent running inside the guest.
      </p>
      <table>
        <thead>
          <tr>
            <th>Method</th>
            <th>Path</th>
            <th>Description</th>
          </tr>
        </thead>
        <tbody>
          <tr>
            <td><code>GET</code></td>
            <td><code>/health</code></td>
            <td>Check if the guest agent is reachable</td>
          </tr>
          <tr>
            <td><code>GET</code></td>
            <td><code>/api/v1/clipboard</code></td>
            <td>Get guest clipboard contents</td>
          </tr>
          <tr>
            <td><code>POST</code></td>
            <td><code>/api/v1/clipboard</code></td>
            <td>Set guest clipboard contents</td>
          </tr>
          <tr>
            <td><code>GET</code></td>
            <td><code>/api/v1/files</code></td>
            <td>List files queued by the guest</td>
          </tr>
          <tr>
            <td><code>DELETE</code></td>
            <td><code>/api/v1/files</code></td>
            <td>Clear the guest file queue</td>
          </tr>
          <tr>
            <td><code>POST</code></td>
            <td><code>/api/v1/open</code></td>
            <td>Open a path in the guest Finder</td>
          </tr>
          <tr>
            <td><code>POST</code></td>
            <td><code>/api/v1/exec</code></td>
            <td>Execute a shell command in the guest</td>
          </tr>
          <tr>
            <td><code>GET</code></td>
            <td><code>/api/v1/fs?path=&lt;dir&gt;</code></td>
            <td>List directory contents in the guest</td>
          </tr>
          <tr>
            <td><code>GET</code></td>
            <td><code>/api/v1/apps</code></td>
            <td>List running applications in the guest</td>
          </tr>
          <tr>
            <td><code>POST</code></td>
            <td><code>/api/v1/apps/launch</code></td>
            <td>Launch an app by bundle ID</td>
          </tr>
          <tr>
            <td><code>POST</code></td>
            <td><code>/api/v1/apps/activate</code></td>
            <td>Activate (bring to front) an app by bundle ID</td>
          </tr>
          <tr>
            <td><code>POST</code></td>
            <td><code>/api/v1/apps/quit</code></td>
            <td>Quit an app by bundle ID</td>
          </tr>
          <tr>
            <td><code>GET</code></td>
            <td><code>/api/v1/apps/frontmost</code></td>
            <td>Get the frontmost application&apos;s bundle ID</td>
          </tr>
        </tbody>
      </table>

      <h2>Example Usage</h2>
      <p>
        You can interact with the Host API using any Unix socket HTTP client.
        Here is an example using <code>curl</code>:
      </p>
      <CodeBlock language="bash" title="Check health with curl">
        {`curl --unix-socket ~/Library/Application\\ Support/GhostVM/api/dev.GhostVM.sock \\
  http://localhost/health`}
      </CodeBlock>
      <CodeBlock language="bash" title="Run a command in the guest">
        {`curl --unix-socket ~/Library/Application\\ Support/GhostVM/api/dev.GhostVM.sock \\
  -X POST -H "Content-Type: application/json" \\
  -d '{"command":"uname","args":["-a"]}' \\
  http://localhost/api/v1/exec`}
      </CodeBlock>
      <p>Or with a simple Python script:</p>
      <CodeBlock language="python" title="Python example">
        {`import socket, os, json

sock_path = os.path.expanduser(
    "~/Library/Application Support/GhostVM/api/dev.GhostVM.sock"
)

s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(sock_path)

request = "GET /health HTTP/1.1\\r\\nHost: localhost\\r\\nContent-Length: 0\\r\\n\\r\\n"
s.sendall(request.encode())

response = b""
while True:
    chunk = s.recv(4096)
    if not chunk:
        break
    response += chunk

print(response.decode())
s.close()`}
      </CodeBlock>

      <Callout variant="info" title="Connection Lifecycle">
        Each connection is single-request: send one request, read one response,
        then the connection is closed by the server. Open a new connection for
        each subsequent request.
      </Callout>

      <PrevNextNav currentHref="/docs/host-api" />
    </>
  );
}
