# GhostVM Container Runtime Protocol

The GhostVM container boundary is a backend-neutral runtime API. Docker is a
frontend implemented inside GhostTools; it is not the protocol spoken to the
outer host.

```text
docker CLI / compose / another client
                |
                v
     guest frontend adapter
                |
                v
   GhostVM runtime protocol over vsock
                |
                v
        host runtime backend
                |
                v
 Apple Containerization or another engine
```

## Design rules

1. Methods model runtime resources and lifecycle operations, not Docker HTTP
   routes or Swift implementation types.
2. The guest owns frontend compatibility. For example, the Docker adapter maps
   Docker Engine API requests to one or more runtime methods.
3. The host owns container objects and their lifetimes. A frontend refers to
   images, filesystems, containers, and processes by stable IDs.
4. Every request carries a protocol major/minor version and request ID. A major
   mismatch is incompatible; minor versions are additive.
5. Frontends call `system.capabilities` and must not infer behavior from the
   host implementation or operating-system version.
6. Errors use stable machine-readable codes. Backend error strings are only
   diagnostics and never control frontend behavior.
7. Large and interactive data uses bounded binary stream frames associated
   with a request. JSON metadata must never contain whole build contexts,
   filesystem archives, or unbounded process output.
8. Guest-backed `ReaderStream`, `Writer`, and `Terminal` resources carry process
   I/O independently from container and process lifecycle calls.

## Runtime surface

| Resource | Methods |
|---|---|
| System | `system.capabilities` |
| Image | `image.pull`, `image.list`, `image.inspect`, `image.delete`, `image.unpack` |
| Filesystem | `filesystem.create`, `filesystem.delete` |
| Container | `container.create`, `container.start`, `container.stop`, `container.kill`, `container.wait`, `container.resize`, `container.state`, `container.list`, `container.delete` |
| Container I/O | `container.copyIn`, `container.copyOut`, `container.dial` |
| Process | `process.create`, `process.start`, `process.kill`, `process.wait`, `process.resize`, `process.delete` |
| Network | `network.createInterface`, `network.releaseInterface` |
| Build extension | `build.create` |

`build.create` is a product-level extension because Containerization does not
define Dockerfile semantics. Its input context and output are streams; the host
may implement it with BuildKit or another builder.

## Framework mapping

| Runtime method | Containerization operation |
|---|---|
| `container.create` | `LinuxContainer.create()` |
| `container.start` | `LinuxContainer.start()` |
| `container.stop` | `LinuxContainer.stop()` |
| `container.kill` | `LinuxContainer.kill(_:)` |
| `container.wait` | `LinuxContainer.wait(timeoutInSeconds:)` |
| `container.resize` | `LinuxContainer.resize(to:)` |
| `process.create` | `LinuxContainer.exec(_:configuration:)` |
| `process.start` | `LinuxProcess.start()` |
| `process.kill` | `LinuxProcess.kill(_:)` |
| `process.wait` | `LinuxProcess.wait(timeoutInSeconds:)` |
| `process.resize` | `LinuxProcess.resize(to:)` |
| `container.copyIn` | `LinuxContainer.copyIn(...)` |
| `container.copyOut` | `LinuxContainer.copyOut(...)` |
| `container.dial` | `LinuxContainer.dialVsock(port:)` |

This mapping is semantic rather than source-compatible. Swift actors, closures,
file handles, and concrete framework types are not part of the wire contract.

### Guest directory mounts

Frontend adapters translate a guest bind-mount source into a host-owned
filesystem resource before creating the container:

```text
Docker or container volume syntax
              |
              v
 filesystem.create(guestPath)
              |
              v
 filesystem ID + container.create mount
              |
              v
 host FSKit mount + Containerization.Mount.share
```

The `source` of a runtime mount is the filesystem resource ID returned by the
host. It is never an outer-host path supplied by the guest. Runtime mount fields
otherwise follow Containerization's semantic model: `type`, `source`,
`destination`, `options`, and `runtimeOptions`.

Filesystem I/O is not tunneled through container lifecycle requests. The host
FSKit extension uses a separate bounded filesystem transport to GhostTools for
lookup, attributes, directory enumeration, and range I/O.

### Persistent named volumes

The additive `volume.create`, `volume.list`, `volume.inspect`, `volume.mount`,
and `volume.delete` methods manage sparse ext4 images in trusted per-VM storage.
`volume.mount` translates a named volume internally to
`Containerization.Mount.block`; guests exchange only `@volume/NAME` and
`@mount/NAME` references, never outer-host paths. Volumes survive container and
VM restarts and cannot be deleted while a mount reference reserves them.

## Docker mapping

Docker Compose is client-side orchestration. GhostTools can parse Compose files
and translate their core operations directly without requiring a Docker Engine
daemon or socket:

| Docker operation | Runtime sequence |
|---|---|
| Pull image | `image.pull` |
| Bind guest directory | `filesystem.create`, then a `container.create` mount |
| Create container | `image.unpack`, `container.create` |
| Start container | `container.start` |
| Wait or inspect | `container.wait`, `container.state` |
| Exec | `process.create`, `process.start`, `process.wait`, `process.delete` |
| Stop or remove | `container.stop`, `container.delete` |
| Build Dockerfile | `build.create` with a streamed build context |

Compose networks and restart policies are orchestration features. They are
exposed as additive capabilities rather than leaking Docker
request structures into the base container lifecycle API. Guest-side frontends
implement published-port listeners using the container address returned by the
host.

There is no one-shot `run` request, Docker-shaped host request, compatibility
handshake, or fallback route. Frontends must use the resource methods above.
Methods that have not been implemented fail with `unsupported`.
