import type { Metadata } from "next";
import CodeBlock from "@/components/docs/CodeBlock";
import Callout from "@/components/docs/Callout";
import PrevNextNav from "@/components/docs/PrevNextNav";

export const metadata: Metadata = { title: "Port Forwarding - GhostVM Docs" };

export default function PortForwarding() {
  return (
    <>
      <h1>Port Forwarding</h1>
      <p className="lead">
        Port forwarding maps ports on the guest VM to{" "}
        <code>localhost</code> on the host, making services running inside the
        VM accessible from the host Mac.
      </p>

      <h2>Configuring Port Forwards</h2>

      <h3>In the GUI</h3>
      <p>There are two ways to configure port forwards:</p>
      <ul>
        <li>
          <strong>Edit VM Settings</strong> — right-click a VM, choose
          &ldquo;Edit Settings&rdquo;, and add port forwards in the Port
          Forwards section. These are saved to <code>config.json</code> and
          persist across restarts.
        </li>
        <li>
          <strong>Runtime editor</strong> — click the network icon in the VM
          toolbar to add or remove forwards while the VM is running.
        </li>
      </ul>

      <h3>In config.json</h3>
      <CodeBlock language="json">
        {`{
  "portForwards": [
    { "hostPort": 8080, "guestPort": 80 },
    { "hostPort": 2222, "guestPort": 22 }
  ]
}`}
      </CodeBlock>

      <h2>Auto Port Mapping</h2>
      <p>
        GhostVM includes automatic port mapping that detects listening ports
        inside the guest (reported by GhostTools) and creates port forwards
        automatically. If the desired host port is already in use, GhostVM falls
        back to an available port.
      </p>

      <Callout variant="info" title="Quick Access">
        Click a port forward in the toolbar menu to copy its{" "}
        <code>localhost</code> URL to the clipboard.
      </Callout>

      <h2>How it Works</h2>
      <p>
        Port forwarding is implemented using NIO (Swift NIO). For each forward,
        GhostVM:
      </p>
      <ol>
        <li>
          Binds a TCP listener on <code>localhost:{"{hostPort}"}</code>
        </li>
        <li>
          When a connection arrives, opens a vsock connection to the guest on
          the guest port
        </li>
        <li>
          Relays data bidirectionally between the TCP socket and the vsock
          connection
        </li>
      </ol>

      <h2>Common Use Cases</h2>
      <table>
        <thead>
          <tr>
            <th>Host Port</th>
            <th>Guest Port</th>
            <th>Use Case</th>
          </tr>
        </thead>
        <tbody>
          <tr>
            <td>2222</td>
            <td>22</td>
            <td>SSH access</td>
          </tr>
          <tr>
            <td>8080</td>
            <td>80</td>
            <td>Web server</td>
          </tr>
          <tr>
            <td>3000</td>
            <td>3000</td>
            <td>Dev server</td>
          </tr>
          <tr>
            <td>5432</td>
            <td>5432</td>
            <td>PostgreSQL</td>
          </tr>
        </tbody>
      </table>

      <PrevNextNav currentHref="/docs/services/port-forwarding" />
    </>
  );
}
