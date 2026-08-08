# Ghostbox Container Volume API

This page documents the five `cr` volume commands implemented by GhostVM's
persistent-volume adapter. These commands retain the existing `volume.*` wire
method IDs; they do not call Apple container's volume CLI commands.

| Resource | Methods |
|---|---:|
| `volume` | 5 |
| **Total** | **5** |

| Ghostbox Signature | Swift Source |
|---|---|
| <pre><code>ghostbox cr:volume:create &lt;volume:name&gt;&#10;    [--size=8589934592]</code></pre> | [`GhostboxVolumeStore.create(name:sizeInBytes:)`](../../macOS/GhostVMContainerRuntime/Ghostbox/GhostboxVolumeCommands.swift#L32-L85) in `GhostVMContainerRuntime` |
| <pre><code>ghostbox cr:volume:list</code></pre> | [`GhostboxVolumeStore.list()`](../../macOS/GhostVMContainerRuntime/Ghostbox/GhostboxVolumeCommands.swift#L88-L91) in `GhostVMContainerRuntime` |
| <pre><code>ghostbox cr:volume:inspect @&lt;volume:id&gt;</code></pre> | [`GhostboxVolumeStore.inspect(name:)`](../../macOS/GhostVMContainerRuntime/Ghostbox/GhostboxVolumeCommands.swift#L93-L96) in `GhostVMContainerRuntime` |
| <pre><code>ghostbox cr:volume:mount @&lt;volume:id&gt;&#10;    &lt;mount:name&gt;&#10;    --destination &lt;destination:container-path&gt;&#10;    [--read-only=false]</code></pre> | [`GhostboxVolumeStore.makeMount(volumeName:mountReference:destination:readOnly:)`](../../macOS/GhostVMContainerRuntime/Ghostbox/GhostboxVolumeCommands.swift#L110-L130) in `GhostVMContainerRuntime` |
| <pre><code>ghostbox cr:volume:delete @&lt;volume:id&gt;</code></pre> | [`GhostboxVolumeStore.delete(name:)`](../../macOS/GhostVMContainerRuntime/Ghostbox/GhostboxVolumeCommands.swift#L98-L108) in `GhostVMContainerRuntime` |

`inspect` intentionally redacts the outer-host backing path. A volume can have
only one active mount reference, and an active mount prevents deletion.
`delete` permanently removes the volume and its contents.
