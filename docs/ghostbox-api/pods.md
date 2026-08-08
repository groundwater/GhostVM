# Ghostbox Pods API

This page maps the 46 Ghostbox pod methods to their corresponding Apple
Containerization APIs.

- Ghostbox signatures are sourced from `GHOSTBOX_CLI_COMMANDS.json`.
- Apple API mappings are sourced from `GhostboxPodCommands.swift`.
- Apple API links are pinned to Containerization `0.40.1`, revision
  `7800b4642171561c95b5f55500b19e5dce5acd45`.

| Resource | Methods |
|---|---:|
| `pod-volume` | 1 |
| `pod-config` | 11 |
| `pod-container-config` | 13 |
| `pod` | 21 |
| **Total** | **46** |

## Pod Volume

| Ghostbox Signature | Apple API |
|---|---|
| <pre><code>ghostbox cn:pod-volume:create &lt;pod-volume:name&gt;&#10;    --name &lt;volume-name:string&gt;&#10;    --source &lt;source:pod-volume-source&gt;&#10;    --format &lt;format:string&gt;</code></pre> | [`LinuxPod.PodVolume.init(name:source:format:)`](https://apple.github.io/containerization/documentation/containerization/linuxpod/podvolume/init(name:source:format:)) |

## Pod Configuration

The `set-*` commands assign the supplied value to the linked documented
`LinuxPod.Configuration` property.

