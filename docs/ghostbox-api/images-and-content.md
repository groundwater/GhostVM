# Ghostbox Images and Content API

This page maps the 41 Ghostbox image and content methods to their corresponding
Apple Containerization APIs.

- Ghostbox signatures are sourced from `GHOSTBOX_CLI_COMMANDS.json` and
  `GHOSTBOX_CLI_TEMPLATE.md`.
- Apple API links are pinned to Containerization `0.40.1`, revision
  `7800b4642171561c95b5f55500b19e5dce5acd45`.

| Resource | Methods |
|---|---:|
| `image-store` | 16 |
| `content-store` | 1 |
| `authentication` | 1 |
| `progress-handler` | 1 |
| `image-description` | 5 |
| `image` | 12 |
| `content` | 5 |
| **Total** | **41** |

## Image Store

| Ghostbox Signature | Apple API |
|---|---|
| <pre><code>ghostbox cn:image-store:create &lt;image-store:name&gt;&#10;    --path &lt;path:host-url&gt;&#10;    [--content-store @&lt;content-store:id&gt;]</code></pre> | [`ImageStore.init(path:contentStore:)`](https://apple.github.io/containerization/documentation/containerization/imagestore/init(path:contentstore:)) |
| <pre><code>ghostbox cn:image-store:default</code></pre> | [`ImageStore.default`](https://apple.github.io/containerization/documentation/containerization/imagestore/default) |
| <pre><code>ghostbox cn:image-store:path @&lt;image-store:id&gt;</code></pre> | [`ImageStore.path`](https://apple.github.io/containerization/documentation/containerization/imagestore/path) |
| <pre><code>ghostbox cn:image-store:get @&lt;image-store:id&gt;&#10;    &lt;reference:string&gt;&#10;    [--pull=false]</code></pre> | [`ImageStore.get(reference:pull:)`](https://apple.github.io/containerization/documentation/containerization/imagestore/get(reference:pull:)) |
| <pre><code>ghostbox cn:image-store:list @&lt;image-store:id&gt;</code></pre> | [`ImageStore.list()`](https://apple.github.io/containerization/documentation/containerization/imagestore/list()) |
| <pre><code>ghostbox cn:image-store:create-image @&lt;image-store:id&gt;&#10;    @&lt;image-description:id&gt;</code></pre> | [`ImageStore.create(description:)`](https://apple.github.io/containerization/documentation/containerization/imagestore/create(description:)) |
| <pre><code>ghostbox cn:image-store:delete @&lt;image-store:id&gt;&#10;    &lt;reference:string&gt;&#10;    [--perform-cleanup=false]</code></pre> | [`ImageStore.delete(reference:performCleanup:)`](https://apple.github.io/containerization/documentation/containerization/imagestore/delete(reference:performcleanup:)) |
| <pre><code>ghostbox cn:image-store:clean-up-orphaned-blobs @&lt;image-store:id&gt;</code></pre> | [`ImageStore.cleanUpOrphanedBlobs()`](https://apple.github.io/containerization/documentation/containerization/imagestore/cleanuporphanedblobs()) |
| <pre><code>ghostbox cn:image-store:calculate-orphaned-blobs-size @&lt;image-store:id&gt;</code></pre> | [`ImageStore.calculateOrphanedBlobsSize()`](https://apple.github.io/containerization/documentation/containerization/imagestore/calculateorphanedblobssize()) |
| <pre><code>ghostbox cn:image-store:tag @&lt;image-store:id&gt;&#10;    &lt;existing-reference:string&gt;&#10;    &lt;new-reference:string&gt;</code></pre> | [`ImageStore.tag(existing:new:)`](https://apple.github.io/containerization/documentation/containerization/imagestore/tag(existing:new:)) |
| <pre><code>ghostbox cn:image-store:pull @&lt;image-store:id&gt;&#10;    &lt;reference:string&gt;&#10;    [--platform &lt;platform:oci-platform&gt;]&#10;    [--insecure=false]&#10;    [--authentication @&lt;authentication:id&gt;]&#10;    [--progress @&lt;progress-handler:id&gt;]&#10;    [--max-concurrent-downloads=3]</code></pre> | [`ImageStore.pull(reference:platform:insecure:auth:progress:maxConcurrentDownloads:)`](https://apple.github.io/containerization/documentation/containerization/imagestore/pull(reference:platform:insecure:auth:progress:maxconcurrentdownloads:)) |
| <pre><code>ghostbox cn:image-store:push @&lt;image-store:id&gt;&#10;    &lt;reference:string&gt;&#10;    [--platform &lt;platform:oci-platform&gt;]&#10;    [--insecure=false]&#10;    [--authentication @&lt;authentication:id&gt;]&#10;    [--progress @&lt;progress-handler:id&gt;]</code></pre> | [`ImageStore.push(reference:platform:insecure:auth:progress:)`](https://apple.github.io/containerization/documentation/containerization/imagestore/push(reference:platform:insecure:auth:progress:)) |
| <pre><code>ghostbox cn:image-store:push-many @&lt;image-store:id&gt;&#10;    &lt;reference:string&gt;...&#10;    [--platform &lt;platform:oci-platform&gt;]&#10;    [--insecure=false]&#10;    [--authentication @&lt;authentication:id&gt;]&#10;    [--max-concurrent-uploads=3]&#10;    [--progress @&lt;progress-handler:id&gt;]</code></pre> | [`ImageStore.push(references:platform:insecure:auth:maxConcurrentUploads:progress:)`](https://apple.github.io/containerization/documentation/containerization/imagestore/push(references:platform:insecure:auth:maxconcurrentuploads:progress:)) |
| <pre><code>ghostbox cn:image-store:save @&lt;image-store:id&gt;&#10;    &lt;reference:string&gt;...&#10;    --out &lt;directory:host-url&gt;&#10;    [--platform &lt;platform:oci-platform&gt;]</code></pre> | [`ImageStore.save(references:out:platform:)`](https://apple.github.io/containerization/documentation/containerization/imagestore/save(references:out:platform:)) |
| <pre><code>ghostbox cn:image-store:load @&lt;image-store:id&gt;&#10;    &lt;directory:host-url&gt;&#10;    [--progress @&lt;progress-handler:id&gt;]</code></pre> | [`ImageStore.load(from:progress:)`](https://apple.github.io/containerization/documentation/containerization/imagestore/load(from:progress:)) |
| <pre><code>ghostbox cn:image-store:get-init-image @&lt;image-store:id&gt;&#10;    &lt;reference:string&gt;&#10;    [--authentication @&lt;authentication:id&gt;]&#10;    [--progress @&lt;progress-handler:id&gt;]</code></pre> | [`ImageStore.getInitImage(reference:auth:progress:)`](https://apple.github.io/containerization/documentation/containerization/imagestore/getinitimage(reference:auth:progress:)) |

`image-store push` and `image-store push-many` select Apple's single-reference
and multiple-reference `push` overloads respectively.

## Content Store, Authentication, and Progress

| Ghostbox Signature | Apple API |
|---|---|
| <pre><code>ghostbox cn:content-store:create &lt;content-store:name&gt;&#10;    --path &lt;path:host-url&gt;</code></pre> | [`LocalContentStore.init(path:)`](https://apple.github.io/containerization/documentation/containerizationoci/localcontentstore/init(path:)) |
| <pre><code>ghostbox cn:authentication:create-basic &lt;authentication:name&gt;&#10;    --username &lt;username:string&gt;&#10;    --password &lt;password:string&gt;</code></pre> | [`BasicAuthentication.init(username:password:)`](https://apple.github.io/containerization/documentation/containerizationoci/basicauthentication/init(username:password:)) |
| <pre><code>ghostbox cn:progress-handler:create &lt;progress-handler:name&gt;&#10;    --writer @&lt;writer:id&gt;</code></pre> | [`ProgressHandler`](https://apple.github.io/containerization/documentation/containerizationextras/progresshandler) |

The progress-handler command is a Ghostbox transport adapter for Apple's
callback type. It writes newline-delimited `{event,value}` JSON objects through
the selected Apple `Writer` implementation.

## Image Description

| Ghostbox Signature | Apple API |
|---|---|
| <pre><code>ghostbox cn:image-description:create&#10;    &lt;image-description:name&gt;&#10;    &lt;reference:string&gt;&#10;    &lt;descriptor:oci-descriptor-json&gt;</code></pre> | [`Image.Description.init(reference:descriptor:)`](https://apple.github.io/containerization/documentation/containerization/image/description-swift.struct/init(reference:descriptor:)) |
| <pre><code>ghostbox cn:image-description:reference @&lt;image-description:id&gt;</code></pre> | [`Image.Description.reference`](https://apple.github.io/containerization/documentation/containerization/image/description-swift.struct/reference) |
| <pre><code>ghostbox cn:image-description:descriptor @&lt;image-description:id&gt;</code></pre> | [`Image.Description.descriptor`](https://apple.github.io/containerization/documentation/containerization/image/description-swift.struct/descriptor) |
| <pre><code>ghostbox cn:image-description:digest @&lt;image-description:id&gt;</code></pre> | [`Image.Description.digest`](https://apple.github.io/containerization/documentation/containerization/image/description-swift.struct/digest) |
| <pre><code>ghostbox cn:image-description:media-type @&lt;image-description:id&gt;</code></pre> | [`Image.Description.mediaType`](https://apple.github.io/containerization/documentation/containerization/image/description-swift.struct/mediatype) |

## Image

| Ghostbox Signature | Apple API |
|---|---|
| <pre><code>ghostbox cn:image:create &lt;image:name&gt;&#10;    @&lt;image-description:id&gt;&#10;    @&lt;content-store:id&gt;</code></pre> | [`Image.init(description:contentStore:)`](https://apple.github.io/containerization/documentation/containerization/image/init(description:contentstore:)) |
| <pre><code>ghostbox cn:image:description @&lt;image:id&gt;</code></pre> | [`Image.description`](https://apple.github.io/containerization/documentation/containerization/image/description-swift.property) |
| <pre><code>ghostbox cn:image:descriptor @&lt;image:id&gt;</code></pre> | [`Image.descriptor`](https://apple.github.io/containerization/documentation/containerization/image/descriptor) |
| <pre><code>ghostbox cn:image:digest @&lt;image:id&gt;</code></pre> | [`Image.digest`](https://apple.github.io/containerization/documentation/containerization/image/digest) |
| <pre><code>ghostbox cn:image:media-type @&lt;image:id&gt;</code></pre> | [`Image.mediaType`](https://apple.github.io/containerization/documentation/containerization/image/mediatype) |
| <pre><code>ghostbox cn:image:reference @&lt;image:id&gt;</code></pre> | [`Image.reference`](https://apple.github.io/containerization/documentation/containerization/image/reference) |
| <pre><code>ghostbox cn:image:index @&lt;image:id&gt;</code></pre> | [`Image.index()`](https://apple.github.io/containerization/documentation/containerization/image/index()) |
| <pre><code>ghostbox cn:image:manifest @&lt;image:id&gt;&#10;    &lt;platform:oci-platform&gt;</code></pre> | [`Image.manifest(for:)`](https://apple.github.io/containerization/documentation/containerization/image/manifest(for:)) |
| <pre><code>ghostbox cn:image:descriptor-for @&lt;image:id&gt;&#10;    &lt;platform:oci-platform&gt;</code></pre> | [`Image.descriptor(for:)`](https://apple.github.io/containerization/documentation/containerization/image/descriptor(for:)) |
| <pre><code>ghostbox cn:image:config @&lt;image:id&gt;&#10;    &lt;platform:oci-platform&gt;</code></pre> | [`Image.config(for:)`](https://apple.github.io/containerization/documentation/containerization/image/config(for:)) |
| <pre><code>ghostbox cn:image:referenced-digests @&lt;image:id&gt;</code></pre> | [`Image.referencedDigests()`](https://apple.github.io/containerization/documentation/containerization/image/referenceddigests()) |
| <pre><code>ghostbox cn:image:get-content @&lt;image:id&gt;&#10;    &lt;digest:string&gt;</code></pre> | [`Image.getContent(digest:)`](https://apple.github.io/containerization/documentation/containerization/image/getcontent(digest:)) |

## Content

The linked `Content` APIs belong to the `ContainerizationOCI` module.

| Ghostbox Signature | Apple API |
|---|---|
| <pre><code>ghostbox cn:content:path @&lt;content:id&gt;</code></pre> | [`Content.path`](https://apple.github.io/containerization/documentation/containerizationoci/content/path) |
| <pre><code>ghostbox cn:content:digest @&lt;content:id&gt;</code></pre> | [`Content.digest()`](https://apple.github.io/containerization/documentation/containerizationoci/content/digest()) |
| <pre><code>ghostbox cn:content:size @&lt;content:id&gt;</code></pre> | [`Content.size()`](https://apple.github.io/containerization/documentation/containerizationoci/content/size()) |
| <pre><code>ghostbox cn:content:data @&lt;content:id&gt;</code></pre> | [`Content.data()`](https://apple.github.io/containerization/documentation/containerizationoci/content/data()) |
| <pre><code>ghostbox cn:content:data-range @&lt;content:id&gt;&#10;    &lt;offset:uint64&gt;&#10;    &lt;length:int&gt;</code></pre> | [`Content.data(offset:length:)`](https://apple.github.io/containerization/documentation/containerizationoci/content/data(offset:length:)) |

Ghostbox enforces its direct-protocol byte limit before returning content data.
For `content data-range`, a CLI length of zero means read from the offset through
the end of the content.
