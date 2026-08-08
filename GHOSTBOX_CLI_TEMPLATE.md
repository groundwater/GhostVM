# Ghostbox Direct API CLI Template

This document defines the proposed direct Ghostbox CLI surface for Apple's
Containerization framework. It is source-audited against Containerization
`0.40.1` at revision `7800b46`.

This is not the backend-neutral protocol in `CONTAINER_RUNTIME_PROTOCOL.md`.
It is a diagnostic and development CLI whose operations stay as close as
possible to one public Containerization initializer, method, or property
access per command.

## Conventions

The `cn` namespace names Apple's Containerization package and has the long
alias `containerization`. Every command uses one qualified command token;
receiver references, when required, follow that token:

```text
$ ghostbox cn:RESOURCE:OPERATION [@<resource:id>] [arguments] [options]
```

```text
<argument:type>       New literal value.
@<argument:type>      Existing VMHost-owned object.
[argument]            Optional argument.
argument...            Repeatable argument.
-> @<argument:type>   Canonical object reference printed on success.
[--argument=default]  Optional argument using the shown framework default.
```

The outer macOS VMHost owns all live and value objects. Example references:

```text
@default                         ContainerManager
@default/web                     LinuxContainer
@default/web/shell               LinuxProcess
@shared                          VmnetNetwork
@shared/web                      Interface
```

Object creation prints its canonical `@` reference. Property operations print
JSON-compatible values. Methods returning framework objects register and print
new references.

`ContainerManager`, `VmnetNetwork`, `Kernel.CommandLine`, and
`LinuxProcessConfiguration` are mutable structs. The registry must serialize
mutation and write the modified value back after every mutating call. Passing
a `Network` to `ContainerManager.init` copies it; the manager's private network
and the original registered network are snapshots that can diverge.

Configuration closure exceptions are called out below. These operations still
make one lifecycle API call, but the host must supply the API-required closure
and assign a stored configuration value inside it.

## Image Stores

```text
ghostbox cn:image-store:create <image-store:name>
    --path <path:host-url>
    [--content-store @<content-store:id>]
    -> @<image-store:id>

ghostbox cn:image-store:default -> @<image-store:id>
ghostbox cn:image-store:path @<image-store:id> -> <path:host-url>

ghostbox cn:image-store:get @<image-store:id>
    <reference:string>
    [--pull=false]
    -> @<image:id>

ghostbox cn:image-store:list @<image-store:id> -> @<image:id>...

ghostbox cn:image-store:create-image @<image-store:id>
    @<image-description:id>
    -> @<image:id>

ghostbox cn:image-store:delete @<image-store:id>
    <reference:string>
    [--perform-cleanup=false]

ghostbox cn:image-store:clean-up-orphaned-blobs @<image-store:id>
    -> <result:deleted-digests-and-freed-bytes>

ghostbox cn:image-store:calculate-orphaned-blobs-size @<image-store:id>
    -> <bytes:uint64>

ghostbox cn:image-store:tag @<image-store:id>
    <existing-reference:string>
    <new-reference:string>
    -> @<image:id>

ghostbox cn:image-store:pull @<image-store:id>
    <reference:string>
    [--platform <platform:oci-platform>]
    [--insecure=false]
    [--authentication @<authentication:id>]
    [--progress @<progress-handler:id>]
    [--max-concurrent-downloads=3]
    -> @<image:id>

ghostbox cn:image-store:push @<image-store:id>
    <reference:string>
    [--platform <platform:oci-platform>]
    [--insecure=false]
    [--authentication @<authentication:id>]
    [--progress @<progress-handler:id>]

ghostbox cn:image-store:push-many @<image-store:id>
    <reference:string>...
    [--platform <platform:oci-platform>]
    [--insecure=false]
    [--authentication @<authentication:id>]
    [--max-concurrent-uploads=3]
    [--progress @<progress-handler:id>]

ghostbox cn:image-store:save @<image-store:id>
    <reference:string>...
    --out <directory:host-url>
    [--platform <platform:oci-platform>]

ghostbox cn:image-store:load @<image-store:id>
    <directory:host-url>
    [--progress @<progress-handler:id>]
    -> @<image:id>...

ghostbox cn:image-store:get-init-image @<image-store:id>
    <reference:string>
    [--authentication @<authentication:id>]
    [--progress @<progress-handler:id>]
    -> @<init-image:id>
```

`ContentStore`, `Authentication`, and `ProgressHandler` are protocol or closure
objects. They are VMHost-owned references, not inline CLI values. Omitting them
passes the framework default.

## Images

