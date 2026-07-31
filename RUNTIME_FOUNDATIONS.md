# GhostVM Runtime Foundations

GhostVM's VM and container features share control-plane concepts, but they do
not share packet processors or guest compatibility APIs.

```text
Docker CLI / Compose
         |
         v
GhostTools frontend and internal CLI
         |
         v
container runtime protocol over vsock
         |
         v
GhostVMHelper
    |
    +-- ghostvm-image-fetch (short-lived)
    |       +-- kernel and ImageStore preparation
    |
    +-- GhostVMContainerRuntime.xpc (one per GhostVMHelper)
            +-- all Containerization container VMs
```

GhostVM does not start `container-apiserver`, `container-core-images`, or a
global container daemon. A short-lived `ghostvm-image-fetch` subprocess prepares
the kernel, requested image, and vminit image in a per-VM application-support
root. After it exits, the helper's application-scoped
`GhostVMContainerRuntime.xpc` opens that store without pulling and calls
`ContainerManager` and `LinuxContainer` directly. One runtime process hosts all
container VMs for its containing helper. Lifecycle control uses raw XPC while
standard streams use file descriptors transferred in the XPC run request.

## Network management

`NetworkManager` owns backend-neutral network definitions and workload
endpoints. Both VM NICs and container interfaces attach through this control
plane.

The initial backend drivers are deliberately distinct:

- `virtualization-nat` uses `VZNATNetworkDeviceAttachment` when host containers
  are disabled.
- `bridged` uses a selected host interface.
- `vmnet-shared` is active for container-enabled NAT VMs. `GhostVMHelper`
  reserves one `VMNET_SHARED_MODE` network per macOS VM, reserves `.2` for the
  VM through DHCP, and allocates `.3+` statically to that VM's containers. The
  helper sends the opaque vmnet serialization and allocated interface settings
  directly to its runtime XPC service with every run. The runtime reconstructs
  the exact network before creating the container VM attachment. Reconstruction
  failure fails the run; it never silently creates an unrelated NAT network.

The multi-NIC configuration concepts from PR #144 can be adapted to these
types. Its custom ARP, DHCP, DNS, NAT, and TCP implementation is not part of the
runtime foundation.

## Content store

`ContentAddressedStore` owns immutable blobs under OCI-style digest paths:

```text
content/
  blobs/
    sha256/<digest>
  ingest/<temporary-id>
  refs/
  snapshots/
```

Writers copy or download into `ingest`, verify the SHA-256 digest, and publish
with a same-volume rename. Existing blobs are reused. Blob deletion, reference
counting, and leases are intentionally deferred.

## Runtime protocol

The guest-to-host API uses stable resource methods such as `image.pull`,
`container.create`, and `process.start`. Docker's HTTP API remains a guest-side
frontend and is never forwarded directly to the host.

Every request includes a major/minor version, request ID, method, and
method-specific parameters. Frontends query `system.capabilities` before using
optional methods. The current one-shot `run` request remains as the migration
path while primitive handlers are added.

## GhostTools CLI

`ghost-container` is the internal diagnostic frontend. It is already built as
a GhostTools package product, copied into `GhostTools.app/Contents/MacOS`, and
placed at the GhostTools DMG root for direct testing.

The next guest layer is a Docker Engine API adapter that shares the same runtime
client and translates Docker operations into one or more runtime protocol
methods.
