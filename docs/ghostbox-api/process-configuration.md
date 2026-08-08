# Ghostbox Process Configuration API

This page maps the 32 Ghostbox process configuration methods to their
corresponding Apple Containerization APIs.

- Ghostbox signatures are sourced from `GHOSTBOX_CLI_COMMANDS.json`.
- Apple API mappings are sourced from
  `macOS/GhostVMContainerRuntime/Ghostbox/GhostboxConfigurationCommands.swift`
  and `macOS/GhostVMContainerRuntime/Ghostbox/GhostboxBuiltinCommands.swift`.
- Apple API links are pinned to Containerization `0.40.1`, revision
  `7800b4642171561c95b5f55500b19e5dce5acd45`.

| Resource | Methods |
|---|---:|
| `rlimit-kind` | 1 |
| `rlimit` | 6 |
| `capabilities` | 10 |
| `process-config` | 15 |
| **Total** | **32** |

## Rlimit Kind

| Ghostbox Signature | Apple API |
|---|---|
| <pre><code>ghostbox cn:rlimit-kind:create &lt;rlimit-kind:name&gt;&#10;    &lt;oci-name:string&gt;</code></pre> | [`LinuxRLimit.Kind.init(_:)`](https://apple.github.io/containerization/documentation/containerization/linuxrlimit/kind-swift.struct/init(_:)) |

## Rlimit