```text
ghostbox cn:image-description:create <image-description:name>
    <reference:string>
    <descriptor:oci-descriptor-json>
    -> @<image-description:id>

ghostbox cn:image-description:reference @<image-description:id> -> <reference:string>
ghostbox cn:image-description:descriptor @<image-description:id> -> <descriptor:oci-descriptor>
ghostbox cn:image-description:digest @<image-description:id> -> <digest:string>
ghostbox cn:image-description:media-type @<image-description:id> -> <media-type:string>

ghostbox cn:image:create <image:name>
    @<image-description:id>
    @<content-store:id>
    -> @<image:id>

ghostbox cn:image:description @<image:id> -> <description:image-description>
ghostbox cn:image:descriptor @<image:id> -> <descriptor:oci-descriptor>
ghostbox cn:image:digest @<image:id> -> <digest:string>
ghostbox cn:image:media-type @<image:id> -> <media-type:string>
ghostbox cn:image:reference @<image:id> -> <reference:string>
ghostbox cn:image:index @<image:id> -> <index:oci-index>

ghostbox cn:image:manifest @<image:id>
    <platform:oci-platform>
    -> <manifest:oci-manifest>

ghostbox cn:image:descriptor-for @<image:id>
    <platform:oci-platform>
    -> <descriptor:oci-descriptor>

ghostbox cn:image:config @<image:id>
    <platform:oci-platform>
    -> <image:oci-image>

ghostbox cn:image:referenced-digests @<image:id> -> <digest:string>...

ghostbox cn:image:get-content @<image:id>
    <digest:string>
    -> @<content:id>

ghostbox cn:content:path @<content:id> -> <path:host-url>
ghostbox cn:content:digest @<content:id> -> <digest:sha256-digest>
ghostbox cn:content:size @<content:id> -> <bytes:uint64>
ghostbox cn:content:data @<content:id> -> <data:byte-stream>
ghostbox cn:content:data-range @<content:id>
    <offset:uint64>
    <length:int>
    -> <data:byte-stream>|null
```

## Kernels And Boot Images

```text
ghostbox cn:kernel-command-line:create <command-line:name>
    [--kernel-argument <argument:string>]...
    [--init-argument <argument:string>]...
    -> @<kernel-command-line:id>

ghostbox cn:kernel-command-line:create-debug <command-line:name>
    <debug:bool>
    <panic:int>
    [--init-argument <argument:string>]...
    -> @<kernel-command-line:id>

ghostbox cn:kernel-command-line:add-debug @<kernel-command-line:id>
ghostbox cn:kernel-command-line:add-panic @<kernel-command-line:id> <level:int>
ghostbox cn:kernel-command-line:set-agent-log-level @<kernel-command-line:id> <level:logger-level>
ghostbox cn:kernel-command-line:kernel-arguments @<kernel-command-line:id> -> <argument:string>...
ghostbox cn:kernel-command-line:init-arguments @<kernel-command-line:id> -> <argument:string>...

ghostbox cn:kernel:create <kernel:name>
    --path <path:host-url>
    --platform <platform:system-platform>
    [--command-line @<kernel-command-line:id>]
    -> @<kernel:id>

ghostbox cn:kernel:path @<kernel:id> -> <path:host-url>
ghostbox cn:kernel:platform @<kernel:id> -> <platform:system-platform>
ghostbox cn:kernel:kernel-arguments @<kernel:id> -> <argument:string>...
ghostbox cn:kernel:init-arguments @<kernel:id> -> <argument:string>...

ghostbox cn:kernel-image:from-image <kernel-image:name>
    @<image:id>
    -> @<kernel-image:id>

ghostbox cn:kernel-image:create <kernel-image:name>
    <reference:string>
    --kernel @<kernel:id>...
    [--label <key-value:string>]...
    --image-store @<image-store:id>
    --content-store @<content-store:id>
    -> @<kernel-image:id>

ghostbox cn:kernel-image:kernel @<kernel-image:id>
    <platform:system-platform>
    -> @<kernel:id>

ghostbox cn:kernel-image:name @<kernel-image:id> -> <name:string>
ghostbox cn:kernel-image:media-type -> <media-type:string>

ghostbox cn:init-image:from-image <init-image:name>
    @<image:id>
    -> @<init-image:id>

ghostbox cn:init-image:create <init-image:name>
    <reference:string>
    --rootfs <rootfs:host-url>
    --platform <platform:oci-platform>
    [--label <key-value:string>]...
    --image-store @<image-store:id>
    --content-store @<content-store:id>
    -> @<init-image:id>

ghostbox cn:init-image:init-block @<init-image:id>
    --at <destination:host-url>
    --platform <platform:system-platform>
    -> @<mount:id>

ghostbox cn:init-image:name @<init-image:id> -> <name:string>
```

## Mounts

