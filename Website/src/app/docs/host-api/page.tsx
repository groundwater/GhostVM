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
        programmatic access to VM operations. This is the foundation that
        powers the MCP server and enables custom integrations.
      </p>

      <h2>Overview</h2>
      <p>
        When a VM starts, the GhostVMHelper process creates a Unix socket at:
      </p>
      <CodeBlock language="text">
        {`~/Library/Application Support/GhostVM/api/<service-name>.sock`}
      </CodeBlock>
      <p>
        The service name is derived from the VM bundle path. Any process on the
        host can connect to this socket to query or control the VM.
      </p>

      <h2>Wire Protocol</h2>
      <p>
        The Host API uses <strong>newline-delimited JSON</strong>. Each
        request/response is a single JSON object followed by a newline
        character.
      </p>
      <CodeBlock language="json" title="Request format">
        {`{"method":"GET","path":"/vm/status","headers":{},"body":null}\n`}
      </CodeBlock>
      <CodeBlock language="json" title="Response format">
        {`{"status":200,"headers":{"Content-Type":"application/json"},"body":"{\\"state\\":\\"running\\"}"}\n`}
      </CodeBlock>
      <p>
        For binary data (file transfers), the response header includes a{" "}
        <code>Content-Length</code> field and raw bytes follow the header line.
      </p>

      <h2>Endpoints</h2>

      <h3>Host-only Endpoints</h3>
      <p>
        These endpoints are handled directly by the Helper process without
        communicating with the guest.
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
            <td><code>/vm/status</code></td>
            <td>Returns VM state, health status, and Helper PID</td>
          </tr>
          <tr>
            <td><code>POST</code></td>
            <td><code>/vm/stop</code></td>
            <td>Request graceful VM shutdown</td>
          </tr>
          <tr>
            <td><code>POST</code></td>
            <td><code>/vm/suspend</code></td>
            <td>Suspend the VM and save state</td>
          </tr>
        </tbody>
      </table>

      <h3>Guest Proxy Endpoints</h3>
      <p>
        These endpoints proxy requests through the vsock connection to the
        GhostTools agent running inside the guest.
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
            <td><code>POST</code></td>
            <td><code>/api/v1/files/send</code></td>
            <td>Send a file to the guest (binary, X-Filename header)</td>
          </tr>
          <tr>
            <td><code>GET</code></td>
            <td><code>/api/v1/files/:path</code></td>
            <td>Fetch a file from the guest (binary response)</td>
          </tr>
          <tr>
            <td><code>GET</code></td>
            <td><code>/api/v1/logs</code></td>
            <td>Get buffered guest logs</td>
          </tr>
          <tr>
            <td><code>POST</code></td>
            <td><code>/api/v1/open</code></td>
            <td>Open a path in the guest Finder</td>
          </tr>
        </tbody>
      </table>

      <h2>Example Usage</h2>
      <p>
        You can interact with the Host API using any Unix socket client. Here is
        an example using <code>socat</code>:
      </p>
      <CodeBlock language="bash" title="Query VM status with socat">
        {`echo '{"method":"GET","path":"/vm/status","headers":{}}' | \\
  socat - UNIX-CONNECT:"$HOME/Library/Application Support/GhostVM/api/your-vm.sock"`}
      </CodeBlock>
      <p>Or with a simple Python script:</p>
      <CodeBlock language="python" title="Python example">
        {`import socket, json

sock_path = "~/Library/Application Support/GhostVM/api/your-vm.sock"
sock_path = os.path.expanduser(sock_path)

s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(sock_path)

request = json.dumps({"method": "GET", "path": "/health", "headers": {}})
s.sendall((request + "\\n").encode())

response = b""
while True:
    chunk = s.recv(4096)
    if not chunk or b"\\n" in chunk:
        response += chunk
        break
    response += chunk

print(json.loads(response.decode().strip()))
s.close()`}
      </CodeBlock>

      <h2>Relationship to MCP</h2>
      <p>
        The <a href="/docs/mcp">MCP server</a> (<code>vmctl mcp</code>) is a
        thin bridge between JSON-RPC on stdin/stdout and the Host API socket.
        Each MCP tool call maps to exactly one Host API request. If you need
        direct programmatic access without MCP, you can connect to the socket
        directly.
      </p>

      <Callout variant="info" title="Connection Lifecycle">
        Each connection is single-request: send one request, read one response,
        then the connection is closed by the server. Open a new connection for
        each subsequent request.
      </Callout>

      <PrevNextNav currentHref="/docs/host-api" />
    </>
  );
}
