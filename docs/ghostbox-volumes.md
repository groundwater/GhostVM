# Ghostbox Persistent Volumes

Ghostbox named volumes are sparse ext4 disk images stored inside the owning VM
bundle. They survive container deletion, Ghostbox session cleanup, and VM
restarts. The outer-host backing path is trusted runtime state and is never
accepted from or returned to the guest.

## Lifecycle

```sh
volume=$(ghostbox cr:volume:create app-data --size 8589934592)
ghostbox cr:volume:list
ghostbox cr:volume:inspect "$volume"
mount=$(ghostbox cr:volume:mount "$volume" app-data --destination /var/lib/app)
```

The mount command returns a normal `@mount/NAME` reference backed by
`Containerization.Mount.block(format:source:destination:options:)`. Include that
reference and every reference returned by `ghostbox cn:container:default-mounts`
when supplying `--mounts` to a manager create operation. Supplying `--mounts`
replaces the complete mount set; it does not append to the defaults.

Delete the mount reference before deleting the volume:

```sh
ghostbox cn:mount:delete "$mount"
ghostbox cr:volume:delete "$volume"
```

Deletion fails while a named-volume mount reference exists. A volume can have
only one such reference at a time. Do not attach the same block-backed mount to
multiple live container VMs concurrently.

## Limits

- Names begin with a letter or digit and otherwise use letters, digits, `.`,
  `_`, or `-`.
- Sizes range from 1 MiB through 1 TiB; the default is 8 GiB.
- Each VM can store at most 128 named volumes.
- `inspect` reports the name, ext4 format, logical size, and creation date. It
  omits the outer-host image path.
- `ghostbox cn:mount:source @mount/NAME` returns the opaque `@volume/NAME` source
  for managed volume mounts.