```text
ghostbox cn:mount:create <mount:name>
    --type <type:string>
    --source <source:string>
    --destination <destination:container-path>
    --option <option:string>...
    --runtime-options <runtime-options:mount-runtime-options>
    -> @<mount:id>

ghostbox cn:mount:block <mount:name>
    --format <format:string>
    --source <source:string>
    --destination <destination:container-path>
    [--option <option:string>]...
    [--runtime-option <option:string>]...
    -> @<mount:id>

ghostbox cn:mount:share <mount:name>
    --source <source:string>
    --destination <destination:container-path>
    [--option <option:string>]...
    [--runtime-option <option:string>]...
    -> @<mount:id>

ghostbox cn:mount:any <mount:name>
    --type <type:string>
    --source <source:string>
    --destination <destination:container-path>
    [--option <option:string>]...
    [--runtime-option <option:string>]...
    -> @<mount:id>

ghostbox cn:mount:shared-mount <mount:name>
    --name <volume-name:string>
    --destination <destination:container-path>
    [--option <option:string>]...
    -> @<mount:id>

ghostbox cn:mount:clone @<mount:id>
    --to <destination:host-path>
    -> @<mount:id>

ghostbox cn:mount:is-block @<mount:id> -> <is-block:bool>
ghostbox cn:mount:type @<mount:id> -> <type:string>
ghostbox cn:mount:source @<mount:id> -> <source:string>
ghostbox cn:mount:destination @<mount:id> -> <destination:string>
ghostbox cn:mount:options @<mount:id> -> <option:string>...
ghostbox cn:mount:runtime-options @<mount:id> -> <runtime-options:mount-runtime-options>
```

## DNS And Hosts

```text
ghostbox cn:dns:create <dns:name>
    [--nameserver <address:string>]...
    [--domain <domain:string>]
    [--search-domain <domain:string>]...
    [--option <option:string>]...
    -> @<dns:id>

ghostbox cn:dns:default-nameservers -> <address:string>...
ghostbox cn:dns:validate @<dns:id>
ghostbox cn:dns:resolv-conf @<dns:id> -> <contents:string>
ghostbox cn:dns:nameservers @<dns:id> -> <address:string>...
ghostbox cn:dns:domain @<dns:id> -> <domain:string>|null
ghostbox cn:dns:search-domains @<dns:id> -> <domain:string>...
ghostbox cn:dns:options @<dns:id> -> <option:string>...

ghostbox cn:hosts-entry:create <hosts-entry:name>
    <ip-address:string>
    <hostname:string>...
    [--comment <comment:string>]
    -> @<hosts-entry:id>

ghostbox cn:hosts-entry:localhost-ipv4 <hosts-entry:name> [--comment <comment:string>] -> @<hosts-entry:id>
ghostbox cn:hosts-entry:localhost-ipv6 <hosts-entry:name> [--comment <comment:string>] -> @<hosts-entry:id>
ghostbox cn:hosts-entry:ipv6-localnet <hosts-entry:name> [--comment <comment:string>] -> @<hosts-entry:id>
ghostbox cn:hosts-entry:ipv6-mcastprefix <hosts-entry:name> [--comment <comment:string>] -> @<hosts-entry:id>
ghostbox cn:hosts-entry:ipv6-allnodes <hosts-entry:name> [--comment <comment:string>] -> @<hosts-entry:id>
ghostbox cn:hosts-entry:ipv6-allrouters <hosts-entry:name> [--comment <comment:string>] -> @<hosts-entry:id>
ghostbox cn:hosts-entry:rendered @<hosts-entry:id> -> <entry:string>
ghostbox cn:hosts-entry:ip-address @<hosts-entry:id> -> <address:string>
ghostbox cn:hosts-entry:hostnames @<hosts-entry:id> -> <hostname:string>...
ghostbox cn:hosts-entry:comment @<hosts-entry:id> -> <comment:string>|null

ghostbox cn:hosts:create <hosts:name>
    [--entry @<hosts-entry:id>]...
    [--comment <comment:string>]
    -> @<hosts:id>

ghostbox cn:hosts:default -> @<hosts:id>
ghostbox cn:hosts:hosts-file @<hosts:id> -> <contents:string>
ghostbox cn:hosts:entries @<hosts:id> -> @<hosts-entry:id>...
ghostbox cn:hosts:comment @<hosts:id> -> <comment:string>|null
```

## Socket And Boot Log Configuration

```text
ghostbox cn:socket:create <socket:name>
    --source <source:host-url>
    --destination <destination:host-url>
    [--permissions <permissions:file-permissions>]
    [--direction <direction:into|out-of>]
    -> @<socket:id>

ghostbox cn:socket:id @<socket:id> -> <id:string>
ghostbox cn:socket:source @<socket:id> -> <source:host-url>
ghostbox cn:socket:destination @<socket:id> -> <destination:host-url>
ghostbox cn:socket:permissions @<socket:id> -> <permissions:file-permissions>|null
ghostbox cn:socket:direction @<socket:id> -> <direction:into|out-of>

ghostbox cn:boot-log:file <boot-log:name>
    --path <path:host-url>
    [--append=true]
    -> @<boot-log:id>
```

