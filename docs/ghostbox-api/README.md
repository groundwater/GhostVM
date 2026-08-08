# Ghostbox API Reference

This reference maps all 282 cataloged Ghostbox direct CLI methods to their
corresponding Apple Containerization, Apple container, or GhostVM adapter APIs.

The combined command catalog is defined by
[`GHOSTBOX_CLI_COMMANDS.json`](../../GHOSTBOX_CLI_COMMANDS.json),
[`GHOSTBOX_CLI_TEMPLATE.md`](../../GHOSTBOX_CLI_TEMPLATE.md), and
[`GHOSTBOX_CR_CLI_TEMPLATE.md`](../../GHOSTBOX_CR_CLI_TEMPLATE.md).
Containerization links are pinned to `0.40.1` revision
`7800b4642171561c95b5f55500b19e5dce5acd45`; container links are pinned to
`1.2.0` revision `6e65319fe476ffe8db8ddaf828a537ed36fe2859`.

CLI tables show inputs only. Ghostbox output types and the corresponding Swift
declarations are intentionally omitted.

| Page | Resources | Methods |
|---|---|---:|
| [Images and Content](images-and-content.md) | `content-store`, `authentication`, `progress-handler`, `image-store`, `image-description`, `image`, `content` | 41 |
| [Boot and Mounts](boot-and-mounts.md) | `kernel-command-line`, `kernel`, `kernel-image`, `init-image`, `mount`, `boot-log` | 34 |
| [Networking and Host Configuration](networking-and-host-configuration.md) | `dns`, `hosts-entry`, `hosts`, `socket`, `network`, `interface` | 46 |
| [Virtual Machines](virtual-machines.md) | `vm-config`, `standard-vm-config`, `vmm`, `vm-instance` | 12 |
| [Process Configuration](process-configuration.md) | `rlimit-kind`, `rlimit`, `capabilities`, `process-config` | 32 |
| [Containers, Managers, and Processes](containers-managers-and-processes.md) | `container-config`, `manager`, `container`, `process` | 49 |
| [Pods](pods.md) | `pod-volume`, `pod-config`, `pod-container-config`, `pod` | 46 |
| [Container Volumes](container-volumes.md) | `volume` | 5 |
| [Container Memory and Labels](container-memory-and-labels.md) | `memory-size`, `resource-labels` | 10 |
| [Container Parser Utilities](container-parser-utilities.md) | `parser` | 7 |
| **Total** | **39 resources** | **282** |

## Signature Conventions

- `cn:RESOURCE:OPERATION` selects the Containerization namespace; its long
  namespace alias is `containerization`.
- `cr:RESOURCE:OPERATION` selects the container namespace; its long namespace
  alias is `container`.
- `<argument:type>` is a literal input.
- `@<argument:type>` is an existing VMHost-owned object reference.
- `[argument]` is optional.
- `argument...` is repeatable.
- `[--argument=default]` is optional and shows the framework default.
