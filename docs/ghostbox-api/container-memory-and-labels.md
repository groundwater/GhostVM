# Ghostbox Container Memory and Labels API

This page maps the ten initial `cr` memory-size and resource-label commands to
public Swift APIs in Apple container `1.2.0`, revision
`6e65319fe476ffe8db8ddaf828a537ed36fe2859`.

| Resource | Methods |
|---|---:|
| `memory-size` | 3 |
| `resource-labels` | 7 |
| **Total** | **10** |

## Memory Size

| Ghostbox Signature | Swift API |
|---|---|
| <pre><code>ghostbox cr:memory-size:create &lt;memory-size:name&gt; &lt;value:string&gt;</code></pre> | [`MemorySize.init(_:)`](https://github.com/apple/container/blob/6e65319fe476ffe8db8ddaf828a537ed36fe2859/Sources/ContainerPersistence/MemorySize.swift#L27-L29) in `ContainerPersistence` |
| <pre><code>ghostbox cr:memory-size:formatted @&lt;memory-size:id&gt;</code></pre> | [`MemorySize.formatted`](https://github.com/apple/container/blob/6e65319fe476ffe8db8ddaf828a537ed36fe2859/Sources/ContainerPersistence/MemorySize.swift#L51-L55) in `ContainerPersistence` |
| <pre><code>ghostbox cr:memory-size:to-uint64 @&lt;memory-size:id&gt;&#10;    &lt;unit:bytes&#124;kibibytes&#124;mebibytes&#124;gibibytes&#124;tebibytes&#124;pebibytes&gt;</code></pre> | [`MemorySize.toUInt64(unit:)`](https://github.com/apple/container/blob/6e65319fe476ffe8db8ddaf828a537ed36fe2859/Sources/ContainerPersistence/MemorySize.swift#L59-L61) in `ContainerPersistence` |

Memory input follows the upstream parser. Conversion rounds the selected
Foundation information-storage unit to the nearest unsigned integer.

## Resource Labels

| Ghostbox Signature | Swift API |
|---|---|
| <pre><code>ghostbox cr:resource-labels:create &lt;resource-labels:name&gt;&#10;    [--label &lt;label:string&gt;]...</code></pre> | [`ResourceLabels.init(_:)`](https://github.com/apple/container/blob/6e65319fe476ffe8db8ddaf828a537ed36fe2859/Sources/ContainerResource/Common/ResourceLabels.swift#L39-L44) in `ContainerResource` |
| <pre><code>ghostbox cr:resource-labels:validate-key &lt;key:string&gt;</code></pre> | [`ResourceLabels.validateLabelKey(_:)`](https://github.com/apple/container/blob/6e65319fe476ffe8db8ddaf828a537ed36fe2859/Sources/ContainerResource/Common/ResourceLabels.swift#L46-L57) in `ContainerResource` |
| <pre><code>ghostbox cr:resource-labels:validate &lt;key:string&gt; &lt;value:string&gt;</code></pre> | [`ResourceLabels.validateLabel(key:value:)`](https://github.com/apple/container/blob/6e65319fe476ffe8db8ddaf828a537ed36fe2859/Sources/ContainerResource/Common/ResourceLabels.swift#L59-L65) in `ContainerResource` |
| <pre><code>ghostbox cr:resource-labels:dictionary @&lt;resource-labels:id&gt;</code></pre> | [`ResourceLabels.dictionary`](https://github.com/apple/container/blob/6e65319fe476ffe8db8ddaf828a537ed36fe2859/Sources/ContainerResource/Common/ResourceLabels.swift#L25) in `ContainerResource` |
| <pre><code>ghostbox cr:resource-labels:value @&lt;resource-labels:id&gt;&#10;    &lt;key:string&gt;</code></pre> | [`ResourceLabels.subscript(_:)`](https://github.com/apple/container/blob/6e65319fe476ffe8db8ddaf828a537ed36fe2859/Sources/ContainerResource/Common/ResourceLabels.swift#L89-L92) in `ContainerResource` |
| <pre><code>ghostbox cr:resource-labels:key-length-max</code></pre> | [`ResourceLabels.keyLengthMax`](https://github.com/apple/container/blob/6e65319fe476ffe8db8ddaf828a537ed36fe2859/Sources/ContainerResource/Common/ResourceLabels.swift#L21) in `ContainerResource` |
| <pre><code>ghostbox cr:resource-labels:label-length-max</code></pre> | [`ResourceLabels.labelLengthMax`](https://github.com/apple/container/blob/6e65319fe476ffe8db8ddaf828a537ed36fe2859/Sources/ContainerResource/Common/ResourceLabels.swift#L23) in `ContainerResource` |

Create labels use `key=value` input. Labels are returned as plain JSON, so they
must not contain secrets.