`BootLog.fileHandle(_:)` is excluded because it requires a live host
`FileHandle`; `BootLog.file(path:append:)` is the CLI-safe public factory.

## Networks And Interfaces

`VmnetNetwork` is available on macOS 26 and later.

```text
ghostbox cn:network:vmnet-create <network:name>
    [--mode=shared]
    [--subnet <subnet:cidrv4>]
    [--prefix-v6 <prefix:cidrv6>]
    -> @<network:id>

ghostbox cn:network:subnet @<network:id> -> <subnet:cidrv4>
ghostbox cn:network:prefix-v6 @<network:id> -> <prefix:cidrv6>|null
ghostbox cn:network:ipv4-gateway @<network:id> -> <gateway:ipv4-address>
ghostbox cn:network:ipv6-gateway @<network:id> -> <gateway:ipv6-address>|null

ghostbox cn:network:create-interface @<network:id>
    <interface:name>
    -> @<interface:id>|null

ghostbox cn:network:create-interface-mtu @<network:id>
    <interface:name>
    <mtu:uint32>
    -> @<interface:id>|null

ghostbox cn:network:create-interface-without-gateway @<network:id>
    <interface:name>
    -> @<interface:id>|null

ghostbox cn:network:release-interface @<network:id> @<interface:id>

# Maps to the platform-independent Containerization.NATInterface value type.
ghostbox cn:interface:nat-create <interface:name>
    --ipv4-address <address:cidrv4>
    [--ipv4-gateway <gateway:ipv4-address>]
    [--ipv6-address <address:cidrv6>]
    [--ipv6-gateway <gateway:ipv6-address>]
    [--mac-address <address:mac-address>]
    [--mtu=1500]
    -> @<interface:id>

ghostbox cn:interface:ipv4-address @<interface:id> -> <address:cidrv4>
ghostbox cn:interface:ipv4-gateway @<interface:id> -> <address:ipv4-address>|null
ghostbox cn:interface:ipv6-address @<interface:id> -> <address:cidrv6>|null
ghostbox cn:interface:ipv6-gateway @<interface:id> -> <address:ipv6-address>|null
ghostbox cn:interface:mac-address @<interface:id> -> <address:mac-address>|null
ghostbox cn:interface:mtu @<interface:id> -> <mtu:uint32>
```

`NATNetworkInterface.init(...reference:)` and `VmnetNetwork.Interface.init`
are excluded because they require a live `vmnet_network_ref` C object.

## VM Configuration And VMM

```text
ghostbox cn:vm-config:create <vm-config:name>
    [--cpus=4]
    [--memory=1073741824]
    [--interface @<interface:id>]...
    [--mount <workload-id:string>=@<mount:id>]...
    [--boot-log @<boot-log:id>]
    [--nested-virtualization=false]
    -> @<vm-config:id>

ghostbox cn:standard-vm-config:create <standard-vm-config:name>
    @<vm-config:id>
    -> @<standard-vm-config:id>

ghostbox cn:vmm:create <vmm:name>
    --kernel @<kernel:id>
    --initial-filesystem @<mount:id>
    [--rosetta=false]
    [--nested-virtualization=false]
    -> @<vmm:id>

ghostbox cn:vmm:create-instance @<vmm:id>
    @<standard-vm-config:id>
    -> @<vm-instance:id>

ghostbox cn:vm-instance:state @<vm-instance:id> -> <state:vm-state>
ghostbox cn:vm-instance:mounts @<vm-instance:id> -> <mounts:attached-filesystem-map>
ghostbox cn:vm-instance:virtiofs-layout @<vm-instance:id> -> <layout:virtiofs-layout>
ghostbox cn:vm-instance:start @<vm-instance:id>
ghostbox cn:vm-instance:stop @<vm-instance:id>
ghostbox cn:vm-instance:pause @<vm-instance:id>
ghostbox cn:vm-instance:resume @<vm-instance:id>

ghostbox cn:vm-instance:dial @<vm-instance:id>
    <port:uint32>
    -> @<file-handle:id>
```

The VMM constructor fixes `EventLoopGroup` and `Logger` to `nil`. Custom
`VMConfiguration.extensions`, `dialAgent`, listeners, and hotplug operations
remain excluded until Ghostbox defines registry-backed wrappers for their live
protocol objects.

## Process Configuration

