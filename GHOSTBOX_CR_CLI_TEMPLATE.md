# Ghostbox Container API CLI Template

This document defines the initial direct Ghostbox CLI catalog for selected APIs
implemented by Apple container `1.2.0` at revision
`6e65319fe476ffe8db8ddaf828a537ed36fe2859`, plus GhostVM's persistent-volume
adapter. It is intentionally limited to the commands listed here.

The `cr` namespace has the long alias `container`. Commands use one qualified
command token followed by an optional receiver reference and arguments:

```text
$ ghostbox cr:RESOURCE:OPERATION [@<resource:id>] [arguments] [options]
```

The value syntax and reference ownership conventions are the same as in
`GHOSTBOX_CLI_TEMPLATE.md`. Direct commands map to one public Swift API. Volume
commands map to the existing GhostVM adapter and retain their `volume.*` wire
method IDs.

## Persistent Volumes

```text
ghostbox cr:volume:create <volume:name>
    [--size=8589934592]
    -> @<volume:id>

ghostbox cr:volume:list -> @<volume:id>...
ghostbox cr:volume:inspect @<volume:id> -> <metadata:volume-metadata>

ghostbox cr:volume:mount @<volume:id>
    <mount:name>
    --destination <destination:container-path>
    [--read-only=false]
    -> @<mount:id>

ghostbox cr:volume:delete @<volume:id>
```

Volumes are persistent ext4 images owned by the VM. `inspect` returns name,
format, byte size, and creation time, but never exposes the outer-host backing
path. `delete` permanently removes an unused volume and its contents. Delete
the mount reference before deleting its volume.

## Memory Size

```text
ghostbox cr:memory-size:create <memory-size:name> <value:string>
    -> @<memory-size:id>

ghostbox cr:memory-size:formatted @<memory-size:id> -> <value:string>

ghostbox cr:memory-size:to-uint64 @<memory-size:id>
    <unit:bytes|kibibytes|mebibytes|gibibytes|tebibytes|pebibytes>
    -> <value:uint64>
```

`create` accepts the syntax implemented by `MemorySize`, such as `512mb` or
`2gb`. Conversion uses Foundation information-storage units and rounds to the
nearest unsigned integer, matching the upstream implementation.

## Resource Labels

```text
ghostbox cr:resource-labels:create <resource-labels:name>
    [--label <label:string>]...
    -> @<resource-labels:id>

ghostbox cr:resource-labels:validate-key <key:string>
ghostbox cr:resource-labels:validate <key:string> <value:string>
ghostbox cr:resource-labels:dictionary @<resource-labels:id> -> <labels:string-map>

ghostbox cr:resource-labels:value @<resource-labels:id>
    <key:string>
    -> <value:string>|null

ghostbox cr:resource-labels:key-length-max -> <length:int>
ghostbox cr:resource-labels:label-length-max -> <length:int>
```

Labels supplied to `create` use `key=value` text. Validation enforces the exact
upstream key and full-label limits. Do not place secrets in labels; dictionary
and value operations return them as plain JSON values.

## Parser Utilities

```text
ghostbox cr:parser:memory-as-mib <memory:string> -> <value:int64>
ghostbox cr:parser:memory-as-bytes <memory:string> -> <value:uint64>
ghostbox cr:parser:labels <label:string>... -> <labels:string-map>
ghostbox cr:parser:platform <platform:string> -> <platform:oci-platform>
ghostbox cr:parser:is-valid-domain-name <name:string> -> <valid:bool>
ghostbox cr:parser:is-valid-domain-name-label <label:string> -> <valid:bool>
ghostbox cr:parser:parse-bool <value:string> -> <value:bool>|null
```

These utilities are deterministic string/value parsers. `labels` does not apply
`ResourceLabels` validation; use the resource-label validation commands when
validated metadata is required. `parse-bool` accepts only `true`, `t`, `false`,
or `f`, case-insensitively, and returns `null` for other input.

## Source Metadata

The generator consumes the metadata block below. `swiftSource` values are
repository-relative and line-pinned to the audited revisions named above.