| Ghostbox Signature | Apple API |
|---|---|
| <pre><code>ghostbox cn:pod-config:create &lt;pod-config:name&gt;</code></pre> | [`LinuxPod.Configuration.init()`](https://apple.github.io/containerization/documentation/containerization/linuxpod/configuration/init()) |
| <pre><code>ghostbox cn:pod-config:set-cpus @&lt;pod-config:id&gt; &lt;cpus:int&gt;</code></pre> | [`LinuxPod.Configuration.cpus`](https://apple.github.io/containerization/documentation/containerization/linuxpod/configuration/cpus) |
| <pre><code>ghostbox cn:pod-config:set-memory @&lt;pod-config:id&gt; &lt;bytes:uint64&gt;</code></pre> | [`LinuxPod.Configuration.memoryInBytes`](https://apple.github.io/containerization/documentation/containerization/linuxpod/configuration/memoryinbytes) |
| <pre><code>ghostbox cn:pod-config:set-interfaces @&lt;pod-config:id&gt; @&lt;interface:id&gt;...</code></pre> | [`LinuxPod.Configuration.interfaces`](https://apple.github.io/containerization/documentation/containerization/linuxpod/configuration/interfaces) |
| <pre><code>ghostbox cn:pod-config:set-virtualization @&lt;pod-config:id&gt; &lt;enabled:bool&gt;</code></pre> | [`LinuxPod.Configuration.virtualization`](https://apple.github.io/containerization/documentation/containerization/linuxpod/configuration/virtualization) |
| <pre><code>ghostbox cn:pod-config:set-boot-log @&lt;pod-config:id&gt; @&lt;boot-log:id&gt;&#124;null</code></pre> | [`LinuxPod.Configuration.bootLog`](https://apple.github.io/containerization/documentation/containerization/linuxpod/configuration/bootlog) |
| <pre><code>ghostbox cn:pod-config:set-share-process-namespace @&lt;pod-config:id&gt; &lt;enabled:bool&gt;</code></pre> | [`LinuxPod.Configuration.shareProcessNamespace`](https://apple.github.io/containerization/documentation/containerization/linuxpod/configuration/shareprocessnamespace) |
| <pre><code>ghostbox cn:pod-config:set-hostname @&lt;pod-config:id&gt; &lt;hostname:string&gt;&#124;null</code></pre> | [`LinuxPod.Configuration.hostname`](https://apple.github.io/containerization/documentation/containerization/linuxpod/configuration/hostname) |
| <pre><code>ghostbox cn:pod-config:set-dns @&lt;pod-config:id&gt; @&lt;dns:id&gt;&#124;null</code></pre> | [`LinuxPod.Configuration.dns`](https://apple.github.io/containerization/documentation/containerization/linuxpod/configuration/dns) |
| <pre><code>ghostbox cn:pod-config:set-hosts @&lt;pod-config:id&gt; @&lt;hosts:id&gt;&#124;null</code></pre> | [`LinuxPod.Configuration.hosts`](https://apple.github.io/containerization/documentation/containerization/linuxpod/configuration/hosts) |
| <pre><code>ghostbox cn:pod-config:set-volumes @&lt;pod-config:id&gt; @&lt;pod-volume:id&gt;...</code></pre> | [`LinuxPod.Configuration.volumes`](https://apple.github.io/containerization/documentation/containerization/linuxpod/configuration/volumes) |

## Pod Container Configuration

The `set-*` commands assign the supplied value to the linked documented
`LinuxPod.ContainerConfiguration` property.

| Ghostbox Signature | Apple API |
|---|---|
| <pre><code>ghostbox cn:pod-container-config:create &lt;pod-container-config:name&gt;</code></pre> | [`LinuxPod.ContainerConfiguration.init()`](https://apple.github.io/containerization/documentation/containerization/linuxpod/containerconfiguration/init()) |
| <pre><code>ghostbox cn:pod-container-config:set-process @&lt;pod-container-config:id&gt; @&lt;process-config:id&gt;</code></pre> | [`LinuxPod.ContainerConfiguration.process`](https://apple.github.io/containerization/documentation/containerization/linuxpod/containerconfiguration/process) |
| <pre><code>ghostbox cn:pod-container-config:set-cpus @&lt;pod-container-config:id&gt; &lt;cpus:int&gt;&#124;null</code></pre> | [`LinuxPod.ContainerConfiguration.cpus`](https://apple.github.io/containerization/documentation/containerization/linuxpod/containerconfiguration/cpus) |
| <pre><code>ghostbox cn:pod-container-config:set-memory @&lt;pod-container-config:id&gt; &lt;bytes:uint64&gt;&#124;null</code></pre> | [`LinuxPod.ContainerConfiguration.memoryInBytes`](https://apple.github.io/containerization/documentation/containerization/linuxpod/containerconfiguration/memoryinbytes) |
| <pre><code>ghostbox cn:pod-container-config:set-hostname @&lt;pod-container-config:id&gt; &lt;hostname:string&gt;&#124;null</code></pre> | [`LinuxPod.ContainerConfiguration.hostname`](https://apple.github.io/containerization/documentation/containerization/linuxpod/containerconfiguration/hostname) |
| <pre><code>ghostbox cn:pod-container-config:set-sysctl @&lt;pod-container-config:id&gt; &lt;key-value:string&gt;...</code></pre> | [`LinuxPod.ContainerConfiguration.sysctl`](https://apple.github.io/containerization/documentation/containerization/linuxpod/containerconfiguration/sysctl) |
| <pre><code>ghostbox cn:pod-container-config:set-mounts @&lt;pod-container-config:id&gt; @&lt;mount:id&gt;...</code></pre> | [`LinuxPod.ContainerConfiguration.mounts`](https://apple.github.io/containerization/documentation/containerization/linuxpod/containerconfiguration/mounts) |
| <pre><code>ghostbox cn:pod-container-config:set-masked-paths @&lt;pod-container-config:id&gt; &lt;path:container-path&gt;...</code></pre> | [`LinuxPod.ContainerConfiguration.maskedPaths`](https://apple.github.io/containerization/documentation/containerization/linuxpod/containerconfiguration/maskedpaths) |
| <pre><code>ghostbox cn:pod-container-config:set-readonly-paths @&lt;pod-container-config:id&gt; &lt;path:container-path&gt;...</code></pre> | [`LinuxPod.ContainerConfiguration.readonlyPaths`](https://apple.github.io/containerization/documentation/containerization/linuxpod/containerconfiguration/readonlypaths) |
| <pre><code>ghostbox cn:pod-container-config:set-sockets @&lt;pod-container-config:id&gt; @&lt;socket:id&gt;...</code></pre> | [`LinuxPod.ContainerConfiguration.sockets`](https://apple.github.io/containerization/documentation/containerization/linuxpod/containerconfiguration/sockets) |
| <pre><code>ghostbox cn:pod-container-config:set-dns @&lt;pod-container-config:id&gt; @&lt;dns:id&gt;&#124;null</code></pre> | [`LinuxPod.ContainerConfiguration.dns`](https://apple.github.io/containerization/documentation/containerization/linuxpod/containerconfiguration/dns) |
| <pre><code>ghostbox cn:pod-container-config:set-hosts @&lt;pod-container-config:id&gt; @&lt;hosts:id&gt;&#124;null</code></pre> | [`LinuxPod.ContainerConfiguration.hosts`](https://apple.github.io/containerization/documentation/containerization/linuxpod/containerconfiguration/hosts) |
| <pre><code>ghostbox cn:pod-container-config:set-use-init @&lt;pod-container-config:id&gt; &lt;enabled:bool&gt;</code></pre> | [`LinuxPod.ContainerConfiguration.useInit`](https://apple.github.io/containerization/documentation/containerization/linuxpod/containerconfiguration/useinit) |

## Pod

| Ghostbox Signature | Apple API |
|---|---|
| <pre><code>ghostbox cn:pod:create-direct &lt;pod:name&gt;&#10;    --vmm @&lt;vmm:id&gt;&#10;    --configuration @&lt;pod-config:id&gt;</code></pre> | [`LinuxPod.init(_:vmm:logger:configuration:)`](https://apple.github.io/containerization/documentation/containerization/linuxpod/init(_:vmm:logger:configuration:)) |
| <pre><code>ghostbox cn:pod:id @&lt;pod:id&gt;</code></pre> | [`LinuxPod.id`](https://apple.github.io/containerization/documentation/containerization/linuxpod/id) |
| <pre><code>ghostbox cn:pod:config @&lt;pod:id&gt;</code></pre> | [`LinuxPod.config`](https://apple.github.io/containerization/documentation/containerization/linuxpod/config) |
| <pre><code>ghostbox cn:pod:cpus @&lt;pod:id&gt;</code></pre> | [`LinuxPod.cpus`](https://apple.github.io/containerization/documentation/containerization/linuxpod/cpus) |
| <pre><code>ghostbox cn:pod:memory @&lt;pod:id&gt;</code></pre> | [`LinuxPod.memoryInBytes`](https://apple.github.io/containerization/documentation/containerization/linuxpod/memoryinbytes) |
| <pre><code>ghostbox cn:pod:interfaces @&lt;pod:id&gt;</code></pre> | [`LinuxPod.interfaces`](https://apple.github.io/containerization/documentation/containerization/linuxpod/interfaces) |
| <pre><code>ghostbox cn:pod:add-container @&lt;pod:id&gt;&#10;    &lt;container:name&gt;&#10;    --rootfs @&lt;mount:id&gt;&#10;    --configuration @&lt;pod-container-config:id&gt;</code></pre> | [`LinuxPod.addContainer(_:rootfs:configuration:)`](https://apple.github.io/containerization/documentation/containerization/linuxpod/addcontainer(_:rootfs:configuration:)) |
| <pre><code>ghostbox cn:pod:create @&lt;pod:id&gt;</code></pre> | [`LinuxPod.create()`](https://apple.github.io/containerization/documentation/containerization/linuxpod/create()) |
| <pre><code>ghostbox cn:pod:start-container @&lt;pod:id&gt; @&lt;pod-container:id&gt;</code></pre> | [`LinuxPod.startContainer(_:)`](https://apple.github.io/containerization/documentation/containerization/linuxpod/startcontainer(_:)) |
| <pre><code>ghostbox cn:pod:stop-container @&lt;pod:id&gt; @&lt;pod-container:id&gt;</code></pre> | [`LinuxPod.stopContainer(_:)`](https://apple.github.io/containerization/documentation/containerization/linuxpod/stopcontainer(_:)) |
| <pre><code>ghostbox cn:pod:stop @&lt;pod:id&gt;</code></pre> | [`LinuxPod.stop()`](https://apple.github.io/containerization/documentation/containerization/linuxpod/stop()) |
| <pre><code>ghostbox cn:pod:kill-container @&lt;pod:id&gt; @&lt;pod-container:id&gt; &lt;signal:linux-signal&gt;</code></pre> | [`LinuxPod.killContainer(_:signal:)`](https://apple.github.io/containerization/documentation/containerization/linuxpod/killcontainer(_:signal:)) |
| <pre><code>ghostbox cn:pod:wait-container @&lt;pod:id&gt;&#10;    @&lt;pod-container:id&gt;&#10;    [--timeout-seconds &lt;seconds:int64&gt;]</code></pre> | [`LinuxPod.waitContainer(_:timeoutInSeconds:)`](https://apple.github.io/containerization/documentation/containerization/linuxpod/waitcontainer(_:timeoutinseconds:)) |
| <pre><code>ghostbox cn:pod:resize-container @&lt;pod:id&gt;&#10;    @&lt;pod-container:id&gt;&#10;    &lt;width:uint16&gt;&#10;    &lt;height:uint16&gt;</code></pre> | [`LinuxPod.resizeContainer(_:to:)`](https://apple.github.io/containerization/documentation/containerization/linuxpod/resizecontainer(_:to:)) |
| <pre><code>ghostbox cn:pod:exec-in-container @&lt;pod:id&gt;&#10;    @&lt;pod-container:id&gt;&#10;    &lt;process:name&gt;&#10;    --configuration @&lt;process-config:id&gt;</code></pre> | [`LinuxPod.execInContainer(_:processID:configuration:)`](https://apple.github.io/containerization/documentation/containerization/linuxpod/execincontainer(_:processid:configuration:)) |
| <pre><code>ghostbox cn:pod:list-containers @&lt;pod:id&gt;</code></pre> | [`LinuxPod.listContainers()`](https://apple.github.io/containerization/documentation/containerization/linuxpod/listcontainers()) |
| <pre><code>ghostbox cn:pod:statistics @&lt;pod:id&gt;&#10;    [--container @&lt;pod-container:id&gt;]...&#10;    [--category &lt;category:statistics-category&gt;]...</code></pre> | [`LinuxPod.statistics(containerIDs:categories:)`](https://apple.github.io/containerization/documentation/containerization/linuxpod/statistics(containerids:categories:)) |
| <pre><code>ghostbox cn:pod:dial-vsock @&lt;pod:id&gt;&#10;    &lt;port:uint32&gt;</code></pre> | [`LinuxPod.dialVsock(port:)`](https://apple.github.io/containerization/documentation/containerization/linuxpod/dialvsock(port:)) |
| <pre><code>ghostbox cn:pod:filesystem-operation @&lt;pod:id&gt;&#10;    @&lt;pod-container:id&gt;&#10;    &lt;operation:freeze&#124;thaw&#124;trim&gt;&#10;    &lt;path:container-path&gt;</code></pre> | [`LinuxPod.filesystemOperation(_:operation:path:)`](https://apple.github.io/containerization/documentation/containerization/linuxpod/filesystemoperation(_:operation:path:)) |
| <pre><code>ghostbox cn:pod:close-container-stdin @&lt;pod:id&gt; @&lt;pod-container:id&gt;</code></pre> | [`LinuxPod.closeContainerStdin(_:)`](https://apple.github.io/containerization/documentation/containerization/linuxpod/closecontainerstdin(_:)) |
| <pre><code>ghostbox cn:pod:relay-unix-socket @&lt;pod:id&gt;&#10;    @&lt;pod-container:id&gt;&#10;    @&lt;socket:id&gt;</code></pre> | [`LinuxPod.relayUnixSocket(_:socket:)`](https://apple.github.io/containerization/documentation/containerization/linuxpod/relayunixsocket(_:socket:)) |