```text
ghostbox cn:rlimit-kind:create <rlimit-kind:name>
    <oci-name:string>
    -> @<rlimit-kind:id>

ghostbox cn:rlimit:create <rlimit:name>
    --kind @<rlimit-kind:id>
    --hard <hard:uint64>
    --soft <soft:uint64>
    -> @<rlimit:id>

ghostbox cn:rlimit:create-equal <rlimit:name>
    --kind @<rlimit-kind:id>
    --limit <limit:uint64>
    -> @<rlimit:id>

ghostbox cn:rlimit:kind @<rlimit:id> -> @<rlimit-kind:id>
ghostbox cn:rlimit:hard @<rlimit:id> -> <hard:uint64>
ghostbox cn:rlimit:soft @<rlimit:id> -> <soft:uint64>
ghostbox cn:rlimit:to-oci @<rlimit:id> -> <rlimit:oci-posix-rlimit>

ghostbox cn:capabilities:create <capabilities:name>
    [--bounding <capability:linux-capability>]...
    [--effective <capability:linux-capability>]...
    [--inheritable <capability:linux-capability>]...
    [--permitted <capability:linux-capability>]...
    [--ambient <capability:linux-capability>]...
    -> @<capabilities:id>

ghostbox cn:capabilities:create-uniform <capabilities:name>
    <capability:linux-capability>...
    -> @<capabilities:id>

ghostbox cn:capabilities:all -> @<capabilities:id>
ghostbox cn:capabilities:default-oci -> @<capabilities:id>
ghostbox cn:capabilities:bounding @<capabilities:id> -> <capability:linux-capability>...
ghostbox cn:capabilities:effective @<capabilities:id> -> <capability:linux-capability>...
ghostbox cn:capabilities:inheritable @<capabilities:id> -> <capability:linux-capability>...
ghostbox cn:capabilities:permitted @<capabilities:id> -> <capability:linux-capability>...
ghostbox cn:capabilities:ambient @<capabilities:id> -> <capability:linux-capability>...
ghostbox cn:capabilities:to-oci @<capabilities:id> -> <capabilities:oci-linux-capabilities>

ghostbox cn:process-config:default-path -> <path:string>

ghostbox cn:process-config:create <process-config:name>
    <argument:string>...
    [--environment <assignment:string>]...
    [--working-directory=/]
    [--user <user:oci-user>]
    [--rlimit @<rlimit:id>]...
    [--no-new-privileges=false]
    [--capabilities @<capabilities:id>]
    [--terminal=false]
    [--stdin @<reader-stream:id>]
    [--stdout @<writer:id>]
    [--stderr @<writer:id>]
    -> @<process-config:id>

ghostbox cn:process-config:from-image-config <process-config:name>
    <image-config:oci-image-config>
    -> @<process-config:id>

ghostbox cn:process-config:set-terminal-io @<process-config:id>
    @<terminal:id>

ghostbox cn:process-config:arguments @<process-config:id> -> <argument:string>...
ghostbox cn:process-config:environment-variables @<process-config:id> -> <assignment:string>...
ghostbox cn:process-config:working-directory @<process-config:id> -> <directory:string>
ghostbox cn:process-config:user @<process-config:id> -> <user:oci-user>
ghostbox cn:process-config:rlimits @<process-config:id> -> @<rlimit:id>...
ghostbox cn:process-config:no-new-privileges @<process-config:id> -> <enabled:bool>
ghostbox cn:process-config:capabilities @<process-config:id> -> @<capabilities:id>
ghostbox cn:process-config:terminal @<process-config:id> -> <enabled:bool>
ghostbox cn:process-config:stdin @<process-config:id> -> @<reader-stream:id>|null
ghostbox cn:process-config:stdout @<process-config:id> -> @<writer:id>|null
ghostbox cn:process-config:stderr @<process-config:id> -> @<writer:id>|null
```

Stdio and terminal arguments are VMHost-owned protocol objects. Ghostbox proxy
extensions register guest-backed adapters without combining lifecycle calls.

## Container Configuration

```text
ghostbox cn:container-config:create-default <container-config:name>
    -> @<container-config:id>

ghostbox cn:container-config:create <container-config:name>
    --process @<process-config:id>
    [--cpus=4]
    [--memory=1073741824]
    [--hostname <hostname:string>]
    [--sysctl <key-value:string>]...
    [--interface @<interface:id>]...
    [--socket @<socket:id>]...
    [--mount @<mount:id>]...
    [--masked-path <path:container-path>]...
    [--readonly-path <path:container-path>]...
    [--dns @<dns:id>]
    [--hosts @<hosts:id>]
    [--virtualization=false]
    [--boot-log @<boot-log:id>]
    [--oci-runtime-path <path:container-path>]
    [--use-init=false]
    [--cpu-overhead=1]
    [--memory-overhead=134217728]
    -> @<container-config:id>

ghostbox cn:container:default-mounts -> @<mount:id>...
ghostbox cn:container:default-oci-mounts -> <mount:oci-mount>...
ghostbox cn:container:default-masked-paths -> <path:container-path>...
ghostbox cn:container:default-readonly-paths -> <path:container-path>...
ghostbox cn:container:default-copy-chunk-size -> <bytes:int>
ghostbox cn:container:max-id-length -> <length:int>
```

