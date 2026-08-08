# Ghostbox Networking and Host Configuration API

This page maps the 46 Ghostbox networking and host configuration methods to
their corresponding Apple Containerization APIs.

- Ghostbox signatures are sourced from `GHOSTBOX_CLI_COMMANDS.json` and
  `GHOSTBOX_CLI_TEMPLATE.md`.
- Apple API links are pinned to Containerization `0.40.1`, revision
  `7800b4642171561c95b5f55500b19e5dce5acd45`.

| Resource | Methods |
|---|---:|
| `dns` | 8 |
| `hosts-entry` | 11 |
| `hosts` | 5 |
| `socket` | 6 |
| `network` | 9 |
| `interface` | 7 |
| **Total** | **46** |

## DNS

| Ghostbox Signature | Apple API |
|---|---|
| <pre><code>ghostbox cn:dns:create &lt;dns:name&gt;&#10;    [--nameserver &lt;address:string&gt;]...&#10;    [--domain &lt;domain:string&gt;]&#10;    [--search-domain &lt;domain:string&gt;]...&#10;    [--option &lt;option:string&gt;]...</code></pre> | [`DNS.init(nameservers:domain:searchDomains:options:)`](https://apple.github.io/containerization/documentation/containerization/dns/init(nameservers:domain:searchdomains:options:)) |
| <pre><code>ghostbox cn:dns:default-nameservers</code></pre> | [`DNS.defaultNameservers`](https://apple.github.io/containerization/documentation/containerization/dns/defaultnameservers) |
| <pre><code>ghostbox cn:dns:validate @&lt;dns:id&gt;</code></pre> | [`DNS.validate()`](https://apple.github.io/containerization/documentation/containerization/dns/validate()) |
| <pre><code>ghostbox cn:dns:resolv-conf @&lt;dns:id&gt;</code></pre> | [`DNS.resolvConf`](https://apple.github.io/containerization/documentation/containerization/dns/resolvconf) |
| <pre><code>ghostbox cn:dns:nameservers @&lt;dns:id&gt;</code></pre> | [`DNS.nameservers`](https://apple.github.io/containerization/documentation/containerization/dns/nameservers) |
| <pre><code>ghostbox cn:dns:domain @&lt;dns:id&gt;</code></pre> | [`DNS.domain`](https://apple.github.io/containerization/documentation/containerization/dns/domain) |
| <pre><code>ghostbox cn:dns:search-domains @&lt;dns:id&gt;</code></pre> | [`DNS.searchDomains`](https://apple.github.io/containerization/documentation/containerization/dns/searchdomains) |
| <pre><code>ghostbox cn:dns:options @&lt;dns:id&gt;</code></pre> | [`DNS.options`](https://apple.github.io/containerization/documentation/containerization/dns/options) |

## Hosts Entry

| Ghostbox Signature | Apple API |
|---|---|
| <pre><code>ghostbox cn:hosts-entry:create &lt;hosts-entry:name&gt;&#10;    &lt;ip-address:string&gt;&#10;    &lt;hostname:string&gt;...&#10;    [--comment &lt;comment:string&gt;]</code></pre> | [`Hosts.Entry.init(ipAddress:hostnames:comment:)`](https://apple.github.io/containerization/documentation/containerization/hosts/entry/init(ipaddress:hostnames:comment:)) |
| <pre><code>ghostbox cn:hosts-entry:localhost-ipv4 &lt;hosts-entry:name&gt;&#10;    [--comment &lt;comment:string&gt;]</code></pre> | [`Hosts.Entry.localHostIPV4(comment:)`](https://apple.github.io/containerization/documentation/containerization/hosts/entry/localhostipv4(comment:)) |
| <pre><code>ghostbox cn:hosts-entry:localhost-ipv6 &lt;hosts-entry:name&gt;&#10;    [--comment &lt;comment:string&gt;]</code></pre> | [`Hosts.Entry.localHostIPV6(comment:)`](https://apple.github.io/containerization/documentation/containerization/hosts/entry/localhostipv6(comment:)) |
| <pre><code>ghostbox cn:hosts-entry:ipv6-localnet &lt;hosts-entry:name&gt;&#10;    [--comment &lt;comment:string&gt;]</code></pre> | [`Hosts.Entry.ipv6LocalNet(comment:)`](https://apple.github.io/containerization/documentation/containerization/hosts/entry/ipv6localnet(comment:)) |
| <pre><code>ghostbox cn:hosts-entry:ipv6-mcastprefix &lt;hosts-entry:name&gt;&#10;    [--comment &lt;comment:string&gt;]</code></pre> | [`Hosts.Entry.ipv6MulticastPrefix(comment:)`](https://apple.github.io/containerization/documentation/containerization/hosts/entry/ipv6multicastprefix(comment:)) |
| <pre><code>ghostbox cn:hosts-entry:ipv6-allnodes &lt;hosts-entry:name&gt;&#10;    [--comment &lt;comment:string&gt;]</code></pre> | [`Hosts.Entry.ipv6AllNodes(comment:)`](https://apple.github.io/containerization/documentation/containerization/hosts/entry/ipv6allnodes(comment:)) |
| <pre><code>ghostbox cn:hosts-entry:ipv6-allrouters &lt;hosts-entry:name&gt;&#10;    [--comment &lt;comment:string&gt;]</code></pre> | [`Hosts.Entry.ipv6AllRouters(comment:)`](https://apple.github.io/containerization/documentation/containerization/hosts/entry/ipv6allrouters(comment:)) |
| <pre><code>ghostbox cn:hosts-entry:rendered @&lt;hosts-entry:id&gt;</code></pre> | [`Hosts.Entry.rendered`](https://apple.github.io/containerization/documentation/containerization/hosts/entry/rendered) |
| <pre><code>ghostbox cn:hosts-entry:ip-address @&lt;hosts-entry:id&gt;</code></pre> | [`Hosts.Entry.ipAddress`](https://apple.github.io/containerization/documentation/containerization/hosts/entry/ipaddress) |
| <pre><code>ghostbox cn:hosts-entry:hostnames @&lt;hosts-entry:id&gt;</code></pre> | [`Hosts.Entry.hostnames`](https://apple.github.io/containerization/documentation/containerization/hosts/entry/hostnames) |
| <pre><code>ghostbox cn:hosts-entry:comment @&lt;hosts-entry:id&gt;</code></pre> | [`Hosts.Entry.comment`](https://apple.github.io/containerization/documentation/containerization/hosts/entry/comment) |

## Hosts

| Ghostbox Signature | Apple API |
|---|---|
| <pre><code>ghostbox cn:hosts:create &lt;hosts:name&gt;&#10;    [--entry @&lt;hosts-entry:id&gt;]...&#10;    [--comment &lt;comment:string&gt;]</code></pre> | [`Hosts.init(entries:comment:)`](https://apple.github.io/containerization/documentation/containerization/hosts/init(entries:comment:)) |
| <pre><code>ghostbox cn:hosts:default</code></pre> | [`Hosts.default`](https://apple.github.io/containerization/documentation/containerization/hosts/default) |
| <pre><code>ghostbox cn:hosts:hosts-file @&lt;hosts:id&gt;</code></pre> | [`Hosts.hostsFile`](https://apple.github.io/containerization/documentation/containerization/hosts/hostsfile) |
| <pre><code>ghostbox cn:hosts:entries @&lt;hosts:id&gt;</code></pre> | [`Hosts.entries`](https://apple.github.io/containerization/documentation/containerization/hosts/entries) |
| <pre><code>ghostbox cn:hosts:comment @&lt;hosts:id&gt;</code></pre> | [`Hosts.comment`](https://apple.github.io/containerization/documentation/containerization/hosts/comment) |

## Socket

| Ghostbox Signature | Apple API |
|---|---|
| <pre><code>ghostbox cn:socket:create &lt;socket:name&gt;&#10;    --source &lt;source:host-url&gt;&#10;    --destination &lt;destination:host-url&gt;&#10;    [--permissions &lt;permissions:file-permissions&gt;]&#10;    [--direction &lt;direction:into&#124;out-of&gt;]</code></pre> | [`UnixSocketConfiguration.init(source:destination:permissions:direction:)`](https://apple.github.io/containerization/documentation/containerization/unixsocketconfiguration/init(source:destination:permissions:direction:)) |
| <pre><code>ghostbox cn:socket:id @&lt;socket:id&gt;</code></pre> | [`UnixSocketConfiguration.id`](https://apple.github.io/containerization/documentation/containerization/unixsocketconfiguration/id) |
| <pre><code>ghostbox cn:socket:source @&lt;socket:id&gt;</code></pre> | [`UnixSocketConfiguration.source`](https://apple.github.io/containerization/documentation/containerization/unixsocketconfiguration/source) |
| <pre><code>ghostbox cn:socket:destination @&lt;socket:id&gt;</code></pre> | [`UnixSocketConfiguration.destination`](https://apple.github.io/containerization/documentation/containerization/unixsocketconfiguration/destination) |
| <pre><code>ghostbox cn:socket:permissions @&lt;socket:id&gt;</code></pre> | [`UnixSocketConfiguration.permissions`](https://apple.github.io/containerization/documentation/containerization/unixsocketconfiguration/permissions) |
| <pre><code>ghostbox cn:socket:direction @&lt;socket:id&gt;</code></pre> | [`UnixSocketConfiguration.direction`](https://apple.github.io/containerization/documentation/containerization/unixsocketconfiguration/direction-swift.property) |

## Network

`VmnetNetwork` is available on macOS 26 and later.

| Ghostbox Signature | Apple API |
|---|---|
| <pre><code>ghostbox cn:network:vmnet-create &lt;network:name&gt;&#10;    [--mode=shared]&#10;    [--subnet &lt;subnet:cidrv4&gt;]&#10;    [--prefix-v6 &lt;prefix:cidrv6&gt;]</code></pre> | [`VmnetNetwork.init(mode:subnet:prefixV6:)`](https://apple.github.io/containerization/documentation/containerization/vmnetnetwork/init(mode:subnet:prefixv6:)) |
| <pre><code>ghostbox cn:network:subnet @&lt;network:id&gt;</code></pre> | [`VmnetNetwork.subnet`](https://apple.github.io/containerization/documentation/containerization/vmnetnetwork/subnet) |
| <pre><code>ghostbox cn:network:prefix-v6 @&lt;network:id&gt;</code></pre> | [`VmnetNetwork.prefixV6`](https://apple.github.io/containerization/documentation/containerization/vmnetnetwork/prefixv6) |
| <pre><code>ghostbox cn:network:ipv4-gateway @&lt;network:id&gt;</code></pre> | [`VmnetNetwork.ipv4Gateway`](https://apple.github.io/containerization/documentation/containerization/vmnetnetwork/ipv4gateway) |
| <pre><code>ghostbox cn:network:ipv6-gateway @&lt;network:id&gt;</code></pre> | [`VmnetNetwork.ipv6Gateway`](https://apple.github.io/containerization/documentation/containerization/vmnetnetwork/ipv6gateway) |
| <pre><code>ghostbox cn:network:create-interface @&lt;network:id&gt;&#10;    &lt;interface:name&gt;</code></pre> | [`VmnetNetwork.createInterface(_:)`](https://apple.github.io/containerization/documentation/containerization/vmnetnetwork/createinterface(_:)) |
| <pre><code>ghostbox cn:network:create-interface-mtu @&lt;network:id&gt;&#10;    &lt;interface:name&gt;&#10;    &lt;mtu:uint32&gt;</code></pre> | [`VmnetNetwork.createInterface(_:mtu:)`](https://apple.github.io/containerization/documentation/containerization/vmnetnetwork/createinterface(_:mtu:)) |
| <pre><code>ghostbox cn:network:create-interface-without-gateway @&lt;network:id&gt;&#10;    &lt;interface:name&gt;</code></pre> | [`VmnetNetwork.createInterfaceWithoutGateway(_:)`](https://apple.github.io/containerization/documentation/containerization/vmnetnetwork/createinterfacewithoutgateway(_:)) |
| <pre><code>ghostbox cn:network:release-interface @&lt;network:id&gt;&#10;    @&lt;interface:id&gt;</code></pre> | [`VmnetNetwork.releaseInterface(_:)`](https://apple.github.io/containerization/documentation/containerization/vmnetnetwork/releaseinterface(_:)) |

## Interface

| Ghostbox Signature | Apple API |
|---|---|
| <pre><code>ghostbox cn:interface:nat-create &lt;interface:name&gt;&#10;    --ipv4-address &lt;address:cidrv4&gt;&#10;    [--ipv4-gateway &lt;gateway:ipv4-address&gt;]&#10;    [--ipv6-address &lt;address:cidrv6&gt;]&#10;    [--ipv6-gateway &lt;gateway:ipv6-address&gt;]&#10;    [--mac-address &lt;address:mac-address&gt;]&#10;    [--mtu=1500]</code></pre> | [`NATInterface.init(ipv4Address:ipv4Gateway:ipv6Address:ipv6Gateway:macAddress:mtu:)`](https://apple.github.io/containerization/documentation/containerization/natinterface/init(ipv4address:ipv4gateway:ipv6address:ipv6gateway:macaddress:mtu:)) |
| <pre><code>ghostbox cn:interface:ipv4-address @&lt;interface:id&gt;</code></pre> | [`Interface.ipv4Address`](https://apple.github.io/containerization/documentation/containerization/interface/ipv4address) |
| <pre><code>ghostbox cn:interface:ipv4-gateway @&lt;interface:id&gt;</code></pre> | [`Interface.ipv4Gateway`](https://apple.github.io/containerization/documentation/containerization/interface/ipv4gateway) |
| <pre><code>ghostbox cn:interface:ipv6-address @&lt;interface:id&gt;</code></pre> | [`Interface.ipv6Address`](https://apple.github.io/containerization/documentation/containerization/interface/ipv6address) |
| <pre><code>ghostbox cn:interface:ipv6-gateway @&lt;interface:id&gt;</code></pre> | [`Interface.ipv6Gateway`](https://apple.github.io/containerization/documentation/containerization/interface/ipv6gateway) |
| <pre><code>ghostbox cn:interface:mac-address @&lt;interface:id&gt;</code></pre> | [`Interface.macAddress`](https://apple.github.io/containerization/documentation/containerization/interface/macaddress) |
| <pre><code>ghostbox cn:interface:mtu @&lt;interface:id&gt;</code></pre> | [`Interface.mtu`](https://apple.github.io/containerization/documentation/containerization/interface/mtu) |

The interface accessors use `Interface` protocol requirements because Ghostbox
stores and reads both NAT and vmnet-backed interfaces through `any Interface`.
