# Ghostbox Container Examples

These scripts compose Ghostbox's source-shaped lifecycle methods into behavior
similar to `docker run --rm`. They do not add a `run` operation: allocation,
creation, start, wait, stop, and deletion remain separate calls.

Run them inside a GhostVM guest with Host-backed Containers enabled. Install
Apple container's recommended Linux kernel on the outer host through Ghostbox:

```sh
ghostbox cn:kernel:install-recommended
```

The operation performs Apple's digest-verified download on the outer host and
returns `@kernel/default`. `setup-manager.sh` runs it automatically and reuses an
already-installed recommended kernel.

## One-Time Manager Setup

Create a reusable manager backed by the host's default kernel and image store:

```sh
./setup-manager.sh
```

The script prints `@manager/ephemeral`. Its default init image is pinned by
manifest digest so an older tag-cache entry cannot silently supply incompatible
guest enforcement. Override the names or pinned init image with `MANAGER_NAME`
and `INITFS_REFERENCE`.

## Non-Interactive

Run Alpine's default example command:

```sh
./ephemeral-container.sh
```

Run a command and propagate its exit status:

```sh
./ephemeral-container.sh docker.io/library/alpine:latest \
    /bin/sh -c 'printf "container says hello\\n"; exit 7'
```

## Interactive PTY

```sh
./ephemeral-terminal.sh docker.io/library/alpine:latest /bin/sh
```

The terminal script waits until raw-mode setup and the first resize reach the
host before it starts the container. It watches the workload cgroup and closes
the PTY proxy when the final process exits, allowing Apple's process wait to
finish draining terminal I/O. Both scripts use traps to stop and delete the
allocated container, delete its process configuration, and close all I/O
proxies on success, failure, or a termination signal. Pulled images remain in
the host cache.

Container networking defaults to `false`, so the basic examples do not require
a vmnet network. Set `CONTAINER_NETWORKING=true` when the manager was created
with a suitable network.

Use another manager or resource limits through environment variables:

```sh
MANAGER=@manager/build CONTAINER_CPUS=2 CONTAINER_MEMORY=1073741824 \
    ./ephemeral-container.sh docker.io/library/alpine:latest uname -a
```

## Resource Cleanup

Remove reusable host references when they are no longer needed:

```sh
ghostbox cn:process-config:delete @process-config/example
ghostbox cn:dns:delete @dns/example
ghostbox cn:network:delete @network/example
ghostbox cn:manager:close @manager/ephemeral
```

Release every network-allocated interface before deleting its network. Delete
all managed containers before closing their manager. Cached images can be
removed separately with `ghostbox cn:image-store:delete @image-store/default REFERENCE`.

## Persistent Volumes

Run a two-container write/read lifecycle against one named ext4 volume:

```sh
./persistent-volume.sh
```

The script creates the volume and a block-mount reference, supplies the default
container mounts plus that reference, verifies data from a second container,
then removes the mount and volume. Named volumes are stored with the VM and
normally remain until explicitly deleted.