| Ghostbox Signature | Apple API |
|---|---|
| <pre><code>ghostbox cn:rlimit:create &lt;rlimit:name&gt;&#10;    --kind @&lt;rlimit-kind:id&gt;&#10;    --hard &lt;hard:uint64&gt;&#10;    --soft &lt;soft:uint64&gt;</code></pre> | [`LinuxRLimit.init(kind:hard:soft:)`](https://apple.github.io/containerization/documentation/containerization/linuxrlimit/init(kind:hard:soft:)) |
| <pre><code>ghostbox cn:rlimit:create-equal &lt;rlimit:name&gt;&#10;    --kind @&lt;rlimit-kind:id&gt;&#10;    --limit &lt;limit:uint64&gt;</code></pre> | [`LinuxRLimit.init(kind:limit:)`](https://apple.github.io/containerization/documentation/containerization/linuxrlimit/init(kind:limit:)) |
| <pre><code>ghostbox cn:rlimit:kind @&lt;rlimit:id&gt;</code></pre> | [`LinuxRLimit.kind`](https://apple.github.io/containerization/documentation/containerization/linuxrlimit/kind-swift.property) |
| <pre><code>ghostbox cn:rlimit:hard @&lt;rlimit:id&gt;</code></pre> | [`LinuxRLimit.hard`](https://apple.github.io/containerization/documentation/containerization/linuxrlimit/hard) |
| <pre><code>ghostbox cn:rlimit:soft @&lt;rlimit:id&gt;</code></pre> | [`LinuxRLimit.soft`](https://apple.github.io/containerization/documentation/containerization/linuxrlimit/soft) |
| <pre><code>ghostbox cn:rlimit:to-oci @&lt;rlimit:id&gt;</code></pre> | [`LinuxRLimit.toOCI()`](https://apple.github.io/containerization/documentation/containerization/linuxrlimit/tooci()) |

## Capabilities

| Ghostbox Signature | Apple API |
|---|---|
| <pre><code>ghostbox cn:capabilities:create &lt;capabilities:name&gt;&#10;    [--bounding &lt;capability:linux-capability&gt;]...&#10;    [--effective &lt;capability:linux-capability&gt;]...&#10;    [--inheritable &lt;capability:linux-capability&gt;]...&#10;    [--permitted &lt;capability:linux-capability&gt;]...&#10;    [--ambient &lt;capability:linux-capability&gt;]...</code></pre> | [`LinuxCapabilities.init(bounding:effective:inheritable:permitted:ambient:)`](https://apple.github.io/containerization/documentation/containerization/linuxcapabilities/init(bounding:effective:inheritable:permitted:ambient:)) |
| <pre><code>ghostbox cn:capabilities:create-uniform &lt;capabilities:name&gt;&#10;    &lt;capability:linux-capability&gt;...</code></pre> | [`LinuxCapabilities.init(capabilities:)`](https://apple.github.io/containerization/documentation/containerization/linuxcapabilities/init(capabilities:)) |
| <pre><code>ghostbox cn:capabilities:all</code></pre> | [`LinuxCapabilities.allCapabilities`](https://apple.github.io/containerization/documentation/containerization/linuxcapabilities/allcapabilities) |
| <pre><code>ghostbox cn:capabilities:default-oci</code></pre> | [`LinuxCapabilities.defaultOCICapabilities`](https://apple.github.io/containerization/documentation/containerization/linuxcapabilities/defaultocicapabilities) |
| <pre><code>ghostbox cn:capabilities:bounding @&lt;capabilities:id&gt;</code></pre> | [`LinuxCapabilities.bounding`](https://apple.github.io/containerization/documentation/containerization/linuxcapabilities/bounding) |
| <pre><code>ghostbox cn:capabilities:effective @&lt;capabilities:id&gt;</code></pre> | [`LinuxCapabilities.effective`](https://apple.github.io/containerization/documentation/containerization/linuxcapabilities/effective) |
| <pre><code>ghostbox cn:capabilities:inheritable @&lt;capabilities:id&gt;</code></pre> | [`LinuxCapabilities.inheritable`](https://apple.github.io/containerization/documentation/containerization/linuxcapabilities/inheritable) |
| <pre><code>ghostbox cn:capabilities:permitted @&lt;capabilities:id&gt;</code></pre> | [`LinuxCapabilities.permitted`](https://apple.github.io/containerization/documentation/containerization/linuxcapabilities/permitted) |
| <pre><code>ghostbox cn:capabilities:ambient @&lt;capabilities:id&gt;</code></pre> | [`LinuxCapabilities.ambient`](https://apple.github.io/containerization/documentation/containerization/linuxcapabilities/ambient) |
| <pre><code>ghostbox cn:capabilities:to-oci @&lt;capabilities:id&gt;</code></pre> | [`LinuxCapabilities.toOCI()`](https://apple.github.io/containerization/documentation/containerization/linuxcapabilities/tooci()) |

## Process Config

| Ghostbox Signature | Apple API |
|---|---|
| <pre><code>ghostbox cn:process-config:default-path</code></pre> | [`LinuxProcessConfiguration.defaultPath`](https://apple.github.io/containerization/documentation/containerization/linuxprocessconfiguration/defaultpath) |
| <pre><code>ghostbox cn:process-config:create &lt;process-config:name&gt;&#10;    &lt;argument:string&gt;...&#10;    [--environment &lt;assignment:string&gt;]...&#10;    [--working-directory=/]&#10;    [--user &lt;user:oci-user&gt;]&#10;    [--rlimit @&lt;rlimit:id&gt;]...&#10;    [--no-new-privileges=false]&#10;    [--capabilities @&lt;capabilities:id&gt;]&#10;    [--terminal=false]&#10;    [--stdin @&lt;reader-stream:id&gt;]&#10;    [--stdout @&lt;writer:id&gt;]&#10;    [--stderr @&lt;writer:id&gt;]</code></pre> | [`LinuxProcessConfiguration.init(arguments:environmentVariables:workingDirectory:user:rlimits:noNewPrivileges:capabilities:terminal:stdin:stdout:stderr:)`](https://apple.github.io/containerization/documentation/containerization/linuxprocessconfiguration/init(arguments:environmentvariables:workingdirectory:user:rlimits:nonewprivileges:capabilities:terminal:stdin:stdout:stderr:)) |
| <pre><code>ghostbox cn:process-config:from-image-config &lt;process-config:name&gt;&#10;    &lt;image-config:oci-image-config&gt;</code></pre> | [`LinuxProcessConfiguration.init(from:)`](https://apple.github.io/containerization/documentation/containerization/linuxprocessconfiguration/init(from:)) |
| <pre><code>ghostbox cn:process-config:set-terminal-io @&lt;process-config:id&gt;&#10;    @&lt;terminal:id&gt;</code></pre> | [`LinuxProcessConfiguration.setTerminalIO(terminal:)`](https://apple.github.io/containerization/documentation/containerization/linuxprocessconfiguration/setterminalio(terminal:)) |
| <pre><code>ghostbox cn:process-config:arguments @&lt;process-config:id&gt;</code></pre> | [`LinuxProcessConfiguration.arguments`](https://apple.github.io/containerization/documentation/containerization/linuxprocessconfiguration/arguments) |
| <pre><code>ghostbox cn:process-config:environment-variables @&lt;process-config:id&gt;</code></pre> | [`LinuxProcessConfiguration.environmentVariables`](https://apple.github.io/containerization/documentation/containerization/linuxprocessconfiguration/environmentvariables) |
| <pre><code>ghostbox cn:process-config:working-directory @&lt;process-config:id&gt;</code></pre> | [`LinuxProcessConfiguration.workingDirectory`](https://apple.github.io/containerization/documentation/containerization/linuxprocessconfiguration/workingdirectory) |
| <pre><code>ghostbox cn:process-config:user @&lt;process-config:id&gt;</code></pre> | [`LinuxProcessConfiguration.user`](https://apple.github.io/containerization/documentation/containerization/linuxprocessconfiguration/user) |
| <pre><code>ghostbox cn:process-config:rlimits @&lt;process-config:id&gt;</code></pre> | [`LinuxProcessConfiguration.rlimits`](https://apple.github.io/containerization/documentation/containerization/linuxprocessconfiguration/rlimits) |
| <pre><code>ghostbox cn:process-config:no-new-privileges @&lt;process-config:id&gt;</code></pre> | [`LinuxProcessConfiguration.noNewPrivileges`](https://apple.github.io/containerization/documentation/containerization/linuxprocessconfiguration/nonewprivileges) |
| <pre><code>ghostbox cn:process-config:capabilities @&lt;process-config:id&gt;</code></pre> | [`LinuxProcessConfiguration.capabilities`](https://apple.github.io/containerization/documentation/containerization/linuxprocessconfiguration/capabilities) |
| <pre><code>ghostbox cn:process-config:terminal @&lt;process-config:id&gt;</code></pre> | [`LinuxProcessConfiguration.terminal`](https://apple.github.io/containerization/documentation/containerization/linuxprocessconfiguration/terminal) |
| <pre><code>ghostbox cn:process-config:stdin @&lt;process-config:id&gt;</code></pre> | [`LinuxProcessConfiguration.stdin`](https://apple.github.io/containerization/documentation/containerization/linuxprocessconfiguration/stdin) |
| <pre><code>ghostbox cn:process-config:stdout @&lt;process-config:id&gt;</code></pre> | [`LinuxProcessConfiguration.stdout`](https://apple.github.io/containerization/documentation/containerization/linuxprocessconfiguration/stdout) |
| <pre><code>ghostbox cn:process-config:stderr @&lt;process-config:id&gt;</code></pre> | [`LinuxProcessConfiguration.stderr`](https://apple.github.io/containerization/documentation/containerization/linuxprocessconfiguration/stderr) |
