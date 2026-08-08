# Ghostbox Virtual Machines API

This page maps the 12 Ghostbox virtual machine methods to their corresponding
Apple Containerization APIs.

- Ghostbox signatures are sourced from `GHOSTBOX_CLI_COMMANDS.json`.
- Apple API links are pinned to Containerization `0.40.1`, revision
  `7800b4642171561c95b5f55500b19e5dce5acd45`.

| Resource | Methods |
|---|---:|
| `vm-config` | 1 |
| `standard-vm-config` | 1 |
| `vmm` | 2 |
| `vm-instance` | 8 |
| **Total** | **12** |

## VM Config

| Ghostbox Signature | Apple API |
|---|---|
| <pre><code>ghostbox cn:vm-config:create &lt;vm-config:name&gt;&#10;    [--cpus=4]&#10;    [--memory=1073741824]&#10;    [--interface @&lt;interface:id&gt;]...&#10;    [--mount &lt;workload-id:string&gt;=@&lt;mount:id&gt;]...&#10;    [--boot-log @&lt;boot-log:id&gt;]&#10;    [--nested-virtualization=false]</code></pre> | [`VMConfiguration.init(cpus:memoryInBytes:interfaces:mountsByID:bootLog:nestedVirtualization:)`](https://apple.github.io/containerization/documentation/containerization/vmconfiguration/init(cpus:memoryinbytes:interfaces:mountsbyid:bootlog:nestedvirtualization:)) |

## Standard VM Config

| Ghostbox Signature | Apple API |
|---|---|
| <pre><code>ghostbox cn:standard-vm-config:create &lt;standard-vm-config:name&gt;&#10;    @&lt;vm-config:id&gt;</code></pre> | [`StandardVMConfig.init(configuration:)`](https://apple.github.io/containerization/documentation/containerization/standardvmconfig/init(configuration:)) |

## VMM

| Ghostbox Signature | Apple API |
|---|---|
| <pre><code>ghostbox cn:vmm:create &lt;vmm:name&gt;&#10;    --kernel @&lt;kernel:id&gt;&#10;    --initial-filesystem @&lt;mount:id&gt;&#10;    [--rosetta=false]&#10;    [--nested-virtualization=false]</code></pre> | [`VZVirtualMachineManager.init(kernel:initialFilesystem:rosetta:nestedVirtualization:group:logger:)`](https://apple.github.io/containerization/documentation/containerization/vzvirtualmachinemanager/init(kernel:initialfilesystem:rosetta:nestedvirtualization:group:logger:)) |
| <pre><code>ghostbox cn:vmm:create-instance @&lt;vmm:id&gt;&#10;    @&lt;standard-vm-config:id&gt;</code></pre> | [`VZVirtualMachineManager.create(config:)`](https://apple.github.io/containerization/documentation/containerization/vzvirtualmachinemanager/create(config:)) |

## VM Instance

| Ghostbox Signature | Apple API |
|---|---|
| <pre><code>ghostbox cn:vm-instance:state @&lt;vm-instance:id&gt;</code></pre> | [`VirtualMachineInstance.state`](https://apple.github.io/containerization/documentation/containerization/virtualmachineinstance/state) |
| <pre><code>ghostbox cn:vm-instance:mounts @&lt;vm-instance:id&gt;</code></pre> | [`VirtualMachineInstance.mounts`](https://apple.github.io/containerization/documentation/containerization/virtualmachineinstance/mounts) |
| <pre><code>ghostbox cn:vm-instance:virtiofs-layout @&lt;vm-instance:id&gt;</code></pre> | [`VirtualMachineInstance.virtiofsLayout`](https://apple.github.io/containerization/documentation/containerization/virtualmachineinstance/virtiofslayout) |
| <pre><code>ghostbox cn:vm-instance:start @&lt;vm-instance:id&gt;</code></pre> | [`VirtualMachineInstance.start()`](https://apple.github.io/containerization/documentation/containerization/virtualmachineinstance/start()) |
| <pre><code>ghostbox cn:vm-instance:stop @&lt;vm-instance:id&gt;</code></pre> | [`VirtualMachineInstance.stop()`](https://apple.github.io/containerization/documentation/containerization/virtualmachineinstance/stop()) |
| <pre><code>ghostbox cn:vm-instance:pause @&lt;vm-instance:id&gt;</code></pre> | [`VirtualMachineInstance.pause()`](https://apple.github.io/containerization/documentation/containerization/virtualmachineinstance/pause()) |
| <pre><code>ghostbox cn:vm-instance:resume @&lt;vm-instance:id&gt;</code></pre> | [`VirtualMachineInstance.resume()`](https://apple.github.io/containerization/documentation/containerization/virtualmachineinstance/resume()) |
| <pre><code>ghostbox cn:vm-instance:dial @&lt;vm-instance:id&gt;&#10;    &lt;port:uint32&gt;</code></pre> | [`VirtualMachineInstance.dial(_:)`](https://apple.github.io/containerization/documentation/containerization/virtualmachineinstance/dial(_:)) |