## Container Managers

Distinct constructor verbs avoid ambiguity between Swift overloads whose
optional arguments otherwise produce identical CLI shapes.

```text
ghostbox cn:manager:create <manager:name>
    --kernel @<kernel:id>
    --initfs @<mount:id>
    --image-store @<image-store:id>
    [--network @<network:id>]
    [--rosetta=false]
    [--nested-virtualization=false]
    -> @<manager:id>

ghostbox cn:manager:create-at-root <manager:name>
    --kernel @<kernel:id>
    --initfs @<mount:id>
    [--root <root:host-url>]
    [--network @<network:id>]
    [--rosetta=false]
    [--nested-virtualization=false]
    -> @<manager:id>

ghostbox cn:manager:create-from-reference <manager:name>
    --kernel @<kernel:id>
    --initfs-reference <reference:string>
    --image-store @<image-store:id>
    [--network @<network:id>]
    [--rosetta=false]
    [--nested-virtualization=false]
    -> @<manager:id>

ghostbox cn:manager:create-from-reference-at-root <manager:name>
    --kernel @<kernel:id>
    --initfs-reference <reference:string>
    [--root <root:host-url>]
    [--network @<network:id>]
    [--rosetta=false]
    [--nested-virtualization=false]
    -> @<manager:id>

ghostbox cn:manager:create-with-vmm <manager:name>
    --vmm @<vmm:id>
    [--network @<network:id>]
    -> @<manager:id>

ghostbox cn:manager:image-store @<manager:id> -> @<image-store:id>
```

## Manager Container Allocation

These three framework methods require a non-optional configuration closure.
Ghostbox builds the closure from optional configuration overrides and applies
them to the manager-populated `inout LinuxContainer.Configuration`. It must not
replace the value wholesale: the manager has already populated image process
settings, networking, DNS, and its boot log. No extra lifecycle API is called.

```text
--process @<process-config:id>
--cpus <cpus:int>
--memory <bytes:uint64>
--hostname <hostname:string>
--sysctl <key-value:string>...
--interfaces @<interface:id>...
--sockets @<socket:id>...
--mounts @<mount:id>...
--masked-paths <path:container-path>...
--readonly-paths <path:container-path>...
--dns @<dns:id>
--hosts @<hosts:id>
--virtualization <enabled:bool>
--boot-log @<boot-log:id>
--oci-runtime-path <path:container-path>
--use-init <enabled:bool>
--cpu-overhead <cpus:int>
--memory-overhead <bytes:uint64>
```

```text
ghostbox cn:manager:create-container @<manager:id>
    <container:name>
    --reference <reference:string>
    [--rootfs-size=8589934592]
    [--writable-layer-size <bytes:uint64>]
    [--read-only=false]
    [--networking=true]
    [--progress @<progress-handler:id>]
    [<override:container-config-override>]...
    -> @<container:id>

ghostbox cn:manager:create-container-from-image @<manager:id>
    <container:name>
    --image @<image:id>
    [--rootfs-size=8589934592]
    [--writable-layer-size <bytes:uint64>]
    [--read-only=false]
    [--networking=true]
    [--progress @<progress-handler:id>]
    [<override:container-config-override>]...
    -> @<container:id>

ghostbox cn:manager:create-container-from-mounts @<manager:id>
    <container:name>
    --image @<image:id>
    --rootfs @<mount:id>
    [--writable-layer @<mount:id>]
    [--networking=true]
    [<override:container-config-override>]...
    -> @<container:id>

ghostbox cn:manager:release-network @<manager:id> @<container:id>
ghostbox cn:manager:delete @<manager:id> @<container:id>
```

## Containers

```text
ghostbox cn:container:create-direct <container:name>
    --rootfs @<mount:id>
    [--writable-layer @<mount:id>]
    --vmm @<vmm:id>
    --configuration @<container-config:id>
    -> @<container:id>

ghostbox cn:container:id @<container:id> -> <id:string>
ghostbox cn:container:rootfs @<container:id> -> @<mount:id>
ghostbox cn:container:writable-layer @<container:id> -> @<mount:id>|null
ghostbox cn:container:config @<container:id> -> @<container-config:id>
ghostbox cn:container:cpus @<container:id> -> <cpus:int>
ghostbox cn:container:memory @<container:id> -> <bytes:uint64>
ghostbox cn:container:interfaces @<container:id> -> @<interface:id>...

ghostbox cn:container:create @<container:id>
ghostbox cn:container:start @<container:id>
ghostbox cn:container:stop @<container:id>
ghostbox cn:container:kill @<container:id> <signal:linux-signal>

ghostbox cn:container:wait @<container:id>
    [--timeout-seconds <seconds:int64>]
    -> <status:exit-status>

ghostbox cn:container:resize @<container:id>
    <width:uint16>
    <height:uint16>

ghostbox cn:container:exec @<container:id>
    <process:name>
    --configuration @<process-config:id>
    -> @<process:id>

ghostbox cn:container:dial-vsock @<container:id>
    <port:uint32>
    -> @<file-handle:id>

ghostbox cn:container:close-stdin @<container:id>

ghostbox cn:container:statistics @<container:id>
    [--category <category:statistics-category>]...
    -> <statistics:container-statistics>

ghostbox cn:container:filesystem-operation @<container:id>
    <operation:freeze|thaw|trim>
    <path:container-path>

ghostbox cn:container:copy-in @<container:id>
    <source:host-url>
    <destination:container-url>
    [--mode=0644]
    [--create-parents=true]
    [--chunk-size=1048576]

ghostbox cn:container:copy-out @<container:id>
    <source:container-url>
    <destination:host-url>
    [--create-parents=true]
    [--chunk-size=1048576]
```

