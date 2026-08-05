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

## Docker mapping

Docker Compose is client-side and uses the ordinary Docker Engine API. A
GhostTools Docker endpoint can therefore translate its core calls as follows:

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

Named volumes, Compose networks, port publication, and restart policies are
orchestration features. They belong in the host runtime service and are exposed
as additive capabilities rather than leaking Docker request structures into
the base container lifecycle API.

## One-shot run compatibility

The one-shot `run` request remains operational while the primitive handlers are
implemented. It is a temporary compatibility path and is not part of the stable
runtime surface above. Its optional `volumes` array contains
`{guestPath, destination, readOnly}` records. The host validates these,
registers capability-scoped FSKit exports, mounts them for the run lifetime, and
passes only the resulting host mount paths to the isolated runtime helper.

Version 1 sends raw stdin bytes after the request newline and remains accepted
for existing GhostTools installations. Version 2 adds `tty`, `columns`, and
`rows` request fields. Guest-to-host traffic after a version 2 request is NDJSON:

```json
{"version":2,"type":"stdin","data":"YmFzZTY0"}
{"version":2,"type":"resize","columns":120,"rows":40}
{"version":2,"type":"stdinClose"}
```

Host responses use the request's protocol version. In TTY mode, the container
process receives a native PTY, stderr is merged into stdout, `TERM` is set to
`xterm-256color`, and resize frames map to `LinuxContainer.resize(to:)`.

Version 4 adds optional `environment`, `workingDirectory`, `user`, `cpus`, and
`memoryBytes` run fields. Once the container starts, the host returns its
private address before relaying output:

```json
{"version":4,"type":"ready","ipv4Address":"192.168.64.3"}
```

`ghostbox` binds requested TCP ports in the macOS guest and forwards them to
that address. The host never binds an outer-Mac port on behalf of a guest run.
