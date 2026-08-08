# Ghostbox Container Parser Utilities API

This page maps the seven initial `cr:parser` commands to public APIs in Apple
container `1.2.0`, revision `6e65319fe476ffe8db8ddaf828a537ed36fe2859`.

| Resource | Methods |
|---|---:|
| `parser` | 7 |
| **Total** | **7** |

| Ghostbox Signature | Swift API |
|---|---|
| <pre><code>ghostbox cr:parser:memory-as-mib &lt;memory:string&gt;</code></pre> | [`Parser.memoryStringAsMiB(_:)`](https://github.com/apple/container/blob/6e65319fe476ffe8db8ddaf828a537ed36fe2859/Sources/Services/ContainerAPIService/Client/Parser.swift#L57-L61) in `ContainerAPIClient` |
| <pre><code>ghostbox cr:parser:memory-as-bytes &lt;memory:string&gt;</code></pre> | [`Parser.memoryStringAsBytes(_:)`](https://github.com/apple/container/blob/6e65319fe476ffe8db8ddaf828a537ed36fe2859/Sources/Services/ContainerAPIService/Client/Parser.swift#L63-L67) in `ContainerAPIClient` |
| <pre><code>ghostbox cr:parser:labels &lt;label:string&gt;...</code></pre> | [`Parser.labels(_:)`](https://github.com/apple/container/blob/6e65319fe476ffe8db8ddaf828a537ed36fe2859/Sources/Services/ContainerAPIService/Client/Parser.swift#L244-L261) in `ContainerAPIClient` |
| <pre><code>ghostbox cr:parser:platform &lt;platform:string&gt;</code></pre> | [`Parser.platform(from:)`](https://github.com/apple/container/blob/6e65319fe476ffe8db8ddaf828a537ed36fe2859/Sources/Services/ContainerAPIService/Client/Parser.swift#L101-L103) in `ContainerAPIClient` |
| <pre><code>ghostbox cr:parser:is-valid-domain-name &lt;name:string&gt;</code></pre> | [`Parser.isValidDomainName(_:)`](https://github.com/apple/container/blob/6e65319fe476ffe8db8ddaf828a537ed36fe2859/Sources/Services/ContainerAPIService/Client/Parser.swift#L895-L900) in `ContainerAPIClient` |
| <pre><code>ghostbox cr:parser:is-valid-domain-name-label &lt;label:string&gt;</code></pre> | [`Parser.isValidDomainNameLabel(_:)`](https://github.com/apple/container/blob/6e65319fe476ffe8db8ddaf828a537ed36fe2859/Sources/Services/ContainerAPIService/Client/Parser.swift#L902-L908) in `ContainerAPIClient` |
| <pre><code>ghostbox cr:parser:parse-bool &lt;value:string&gt;</code></pre> | [`Parser.parseBool(string:)`](https://github.com/apple/container/blob/6e65319fe476ffe8db8ddaf828a537ed36fe2859/Sources/Services/ContainerAPIService/Client/Parser.swift#L1061-L1063) in `ContainerAPIClient` |

`labels` parses text but does not apply `ResourceLabels` validation. `parse-bool`
returns `null` for values other than case-insensitive `true`, `t`, `false`, and
`f`.