There is no public `LinuxContainer.pause()`, `resume()`, `delete()`, `state`, or
container-level Unix-socket relay operation. VM pause and resume exist only on
`VirtualMachineInstance`, which Containerization exposes to containers through
the scoped `withVirtualMachineInstance` closure. That closure is deliberately
not converted into a durable CLI reference.

## Processes

`LinuxProcess` has no public initializer. A process reference is created only
by `LinuxContainer.exec` or `LinuxPod.execInContainer`.

```text
ghostbox cn:process:id @<process:id> -> <id:string>
ghostbox cn:process:owning-container @<process:id> -> <container-id:string>|null
ghostbox cn:process:pid @<process:id> -> <pid:int32>

ghostbox cn:process:start @<process:id>
ghostbox cn:process:kill @<process:id> <signal:linux-signal>

ghostbox cn:process:resize @<process:id>
    <width:uint16>
    <height:uint16>

ghostbox cn:process:close-stdin @<process:id>

ghostbox cn:process:wait @<process:id>
    [--timeout-seconds <seconds:int64>]
    -> <status:exit-status>

ghostbox cn:process:delete @<process:id>
```

## Experimental Pods

Pod construction, container addition, and process execution only have closure configuration forms. Ghostbox assigns the stored value inside that closure.
For `exec-in-container`, this intentionally replaces Apple's inherited configuration and returns an unstarted process that is not registered in pod state.
`pod config` returns the pod's immutable configuration as a read-only detached
snapshot. Use a separately created `pod-config` reference as a mutable builder.