<!-- GHOSTBOX_CATALOG_METADATA
[
  {"commandID":"cr:volume:create","methodID":"volume.create","sourceKind":"ghostvm-adapter","swiftModule":"GhostVMContainerRuntime","swiftSymbol":"GhostboxVolumeStore.create(name:sizeInBytes:)","swiftSource":"macOS/GhostVMContainerRuntime/Ghostbox/GhostboxVolumeCommands.swift:32","documentationURL":"macOS/GhostVMContainerRuntime/Ghostbox/GhostboxVolumeCommands.swift#L32-L85"},
  {"commandID":"cr:volume:list","methodID":"volume.list","sourceKind":"ghostvm-adapter","swiftModule":"GhostVMContainerRuntime","swiftSymbol":"GhostboxVolumeStore.list()","swiftSource":"macOS/GhostVMContainerRuntime/Ghostbox/GhostboxVolumeCommands.swift:88","documentationURL":"macOS/GhostVMContainerRuntime/Ghostbox/GhostboxVolumeCommands.swift#L88-L91"},
  {"commandID":"cr:volume:inspect","methodID":"volume.inspect","sourceKind":"ghostvm-adapter","swiftModule":"GhostVMContainerRuntime","swiftSymbol":"GhostboxVolumeStore.inspect(name:)","swiftSource":"macOS/GhostVMContainerRuntime/Ghostbox/GhostboxVolumeCommands.swift:93","documentationURL":"macOS/GhostVMContainerRuntime/Ghostbox/GhostboxVolumeCommands.swift#L93-L96"},
  {"commandID":"cr:volume:mount","methodID":"volume.mount","sourceKind":"ghostvm-adapter","swiftModule":"GhostVMContainerRuntime","swiftSymbol":"GhostboxVolumeStore.makeMount(volumeName:mountReference:destination:readOnly:)","swiftSource":"macOS/GhostVMContainerRuntime/Ghostbox/GhostboxVolumeCommands.swift:110","documentationURL":"macOS/GhostVMContainerRuntime/Ghostbox/GhostboxVolumeCommands.swift#L110-L130"},
  {"commandID":"cr:volume:delete","methodID":"volume.delete","sourceKind":"ghostvm-adapter","swiftModule":"GhostVMContainerRuntime","swiftSymbol":"GhostboxVolumeStore.delete(name:)","swiftSource":"macOS/GhostVMContainerRuntime/Ghostbox/GhostboxVolumeCommands.swift:98","documentationURL":"macOS/GhostVMContainerRuntime/Ghostbox/GhostboxVolumeCommands.swift#L98-L108"},
  {"commandID":"cr:memory-size:create","methodID":"crMemorySize.create","sourceKind":"direct","swiftModule":"ContainerPersistence","swiftSymbol":"MemorySize.init(_:)","swiftSource":"Sources/ContainerPersistence/MemorySize.swift:27","documentationURL":"https://github.com/apple/container/blob/6e65319fe476ffe8db8ddaf828a537ed36fe2859/Sources/ContainerPersistence/MemorySize.swift#L27-L29"},
  {"commandID":"cr:memory-size:formatted","methodID":"crMemorySize.formatted","sourceKind":"direct","swiftModule":"ContainerPersistence","swiftSymbol":"MemorySize.formatted","swiftSource":"Sources/ContainerPersistence/MemorySize.swift:51","documentationURL":"https://github.com/apple/container/blob/6e65319fe476ffe8db8ddaf828a537ed36fe2859/Sources/ContainerPersistence/MemorySize.swift#L51-L55"},
  {"commandID":"cr:memory-size:to-uint64","methodID":"crMemorySize.toUInt64","sourceKind":"direct","swiftModule":"ContainerPersistence","swiftSymbol":"MemorySize.toUInt64(unit:)","swiftSource":"Sources/ContainerPersistence/MemorySize.swift:59","documentationURL":"https://github.com/apple/container/blob/6e65319fe476ffe8db8ddaf828a537ed36fe2859/Sources/ContainerPersistence/MemorySize.swift#L59-L61"},
  {"commandID":"cr:resource-labels:create","methodID":"crResourceLabels.create","sourceKind":"direct","swiftModule":"ContainerResource","swiftSymbol":"ResourceLabels.init(_:)","swiftSource":"Sources/ContainerResource/Common/ResourceLabels.swift:39","documentationURL":"https://github.com/apple/container/blob/6e65319fe476ffe8db8ddaf828a537ed36fe2859/Sources/ContainerResource/Common/ResourceLabels.swift#L39-L44"},
  {"commandID":"cr:resource-labels:validate-key","methodID":"crResourceLabels.validateKey","sourceKind":"direct","swiftModule":"ContainerResource","swiftSymbol":"ResourceLabels.validateLabelKey(_:)","swiftSource":"Sources/ContainerResource/Common/ResourceLabels.swift:46","documentationURL":"https://github.com/apple/container/blob/6e65319fe476ffe8db8ddaf828a537ed36fe2859/Sources/ContainerResource/Common/ResourceLabels.swift#L46-L57"},
  {"commandID":"cr:resource-labels:validate","methodID":"crResourceLabels.validate","sourceKind":"direct","swiftModule":"ContainerResource","swiftSymbol":"ResourceLabels.validateLabel(key:value:)","swiftSource":"Sources/ContainerResource/Common/ResourceLabels.swift:59","documentationURL":"https://github.com/apple/container/blob/6e65319fe476ffe8db8ddaf828a537ed36fe2859/Sources/ContainerResource/Common/ResourceLabels.swift#L59-L65"},
  {"commandID":"cr:resource-labels:dictionary","methodID":"crResourceLabels.dictionary","sourceKind":"direct","swiftModule":"ContainerResource","swiftSymbol":"ResourceLabels.dictionary","swiftSource":"Sources/ContainerResource/Common/ResourceLabels.swift:25","documentationURL":"https://github.com/apple/container/blob/6e65319fe476ffe8db8ddaf828a537ed36fe2859/Sources/ContainerResource/Common/ResourceLabels.swift#L25"},
  {"commandID":"cr:resource-labels:value","methodID":"crResourceLabels.value","sourceKind":"direct","swiftModule":"ContainerResource","swiftSymbol":"ResourceLabels.subscript(_:)","swiftSource":"Sources/ContainerResource/Common/ResourceLabels.swift:90","documentationURL":"https://github.com/apple/container/blob/6e65319fe476ffe8db8ddaf828a537ed36fe2859/Sources/ContainerResource/Common/ResourceLabels.swift#L89-L92"},
  {"commandID":"cr:resource-labels:key-length-max","methodID":"crResourceLabels.keyLengthMax","sourceKind":"direct","swiftModule":"ContainerResource","swiftSymbol":"ResourceLabels.keyLengthMax","swiftSource":"Sources/ContainerResource/Common/ResourceLabels.swift:21","documentationURL":"https://github.com/apple/container/blob/6e65319fe476ffe8db8ddaf828a537ed36fe2859/Sources/ContainerResource/Common/ResourceLabels.swift#L21"},
  {"commandID":"cr:resource-labels:label-length-max","methodID":"crResourceLabels.labelLengthMax","sourceKind":"direct","swiftModule":"ContainerResource","swiftSymbol":"ResourceLabels.labelLengthMax","swiftSource":"Sources/ContainerResource/Common/ResourceLabels.swift:23","documentationURL":"https://github.com/apple/container/blob/6e65319fe476ffe8db8ddaf828a537ed36fe2859/Sources/ContainerResource/Common/ResourceLabels.swift#L23"},
  {"commandID":"cr:parser:memory-as-mib","methodID":"crParser.memoryAsMiB","sourceKind":"direct","swiftModule":"ContainerAPIClient","swiftSymbol":"Parser.memoryStringAsMiB(_:)","swiftSource":"Sources/Services/ContainerAPIService/Client/Parser.swift:57","documentationURL":"https://github.com/apple/container/blob/6e65319fe476ffe8db8ddaf828a537ed36fe2859/Sources/Services/ContainerAPIService/Client/Parser.swift#L57-L61"},
  {"commandID":"cr:parser:memory-as-bytes","methodID":"crParser.memoryAsBytes","sourceKind":"direct","swiftModule":"ContainerAPIClient","swiftSymbol":"Parser.memoryStringAsBytes(_:)","swiftSource":"Sources/Services/ContainerAPIService/Client/Parser.swift:63","documentationURL":"https://github.com/apple/container/blob/6e65319fe476ffe8db8ddaf828a537ed36fe2859/Sources/Services/ContainerAPIService/Client/Parser.swift#L63-L67"},
  {"commandID":"cr:parser:labels","methodID":"crParser.labels","sourceKind":"direct","swiftModule":"ContainerAPIClient","swiftSymbol":"Parser.labels(_:)","swiftSource":"Sources/Services/ContainerAPIService/Client/Parser.swift:244","documentationURL":"https://github.com/apple/container/blob/6e65319fe476ffe8db8ddaf828a537ed36fe2859/Sources/Services/ContainerAPIService/Client/Parser.swift#L244-L261"},
  {"commandID":"cr:parser:platform","methodID":"crParser.platform","sourceKind":"direct","swiftModule":"ContainerAPIClient","swiftSymbol":"Parser.platform(from:)","swiftSource":"Sources/Services/ContainerAPIService/Client/Parser.swift:101","documentationURL":"https://github.com/apple/container/blob/6e65319fe476ffe8db8ddaf828a537ed36fe2859/Sources/Services/ContainerAPIService/Client/Parser.swift#L101-L103"},
  {"commandID":"cr:parser:is-valid-domain-name","methodID":"crParser.isValidDomainName","sourceKind":"direct","swiftModule":"ContainerAPIClient","swiftSymbol":"Parser.isValidDomainName(_:)","swiftSource":"Sources/Services/ContainerAPIService/Client/Parser.swift:895","documentationURL":"https://github.com/apple/container/blob/6e65319fe476ffe8db8ddaf828a537ed36fe2859/Sources/Services/ContainerAPIService/Client/Parser.swift#L895-L900"},
  {"commandID":"cr:parser:is-valid-domain-name-label","methodID":"crParser.isValidDomainNameLabel","sourceKind":"direct","swiftModule":"ContainerAPIClient","swiftSymbol":"Parser.isValidDomainNameLabel(_:)","swiftSource":"Sources/Services/ContainerAPIService/Client/Parser.swift:902","documentationURL":"https://github.com/apple/container/blob/6e65319fe476ffe8db8ddaf828a537ed36fe2859/Sources/Services/ContainerAPIService/Client/Parser.swift#L902-L908"},
  {"commandID":"cr:parser:parse-bool","methodID":"crParser.parseBool","sourceKind":"direct","swiftModule":"ContainerAPIClient","swiftSymbol":"Parser.parseBool(string:)","swiftSource":"Sources/Services/ContainerAPIService/Client/Parser.swift:1061","documentationURL":"https://github.com/apple/container/blob/6e65319fe476ffe8db8ddaf828a537ed36fe2859/Sources/Services/ContainerAPIService/Client/Parser.swift#L1061-L1063"}
]
-->
