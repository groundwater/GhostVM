import type { Metadata } from "next";
import CodeBlock from "@/components/docs/CodeBlock";
import Callout from "@/components/docs/Callout";
import PrevNextNav from "@/components/docs/PrevNextNav";
import { siteConfig } from "@/config/site";

export const metadata: Metadata = {
  title: "Building from Source - GhostVM Docs",
};

export default function BuildingFromSource() {
  return (
    <>
      <h1>Building from Source</h1>
      <p className="lead">
        Build GhostVM from source to contribute or run a development version.
      </p>

      <h2>Prerequisites</h2>
      <ul>
        <li>macOS 15+ (Sequoia) on Apple Silicon (M1 or later)</li>
        <li>Xcode 15+</li>
        <li>
          <a href="https://github.com/yonaskolb/XcodeGen">XcodeGen</a>
        </li>
      </ul>
      <CodeBlock language="bash">{`brew install xcodegen`}</CodeBlock>

      <h2>Clone and Build</h2>
      <CodeBlock language="bash">
        {`git clone ${siteConfig.repo}
cd ghostvm
make app`}
      </CodeBlock>
      <p>
        This generates the Xcode project from <code>project.yml</code> and
        builds the app. The built app is placed in <code>build/</code>.
      </p>

      <h2>Code Signing</h2>
      <p>
        GhostVM requires the{" "}
        <code>com.apple.security.virtualization</code> entitlement to use
        Apple&apos;s Virtualization.framework. The build automatically signs the
        app with your local <strong>Apple Development</strong> certificate.
      </p>
      <p>
        You need a valid Apple Developer identity in your keychain. Verify you
        have one with:
      </p>
      <CodeBlock language="bash">
        {`security find-identity -v -p codesigning`}
      </CodeBlock>
      <p>
        Look for a line containing <code>Apple Development</code>. If you
        don&apos;t have one, open Xcode, go to Settings &rarr; Accounts, and
        sign in with your Apple ID &mdash; Xcode will create the certificate
        automatically.
      </p>
      <p>
        To override the signing identity, pass <code>CODESIGN_ID</code>:
      </p>
      <CodeBlock language="bash">
        {`make app CODESIGN_ID="Apple Development: you@example.com (TEAMID)"`}
      </CodeBlock>

      <Callout variant="warning" title="Ad-hoc signing won't work">
        Ad-hoc signed builds (<code>-s &quot;-&quot;</code>) cannot use the
        virtualization entitlement. You must sign with a real Apple Development
        certificate or the app will crash on launch.
      </Callout>

      <h2>Make Targets</h2>
      <table>
        <thead>
          <tr>
            <th>Target</th>
            <th>Description</th>
          </tr>
        </thead>
        <tbody>
          <tr>
            <td><code>make app</code></td>
            <td>Build the GUI app (auto-generates Xcode project)</td>
          </tr>
          <tr>
            <td><code>make cli</code></td>
            <td>Build the <code>vmctl</code> CLI tool</td>
          </tr>
          <tr>
            <td><code>make generate</code></td>
            <td>Generate the Xcode project from <code>project.yml</code></td>
          </tr>
          <tr>
            <td><code>make run</code></td>
            <td>Build and run attached to terminal</td>
          </tr>
          <tr>
            <td><code>make launch</code></td>
            <td>Build and launch detached</td>
          </tr>
          <tr>
            <td><code>make test</code></td>
            <td>Run unit tests</td>
          </tr>
          <tr>
            <td><code>make clean</code></td>
            <td>Remove build artifacts and generated project</td>
          </tr>
        </tbody>
      </table>

      <Callout variant="info" title="XcodeGen">
        The Xcode project is generated from <code>project.yml</code> using
        XcodeGen. Do not edit <code>GhostVM.xcodeproj</code> directly &mdash;
        your changes will be overwritten on the next <code>make generate</code>.
      </Callout>

      <PrevNextNav currentHref="/docs/building-from-source" />
    </>
  );
}