```text
ghostbox cn:pod-volume:create <pod-volume:name>
    --name <volume-name:string>
    --source <source:pod-volume-source>
    --format <format:string>
    -> @<pod-volume:id>

ghostbox cn:pod-config:create <pod-config:name> -> @<pod-config:id>
ghostbox cn:pod-config:set-cpus @<pod-config:id> <cpus:int>
ghostbox cn:pod-config:set-memory @<pod-config:id> <bytes:uint64>
ghostbox cn:pod-config:set-interfaces @<pod-config:id> @<interface:id>...
ghostbox cn:pod-config:set-virtualization @<pod-config:id> <enabled:bool>
ghostbox cn:pod-config:set-boot-log @<pod-config:id> @<boot-log:id>|null
ghostbox cn:pod-config:set-share-process-namespace @<pod-config:id> <enabled:bool>
ghostbox cn:pod-config:set-hostname @<pod-config:id> <hostname:string>|null
ghostbox cn:pod-config:set-dns @<pod-config:id> @<dns:id>|null
ghostbox cn:pod-config:set-hosts @<pod-config:id> @<hosts:id>|null
ghostbox cn:pod-config:set-volumes @<pod-config:id> @<pod-volume:id>...

ghostbox cn:pod-container-config:create <pod-container-config:name> -> @<pod-container-config:id>
ghostbox cn:pod-container-config:set-process @<pod-container-config:id> @<process-config:id>
ghostbox cn:pod-container-config:set-cpus @<pod-container-config:id> <cpus:int>|null
ghostbox cn:pod-container-config:set-memory @<pod-container-config:id> <bytes:uint64>|null
ghostbox cn:pod-container-config:set-hostname @<pod-container-config:id> <hostname:string>|null
ghostbox cn:pod-container-config:set-sysctl @<pod-container-config:id> <key-value:string>...
ghostbox cn:pod-container-config:set-mounts @<pod-container-config:id> @<mount:id>...
ghostbox cn:pod-container-config:set-masked-paths @<pod-container-config:id> <path:container-path>...
ghostbox cn:pod-container-config:set-readonly-paths @<pod-container-config:id> <path:container-path>...
ghostbox cn:pod-container-config:set-sockets @<pod-container-config:id> @<socket:id>...
ghostbox cn:pod-container-config:set-dns @<pod-container-config:id> @<dns:id>|null
ghostbox cn:pod-container-config:set-hosts @<pod-container-config:id> @<hosts:id>|null
ghostbox cn:pod-container-config:set-use-init @<pod-container-config:id> <enabled:bool>

ghostbox cn:pod:create-direct <pod:name>
    --vmm @<vmm:id>
    --configuration @<pod-config:id>
    -> @<pod:id>

ghostbox cn:pod:id @<pod:id> -> <id:string>
ghostbox cn:pod:config @<pod:id> -> @<pod-config:id>
ghostbox cn:pod:cpus @<pod:id> -> <cpus:int>
ghostbox cn:pod:memory @<pod:id> -> <bytes:uint64>
ghostbox cn:pod:interfaces @<pod:id> -> @<interface:id>...

ghostbox cn:pod:add-container @<pod:id>
    <container:name>
    --rootfs @<mount:id>
    --configuration @<pod-container-config:id>
    -> @<pod-container:id>

ghostbox cn:pod:create @<pod:id>
ghostbox cn:pod:start-container @<pod:id> @<pod-container:id>
ghostbox cn:pod:stop-container @<pod:id> @<pod-container:id>
ghostbox cn:pod:stop @<pod:id>
ghostbox cn:pod:kill-container @<pod:id> @<pod-container:id> <signal:linux-signal>

ghostbox cn:pod:wait-container @<pod:id>
    @<pod-container:id>
    [--timeout-seconds <seconds:int64>]
    -> <status:exit-status>

ghostbox cn:pod:resize-container @<pod:id>
    @<pod-container:id>
    <width:uint16>
    <height:uint16>

ghostbox cn:pod:exec-in-container @<pod:id>
    @<pod-container:id>
    <process:name>
    --configuration @<process-config:id>
    -> @<process:id>

ghostbox cn:pod:list-containers @<pod:id> -> @<pod-container:id>...

ghostbox cn:pod:statistics @<pod:id>
    [--container @<pod-container:id>]...
    [--category <category:statistics-category>]...
    -> <statistics:container-statistics>...

ghostbox cn:pod:dial-vsock @<pod:id>
    <port:uint32>
    -> @<file-handle:id>

ghostbox cn:pod:filesystem-operation @<pod:id>
    @<pod-container:id>
    <operation:freeze|thaw|trim>
    <path:container-path>

ghostbox cn:pod:close-container-stdin @<pod:id> @<pod-container:id>

ghostbox cn:pod:relay-unix-socket @<pod:id>
    @<pod-container:id>
    @<socket:id>
```

## Content Stores, Authentication, and Progress

```text
ghostbox cn:content-store:create <content-store:name>
    --path <path:host-url>
    -> @<content-store:id>

ghostbox cn:authentication:create-basic <authentication:name>
    --username <username:string>
    --password <password:string>
    -> @<authentication:id>

ghostbox cn:progress-handler:create <progress-handler:name>
    --writer @<writer:id>
    -> @<progress-handler:id>
```

`progress-handler create` adapts Apple's callback to newline-delimited JSON
objects written through the supplied registered `Writer`. Each object contains
the framework event's `event` and integer `value` properties.

## Container Resource Visibility

Each `LinuxContainer` runs in its own VM. `cpus` and `memory` are workload
cgroup limits, while `/proc/cpuinfo` and `/proc/meminfo` expose VM capacity.
For manager create operations, supplying `cpus` selects zero additional vCPUs
unless `cpuOverhead` is explicit. Supplying `memory` selects the bundled guest
kernel reservation as `memoryOverhead` unless that option is explicit, so
`MemTotal` tracks the requested workload memory. Explicit overhead options retain
Apple's `capacity = limit + overhead` behavior. Cgroup v2 `cpu.max` and
`memory.max`, or `container statistics`, remain authoritative for enforcement.

## Explicit Exclusions

```text
LinuxContainer.withVirtualMachineInstance(...)
LinuxPod.withVirtualMachineInstance(...)
BootLog.fileHandle(...)
VmnetNetwork.Interface.init(...)
NATNetworkInterface.init(...reference: vmnet_network_ref...)
Mount.configure(...)
Mount.readonly
ImageStore import/export implementation types
LinuxProcess internal initializer
ProgressHandler inline closures other than the registered writer adapter
Arbitrary Authentication protocol implementations
VMCreationConfig custom protocol implementations
VMConfiguration.extensions
VirtualMachineInstance listeners, agents, and hotplug objects
VZVirtualMachineInstance direct initializer and Configuration closure
Content.decode<T>() generic decoding
Cloud Hypervisor and Linux-only network backends
```

These APIs are closure-scoped, internal, require non-serializable host objects,
or are outside the VZ-backed macOS container scope. They must not be presented
as direct CLI operations without a separate registry-backed transport design.
