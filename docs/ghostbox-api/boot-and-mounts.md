# Ghostbox Boot and Mounts API

This page maps the 34 Ghostbox boot and mount methods to their corresponding
Apple Containerization APIs.

- Ghostbox signatures are sourced from `GHOSTBOX_CLI_COMMANDS.json`.
- Apple API links are pinned to Containerization `0.40.1`, revision
  `7800b4642171561c95b5f55500b19e5dce5acd45`.

| Resource | Methods |
|---|---:|
| `kernel-command-line` | 7 |
| `kernel` | 5 |
| `kernel-image` | 5 |
| `init-image` | 4 |
| `mount` | 12 |
| `boot-log` | 1 |
| **Total** | **34** |

## Kernel Command Line

| Ghostbox Signature | Apple API |
|---|---|
| <pre><code>ghostbox cn:kernel-command-line:create &lt;command-line:name&gt;&#10;    [--kernel-argument &lt;argument:string&gt;]...&#10;    [--init-argument &lt;argument:string&gt;]...</code></pre> | [`Kernel.CommandLine.init(kernelArgs:initArgs:)`](https://apple.github.io/containerization/documentation/containerization/kernel/commandline-swift.struct/init(kernelargs:initargs:)) |
| <pre><code>ghostbox cn:kernel-command-line:create-debug &lt;command-line:name&gt;&#10;    &lt;debug:bool&gt;&#10;    &lt;panic:int&gt;&#10;    [--init-argument &lt;argument:string&gt;]...</code></pre> | [`Kernel.CommandLine.init(debug:panic:initArgs:)`](https://apple.github.io/containerization/documentation/containerization/kernel/commandline-swift.struct/init(debug:panic:initargs:)) |
| <pre><code>ghostbox cn:kernel-command-line:add-debug @&lt;kernel-command-line:id&gt;</code></pre> | [`Kernel.CommandLine.addDebug()`](https://apple.github.io/containerization/documentation/containerization/kernel/commandline-swift.struct/adddebug()) |
| <pre><code>ghostbox cn:kernel-command-line:add-panic @&lt;kernel-command-line:id&gt; &lt;level:int&gt;</code></pre> | [`Kernel.CommandLine.addPanic(level:)`](https://apple.github.io/containerization/documentation/containerization/kernel/commandline-swift.struct/addpanic(level:)) |
| <pre><code>ghostbox cn:kernel-command-line:set-agent-log-level @&lt;kernel-command-line:id&gt; &lt;level:logger-level&gt;</code></pre> | [`Kernel.CommandLine.setAgentLogLevel(level:)`](https://apple.github.io/containerization/documentation/containerization/kernel/commandline-swift.struct/setagentloglevel(level:)) |
| <pre><code>ghostbox cn:kernel-command-line:kernel-arguments @&lt;kernel-command-line:id&gt;</code></pre> | [`Kernel.CommandLine.kernelArgs`](https://apple.github.io/containerization/documentation/containerization/kernel/commandline-swift.struct/kernelargs) |
| <pre><code>ghostbox cn:kernel-command-line:init-arguments @&lt;kernel-command-line:id&gt;</code></pre> | [`Kernel.CommandLine.initArgs`](https://apple.github.io/containerization/documentation/containerization/kernel/commandline-swift.struct/initargs) |

## Kernel

| Ghostbox Signature | Apple API |
|---|---|
| <pre><code>ghostbox cn:kernel:create &lt;kernel:name&gt;&#10;    --path &lt;path:host-url&gt;&#10;    --platform &lt;platform:system-platform&gt;&#10;    [--command-line @&lt;kernel-command-line:id&gt;]</code></pre> | [`Kernel.init(path:platform:commandline:)`](https://apple.github.io/containerization/documentation/containerization/kernel/init(path:platform:commandline:)) |
| <pre><code>ghostbox cn:kernel:path @&lt;kernel:id&gt;</code></pre> | [`Kernel.path`](https://apple.github.io/containerization/documentation/containerization/kernel/path) |
| <pre><code>ghostbox cn:kernel:platform @&lt;kernel:id&gt;</code></pre> | [`Kernel.platform`](https://apple.github.io/containerization/documentation/containerization/kernel/platform) |
| <pre><code>ghostbox cn:kernel:kernel-arguments @&lt;kernel:id&gt;</code></pre> | [`Kernel.kernelArgs`](https://apple.github.io/containerization/documentation/containerization/kernel/kernelargs) |
| <pre><code>ghostbox cn:kernel:init-arguments @&lt;kernel:id&gt;</code></pre> | [`Kernel.initArgs`](https://apple.github.io/containerization/documentation/containerization/kernel/initargs) |

Without `--command-line`, `kernel create` supplies a non-debug command line with
panic level zero to the Apple initializer.

## Kernel Image

| Ghostbox Signature | Apple API |
|---|---|
| <pre><code>ghostbox cn:kernel-image:from-image &lt;kernel-image:name&gt;&#10;    @&lt;image:id&gt;</code></pre> | [`KernelImage.init(image:)`](https://apple.github.io/containerization/documentation/containerization/kernelimage/init(image:)) |
| <pre><code>ghostbox cn:kernel-image:create &lt;kernel-image:name&gt;&#10;    &lt;reference:string&gt;&#10;    --kernel @&lt;kernel:id&gt;...&#10;    [--label &lt;key-value:string&gt;]...&#10;    --image-store @&lt;image-store:id&gt;&#10;    --content-store @&lt;content-store:id&gt;</code></pre> | [`KernelImage.create(reference:binaries:labels:imageStore:contentStore:)`](https://apple.github.io/containerization/documentation/containerization/kernelimage/create(reference:binaries:labels:imagestore:contentstore:)) |
| <pre><code>ghostbox cn:kernel-image:kernel @&lt;kernel-image:id&gt;&#10;    &lt;platform:system-platform&gt;</code></pre> | [`KernelImage.kernel(for:)`](https://apple.github.io/containerization/documentation/containerization/kernelimage/kernel(for:)) |
| <pre><code>ghostbox cn:kernel-image:name @&lt;kernel-image:id&gt;</code></pre> | [`KernelImage.name`](https://apple.github.io/containerization/documentation/containerization/kernelimage/name) |
| <pre><code>ghostbox cn:kernel-image:media-type</code></pre> | [`KernelImage.mediaType`](https://apple.github.io/containerization/documentation/containerization/kernelimage/mediatype) |

## Init Image

| Ghostbox Signature | Apple API |
|---|---|
| <pre><code>ghostbox cn:init-image:from-image &lt;init-image:name&gt;&#10;    @&lt;image:id&gt;</code></pre> | [`InitImage.init(image:)`](https://apple.github.io/containerization/documentation/containerization/initimage/init(image:)) |
| <pre><code>ghostbox cn:init-image:create &lt;init-image:name&gt;&#10;    &lt;reference:string&gt;&#10;    --rootfs &lt;rootfs:host-url&gt;&#10;    --platform &lt;platform:oci-platform&gt;&#10;    [--label &lt;key-value:string&gt;]...&#10;    --image-store @&lt;image-store:id&gt;&#10;    --content-store @&lt;content-store:id&gt;</code></pre> | [`InitImage.create(reference:rootfs:platform:labels:imageStore:contentStore:)`](https://apple.github.io/containerization/documentation/containerization/initimage/create(reference:rootfs:platform:labels:imagestore:contentstore:)) |
| <pre><code>ghostbox cn:init-image:init-block @&lt;init-image:id&gt;&#10;    --at &lt;destination:host-url&gt;&#10;    --platform &lt;platform:system-platform&gt;</code></pre> | [`InitImage.initBlock(at:for:)`](https://apple.github.io/containerization/documentation/containerization/initimage/initblock(at:for:)) |
| <pre><code>ghostbox cn:init-image:name @&lt;init-image:id&gt;</code></pre> | [`InitImage.name`](https://apple.github.io/containerization/documentation/containerization/initimage/name) |

## Mount

| Ghostbox Signature | Apple API |
|---|---|
| <pre><code>ghostbox cn:mount:create &lt;mount:name&gt;&#10;    --type &lt;type:string&gt;&#10;    --source &lt;source:string&gt;&#10;    --destination &lt;destination:container-path&gt;&#10;    --option &lt;option:string&gt;...&#10;    --runtime-options &lt;runtime-options:mount-runtime-options&gt;</code></pre> | [`Mount.init(type:source:destination:options:runtimeOptions:)`](https://apple.github.io/containerization/documentation/containerization/mount/init(type:source:destination:options:runtimeoptions:)) |
| <pre><code>ghostbox cn:mount:block &lt;mount:name&gt;&#10;    --format &lt;format:string&gt;&#10;    --source &lt;source:string&gt;&#10;    --destination &lt;destination:container-path&gt;&#10;    [--option &lt;option:string&gt;]...&#10;    [--runtime-option &lt;option:string&gt;]...</code></pre> | [`Mount.block(format:source:destination:options:runtimeOptions:)`](https://apple.github.io/containerization/documentation/containerization/mount/block(format:source:destination:options:runtimeoptions:)) |
| <pre><code>ghostbox cn:mount:share &lt;mount:name&gt;&#10;    --source &lt;source:string&gt;&#10;    --destination &lt;destination:container-path&gt;&#10;    [--option &lt;option:string&gt;]...&#10;    [--runtime-option &lt;option:string&gt;]...</code></pre> | [`Mount.share(source:destination:options:runtimeOptions:)`](https://apple.github.io/containerization/documentation/containerization/mount/share(source:destination:options:runtimeoptions:)) |
| <pre><code>ghostbox cn:mount:any &lt;mount:name&gt;&#10;    --type &lt;type:string&gt;&#10;    --source &lt;source:string&gt;&#10;    --destination &lt;destination:container-path&gt;&#10;    [--option &lt;option:string&gt;]...&#10;    [--runtime-option &lt;option:string&gt;]...</code></pre> | [`Mount.any(type:source:destination:options:runtimeOptions:)`](https://apple.github.io/containerization/documentation/containerization/mount/any(type:source:destination:options:runtimeoptions:)) |
| <pre><code>ghostbox cn:mount:shared-mount &lt;mount:name&gt;&#10;    --name &lt;volume-name:string&gt;&#10;    --destination &lt;destination:container-path&gt;&#10;    [--option &lt;option:string&gt;]...</code></pre> | [`Mount.sharedMount(name:destination:options:)`](https://apple.github.io/containerization/documentation/containerization/mount/sharedmount(name:destination:options:)) |
| <pre><code>ghostbox cn:mount:clone @&lt;mount:id&gt;&#10;    --to &lt;destination:host-path&gt;</code></pre> | [`Mount.clone(to:)`](https://apple.github.io/containerization/documentation/containerization/mount/clone(to:)) |
| <pre><code>ghostbox cn:mount:is-block @&lt;mount:id&gt;</code></pre> | [`Mount.isBlock`](https://apple.github.io/containerization/documentation/containerization/mount/isblock) |
| <pre><code>ghostbox cn:mount:type @&lt;mount:id&gt;</code></pre> | [`Mount.type`](https://apple.github.io/containerization/documentation/containerization/mount/type) |
| <pre><code>ghostbox cn:mount:source @&lt;mount:id&gt;</code></pre> | [`Mount.source`](https://apple.github.io/containerization/documentation/containerization/mount/source) |
| <pre><code>ghostbox cn:mount:destination @&lt;mount:id&gt;</code></pre> | [`Mount.destination`](https://apple.github.io/containerization/documentation/containerization/mount/destination) |
| <pre><code>ghostbox cn:mount:options @&lt;mount:id&gt;</code></pre> | [`Mount.options`](https://apple.github.io/containerization/documentation/containerization/mount/options) |
| <pre><code>ghostbox cn:mount:runtime-options @&lt;mount:id&gt;</code></pre> | [`Mount.runtimeOptions`](https://apple.github.io/containerization/documentation/containerization/mount/runtimeoptions-swift.property) |

The `block`, `share`, and `any` commands pass repeated `--runtime-option`
values to Apple's `runtimeOptions` array parameter.

## Boot Log

| Ghostbox Signature | Apple API |
|---|---|
| <pre><code>ghostbox cn:boot-log:file &lt;boot-log:name&gt;&#10;    --path &lt;path:host-url&gt;&#10;    [--append=true]</code></pre> | [`BootLog.file(path:append:)`](https://apple.github.io/containerization/documentation/containerization/bootlog/file(path:append:)) |
