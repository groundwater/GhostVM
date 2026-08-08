import Containerization
import ContainerizationExtras
import ContainerizationOCI
import ContainerizationOS
import Foundation
import GhostVMKit

let ghostboxImageStoreContextKey = "ghostbox.image-store"

struct GhostboxProgressHandlerBox: Sendable {
    let handler: ProgressHandler
    let writerReference: String

    init(_ handler: @escaping ProgressHandler, writerReference: String) {
        self.handler = handler
        self.writerReference = writerReference
    }
}

private struct GhostboxAuthenticationRecord: Sendable {
    let value: any Authentication
    let username: String
    let password: String
}

struct GhostboxContentStoreCommands: GhostboxDomainHandler {
    let resource = "contentStore"

    func handle(
        method: GhostboxDirectMethod,
        parameters: [String: GhostboxJSONValue],
        session: GhostboxSession
    ) async throws -> GhostboxDirectValue {
        guard method.rawValue == "contentStore.create" else { throw ghostboxUnsupportedImageMethod(method) }
        let decoded = try GhostboxParameters(parameters, allowed: ["contentStore", "path"])
        let store = try LocalContentStore(path: ghostboxHostURL(decoded.requiredString("path"), parameter: "path"))
        let reference = try session.register(
            kind: "content-store",
            name: decoded.requiredString("contentStore"),
            value: store,
            equivalent: { $0 === $1 }
        )
        return .reference(reference)
    }
}

struct GhostboxAuthenticationCommands: GhostboxDomainHandler {
    let resource = "authentication"

    func handle(
        method: GhostboxDirectMethod,
        parameters: [String: GhostboxJSONValue],
        session: GhostboxSession
    ) async throws -> GhostboxDirectValue {
        guard method.rawValue == "authentication.createBasic" else { throw ghostboxUnsupportedImageMethod(method) }
        let decoded = try GhostboxParameters(parameters, allowed: ["authentication", "username", "password"])
        let username = try decoded.requiredString("username")
        let password = try decoded.requiredString("password")
        let record = GhostboxAuthenticationRecord(
            value: BasicAuthentication(username: username, password: password),
            username: username,
            password: password
        )
        let reference = try session.register(
            kind: "authentication",
            name: decoded.requiredString("authentication"),
            value: record,
            equivalent: { $0.username == $1.username && $0.password == $1.password }
        )
        return .reference(reference)
    }
}

struct GhostboxProgressHandlerCommands: GhostboxDomainHandler {
    let resource = "progressHandler"

    func handle(
        method: GhostboxDirectMethod,
        parameters: [String: GhostboxJSONValue],
        session: GhostboxSession
    ) async throws -> GhostboxDirectValue {
        guard method.rawValue == "progressHandler.create" else { throw ghostboxUnsupportedImageMethod(method) }
        let decoded = try GhostboxParameters(parameters, allowed: ["progressHandler", "writer"])
        let writerReference = try decoded.requiredReference("writer", expectedKind: "writer")
        let writer: any Writer = try session.value(for: writerReference, expectedKind: "writer", as: (any Writer).self)
        let box = GhostboxProgressHandlerBox({ events in
            for event in events {
                try? writer.write(ghostboxProgressEventData(event))
            }
        }, writerReference: writerReference)
        let reference = try session.register(
            kind: "progress-handler",
            name: decoded.requiredString("progressHandler"),
            value: box,
            equivalent: { $0.writerReference == $1.writerReference }
        )
        return .reference(reference)
    }
}

private struct GhostboxImageDescriptionRecord: Sendable {
    let description: Containerization.Image.Description
    let provenance: String
}

struct GhostboxImageRecord: Sendable {
    let image: Containerization.Image
    let provenance: String
}

private struct GhostboxContentRecord: Sendable {
    let content: any Content
    let imageReference: String
    let requestedDigest: String
}

struct GhostboxImageStoreCommands: GhostboxDomainHandler {
    let resource = "imageStore"

    func handle(
        method: GhostboxDirectMethod,
        parameters: [String: GhostboxJSONValue],
        session: GhostboxSession
    ) async throws -> GhostboxDirectValue {
        switch method.rawValue {
        case "imageStore.create":
            let decoded = try GhostboxParameters(
                parameters,
                allowed: ["imageStore", "path", "contentStore"]
            )
            let name = try decoded.requiredString("imageStore")
            let path = try ghostboxHostURL(decoded.requiredString("path"), parameter: "path")
            let contentStore = try ghostboxContentStore(
                decoded.optionalReference("contentStore", expectedKind: "content-store"),
                session: session
            )
            let store = try ImageStore(path: path, contentStore: contentStore)
            let reference = try session.register(
                kind: "image-store",
                name: name,
                value: store,
                equivalent: { $0 === $1 }
            )
            return .reference(reference)

        case "imageStore.default":
            _ = try GhostboxParameters(parameters, allowed: [])
            guard let store = session.contextValue(ghostboxImageStoreContextKey, as: ImageStore.self) else {
                throw DirectDispatchError(.failedPrecondition, "per-VM image store is unavailable")
            }
            let reference = try session.register(
                kind: "image-store",
                name: "default",
                value: store,
                equivalent: { $0 === $1 }
            )
            return .reference(reference)

        case "imageStore.path":
            let decoded = try GhostboxParameters(parameters, allowed: ["imageStore"])
            let (_, store) = try ghostboxImageStore(decoded, session: session)
            return .string(store.path.path)

        case "imageStore.get":
            let decoded = try GhostboxParameters(
                parameters,
                allowed: ["imageStore", "reference", "pull"]
            )
            let (storeReference, store) = try ghostboxImageStore(decoded, session: session)
            let image = try await store.get(
                reference: decoded.requiredString("reference"),
                pull: try decoded.optionalBool("pull") ?? false
            )
            return try ghostboxRegisterImage(image, provenance: storeReference, session: session)

        case "imageStore.list":
            let decoded = try GhostboxParameters(parameters, allowed: ["imageStore"])
            let (storeReference, store) = try ghostboxImageStore(decoded, session: session)
            let images = try await store.list()
            let references = try images.map {
                try ghostboxRegisterImageReference($0, provenance: storeReference, session: session)
            }
            return .references(references)

        case "imageStore.createImage":
            let decoded = try GhostboxParameters(
                parameters,
                allowed: ["imageStore", "imageDescription"]
            )
            let (storeReference, store) = try ghostboxImageStore(decoded, session: session)
            let descriptionReference = try decoded.requiredReference(
                "imageDescription",
                expectedKind: "image-description"
            )
            let record: GhostboxImageDescriptionRecord = try session.value(
                for: descriptionReference,
                expectedKind: "image-description"
            )
            let image = try await store.create(description: record.description)
            return try ghostboxRegisterImage(image, provenance: storeReference, session: session)

        case "imageStore.delete":
            let decoded = try GhostboxParameters(
                parameters,
                allowed: ["imageStore", "reference", "performCleanup"]
            )
            let (_, store) = try ghostboxImageStore(decoded, session: session)
            try await store.delete(
                reference: decoded.requiredString("reference"),
                performCleanup: try decoded.optionalBool("performCleanup") ?? false
            )
            return .void

        case "imageStore.cleanUpOrphanedBlobs":
            let decoded = try GhostboxParameters(parameters, allowed: ["imageStore"])
            let (_, store) = try ghostboxImageStore(decoded, session: session)
            let result = try await store.cleanUpOrphanedBlobs()
            return .object([
                "deleted": .strings(result.deleted),
                "freed": .unsignedInteger(result.freed),
            ])

        case "imageStore.calculateOrphanedBlobsSize":
            let decoded = try GhostboxParameters(parameters, allowed: ["imageStore"])
            let (_, store) = try ghostboxImageStore(decoded, session: session)
            return .unsignedInteger(try await store.calculateOrphanedBlobsSize())

        case "imageStore.tag":
            let decoded = try GhostboxParameters(
                parameters,
                allowed: ["imageStore", "existingReference", "newReference"]
            )
            let (storeReference, store) = try ghostboxImageStore(decoded, session: session)
            let image = try await store.tag(
                existing: decoded.requiredString("existingReference"),
                new: decoded.requiredString("newReference")
            )
            return try ghostboxRegisterImage(image, provenance: storeReference, session: session)

        case "imageStore.pull":
            let decoded = try GhostboxParameters(
                parameters,
                allowed: [
                    "imageStore", "reference", "platform", "insecure", "authentication",
                    "progress", "maxConcurrentDownloads",
                ]
            )
            let (storeReference, store) = try ghostboxImageStore(decoded, session: session)
            let maxConcurrentDownloads = try decoded.optionalInt("maxConcurrentDownloads") ?? 3
            guard maxConcurrentDownloads > 0 else {
                throw DirectDispatchError(
                    .invalidArgument,
                    "parameter 'maxConcurrentDownloads' must be greater than zero"
                )
            }
            let image = try await store.pull(
                reference: decoded.requiredString("reference"),
                platform: try ghostboxOptionalPlatform(decoded, name: "platform"),
                insecure: try decoded.optionalBool("insecure") ?? false,
                auth: try ghostboxAuthentication(
                    decoded.optionalReference("authentication", expectedKind: "authentication"),
                    session: session
                ),
                progress: try ghostboxProgressHandler(
                    decoded.optionalReference("progress", expectedKind: "progress-handler"),
                    session: session
                ),
                maxConcurrentDownloads: maxConcurrentDownloads
            )
            return try ghostboxRegisterImage(image, provenance: storeReference, session: session)

        case "imageStore.push":
            let decoded = try GhostboxParameters(
                parameters,
                allowed: ["imageStore", "reference", "platform", "insecure", "authentication", "progress"]
            )
            let (_, store) = try ghostboxImageStore(decoded, session: session)
            try await store.push(
                reference: decoded.requiredString("reference"),
                platform: try ghostboxOptionalPlatform(decoded, name: "platform"),
                insecure: try decoded.optionalBool("insecure") ?? false,
                auth: try ghostboxAuthentication(
                    decoded.optionalReference("authentication", expectedKind: "authentication"),
                    session: session
                ),
                progress: try ghostboxProgressHandler(
                    decoded.optionalReference("progress", expectedKind: "progress-handler"),
                    session: session
                )
            )
            return .void

        case "imageStore.pushMany":
            let decoded = try GhostboxParameters(
                parameters,
                allowed: [
                    "imageStore", "reference", "platform", "insecure", "authentication",
                    "maxConcurrentUploads", "progress",
                ]
            )
            let (_, store) = try ghostboxImageStore(decoded, session: session)
            let references = try decoded.requiredStringArray("reference")
            guard !references.isEmpty else {
                throw DirectDispatchError(.invalidArgument, "parameter 'reference' must not be empty")
            }
            let maxConcurrentUploads = try decoded.optionalInt("maxConcurrentUploads") ?? 3
            guard maxConcurrentUploads > 0 else {
                throw DirectDispatchError(
                    .invalidArgument,
                    "parameter 'maxConcurrentUploads' must be greater than zero"
                )
            }
            try await store.push(
                references: references,
                platform: try ghostboxOptionalPlatform(decoded, name: "platform"),
                insecure: try decoded.optionalBool("insecure") ?? false,
                auth: try ghostboxAuthentication(
                    decoded.optionalReference("authentication", expectedKind: "authentication"),
                    session: session
                ),
                maxConcurrentUploads: maxConcurrentUploads,
                progress: try ghostboxProgressHandler(
                    decoded.optionalReference("progress", expectedKind: "progress-handler"),
                    session: session
                )
            )
            return .void

        case "imageStore.save":
            let decoded = try GhostboxParameters(
                parameters,
                allowed: ["imageStore", "reference", "out", "platform"]
            )
            let (_, store) = try ghostboxImageStore(decoded, session: session)
            let references = try decoded.requiredStringArray("reference")
            guard !references.isEmpty else {
                throw DirectDispatchError(.invalidArgument, "parameter 'reference' must not be empty")
            }
            try await store.save(
                references: references,
                out: try ghostboxHostURL(decoded.requiredString("out"), parameter: "out"),
                platform: try ghostboxOptionalPlatform(decoded, name: "platform")
            )
            return .void

        case "imageStore.load":
            let decoded = try GhostboxParameters(
                parameters,
                allowed: ["imageStore", "directory", "progress"]
            )
            let (storeReference, store) = try ghostboxImageStore(decoded, session: session)
            let images = try await store.load(
                from: ghostboxHostURL(decoded.requiredString("directory"), parameter: "directory"),
                progress: ghostboxProgressHandler(
                    decoded.optionalReference("progress", expectedKind: "progress-handler"),
                    session: session
                )
            )
            let references = try images.map {
                try ghostboxRegisterImageReference($0, provenance: storeReference, session: session)
            }
            return .references(references)

        case "imageStore.getInitImage":
            let decoded = try GhostboxParameters(
                parameters,
                allowed: ["imageStore", "reference", "authentication", "progress"]
            )
            let (storeReference, store) = try ghostboxImageStore(decoded, session: session)
            let imageReference = try decoded.requiredString("reference")
            let image = try await store.getInitImage(
                reference: imageReference,
                auth: ghostboxAuthentication(
                    decoded.optionalReference("authentication", expectedKind: "authentication"),
                    session: session
                ),
                progress: ghostboxProgressHandler(
                    decoded.optionalReference("progress", expectedKind: "progress-handler"),
                    session: session
                )
            )
            let name = ghostboxStableName(["init-image", storeReference, imageReference])
            let reference = try session.register(
                kind: "init-image",
                name: name,
                value: image,
                equivalent: { $0.name == $1.name }
            )
            return .reference(reference)

        default:
            throw ghostboxUnsupportedImageMethod(method)
        }
    }
}

struct GhostboxImageDescriptionCommands: GhostboxDomainHandler {
    let resource = "imageDescription"

    func handle(
        method: GhostboxDirectMethod,
        parameters: [String: GhostboxJSONValue],
        session: GhostboxSession
    ) async throws -> GhostboxDirectValue {
        switch method.rawValue {
        case "imageDescription.create":
            let decoded = try GhostboxParameters(
                parameters,
                allowed: ["imageDescription", "reference", "descriptor"]
            )
            let description = Containerization.Image.Description(
                reference: try decoded.requiredString("reference"),
                descriptor: try ghostboxDescriptor(decoded, name: "descriptor")
            )
            let record = GhostboxImageDescriptionRecord(
                description: description,
                provenance: "created"
            )
            let reference = try session.register(
                kind: "image-description",
                name: decoded.requiredString("imageDescription"),
                value: record,
                equivalent: ghostboxImageDescriptionRecordsEqual
            )
            return .reference(reference)

        case "imageDescription.reference",
             "imageDescription.descriptor",
             "imageDescription.digest",
             "imageDescription.mediaType":
            let decoded = try GhostboxParameters(parameters, allowed: ["imageDescription"])
            let reference = try decoded.requiredReference("imageDescription", expectedKind: "image-description")
            let record: GhostboxImageDescriptionRecord = try session.value(
                for: reference,
                expectedKind: "image-description"
            )
            switch method.rawValue {
            case "imageDescription.reference":
                return .string(record.description.reference)
            case "imageDescription.descriptor":
                return try ghostboxCodableValue(record.description.descriptor)
            case "imageDescription.digest":
                return .string(record.description.digest)
            default:
                return .string(record.description.mediaType)
            }

        default:
            throw ghostboxUnsupportedImageMethod(method)
        }
    }
}

struct GhostboxImageCommands: GhostboxDomainHandler {
    let resource = "image"

    func handle(
        method: GhostboxDirectMethod,
        parameters: [String: GhostboxJSONValue],
        session: GhostboxSession
    ) async throws -> GhostboxDirectValue {
        switch method.rawValue {
        case "image.create":
            let decoded = try GhostboxParameters(
                parameters,
                allowed: ["image", "imageDescription", "contentStore"]
            )
            let descriptionReference = try decoded.requiredReference(
                "imageDescription",
                expectedKind: "image-description"
            )
            let description: GhostboxImageDescriptionRecord = try session.value(
                for: descriptionReference,
                expectedKind: "image-description"
            )
            let contentStoreReference = try decoded.requiredReference("contentStore", expectedKind: "content-store")
            let contentStore: any ContentStore = try session.value(
                for: contentStoreReference,
                expectedKind: "content-store",
                as: (any ContentStore).self
            )
            let record = GhostboxImageRecord(
                image: Containerization.Image(description: description.description, contentStore: contentStore),
                provenance: contentStoreReference
            )
            let reference = try session.register(
                kind: "image",
                name: decoded.requiredString("image"),
                value: record,
                equivalent: ghostboxImageRecordsEqual
            )
            return .reference(reference)

        case "image.description":
            let decoded = try GhostboxParameters(parameters, allowed: ["image"])
            let (imageReference, record) = try ghostboxImage(decoded, session: session)
            let descriptionRecord = GhostboxImageDescriptionRecord(
                description: record.image.description,
                provenance: imageReference
            )
            let name = ghostboxStableName([
                "image-description", imageReference, record.image.reference, record.image.digest,
            ])
            _ = try session.register(
                kind: "image-description",
                name: name,
                value: descriptionRecord,
                equivalent: ghostboxImageDescriptionRecordsEqual
            )
            return .object([
                "reference": .string(record.image.description.reference),
                "descriptor": try ghostboxCodableValue(record.image.description.descriptor),
            ])

        case "image.descriptor",
             "image.digest",
             "image.mediaType",
             "image.reference",
             "image.index",
             "image.referencedDigests":
            let decoded = try GhostboxParameters(parameters, allowed: ["image"])
            let (_, record) = try ghostboxImage(decoded, session: session)
            switch method.rawValue {
            case "image.descriptor":
                return try ghostboxCodableValue(record.image.descriptor)
            case "image.digest":
                return .string(record.image.digest)
            case "image.mediaType":
                return .string(record.image.mediaType)
            case "image.reference":
                return .string(record.image.reference)
            case "image.index":
                return try await ghostboxCodableValue(record.image.index())
            default:
                return .strings(try await record.image.referencedDigests())
            }

        case "image.manifest":
            let decoded = try GhostboxParameters(parameters, allowed: ["image", "platform"])
            let (_, record) = try ghostboxImage(decoded, session: session)
            return try await ghostboxCodableValue(
                record.image.manifest(for: ghostboxPlatform(decoded, name: "platform"))
            )

        case "image.descriptorFor":
            let decoded = try GhostboxParameters(parameters, allowed: ["image", "platform"])
            let (_, record) = try ghostboxImage(decoded, session: session)
            return try await ghostboxCodableValue(
                record.image.descriptor(for: ghostboxPlatform(decoded, name: "platform"))
            )

        case "image.config":
            let decoded = try GhostboxParameters(parameters, allowed: ["image", "platform"])
            let (_, record) = try ghostboxImage(decoded, session: session)
            return try await ghostboxCodableValue(
                record.image.config(for: ghostboxPlatform(decoded, name: "platform"))
            )

        case "image.getContent":
            let decoded = try GhostboxParameters(parameters, allowed: ["image", "digest"])
            let (imageReference, record) = try ghostboxImage(decoded, session: session)
            let digest = try decoded.requiredString("digest")
            let content = try await record.image.getContent(digest: digest)
            let contentRecord = GhostboxContentRecord(
                content: content,
                imageReference: imageReference,
                requestedDigest: digest
            )
            let name = ghostboxStableName(["content", imageReference, digest])
            let reference = try session.register(
                kind: "content",
                name: name,
                value: contentRecord,
                equivalent: ghostboxContentRecordsEqual
            )
            return .reference(reference)

        default:
            throw ghostboxUnsupportedImageMethod(method)
        }
    }
}

struct GhostboxContentCommands: GhostboxDomainHandler {
    let resource = "content"

    func handle(
        method: GhostboxDirectMethod,
        parameters: [String: GhostboxJSONValue],
        session: GhostboxSession
    ) async throws -> GhostboxDirectValue {
        switch method.rawValue {
        case "content.path",
             "content.digest",
             "content.size",
             "content.data":
            let decoded = try GhostboxParameters(parameters, allowed: ["content"])
            let record = try ghostboxContent(decoded, session: session)
            switch method.rawValue {
            case "content.path":
                return .string(record.content.path.path)
            case "content.digest":
                return .string(try record.content.digest().digestString)
            case "content.size":
                return .unsignedInteger(try record.content.size())
            default:
                let size = try record.content.size()
                try ghostboxCheckBytePayload(size)
                let data = try record.content.data()
                try ghostboxCheckBytePayload(data.count)
                return .bytes(data)
            }

        case "content.dataRange":
            let decoded = try GhostboxParameters(
                parameters,
                allowed: ["content", "offset", "length"]
            )
            let record = try ghostboxContent(decoded, session: session)
            let offset = try decoded.requiredUInt64("offset")
            let length = try decoded.requiredInt("length")
            guard length >= 0 else {
                throw DirectDispatchError(.invalidArgument, "parameter 'length' must not be negative")
            }
            let readLength: Int
            if length == 0 {
                let size = try record.content.size()
                let remaining = offset < size ? size - offset : 0
                try ghostboxCheckBytePayload(remaining)
                guard let boundedLength = Int(exactly: remaining) else {
                    throw DirectDispatchError(.resourceExhausted, "content range is too large")
                }
                readLength = boundedLength
            } else {
                try ghostboxCheckBytePayload(length)
                readLength = length
            }
            if readLength == 0 {
                return .bytes(Data())
            }
            guard let data = try record.content.data(offset: offset, length: readLength) else {
                return .null
            }
            try ghostboxCheckBytePayload(data.count)
            return .bytes(data)

        default:
            throw ghostboxUnsupportedImageMethod(method)
        }
    }
}

private func ghostboxImageStore(
    _ parameters: GhostboxParameters,
    session: GhostboxSession
) throws -> (String, ImageStore) {
    let reference = try parameters.requiredReference("imageStore", expectedKind: "image-store")
    let store: ImageStore = try session.value(for: reference, expectedKind: "image-store")
    return (reference, store)
}

private func ghostboxImage(
    _ parameters: GhostboxParameters,
    session: GhostboxSession
) throws -> (String, GhostboxImageRecord) {
    let reference = try parameters.requiredReference("image", expectedKind: "image")
    let record: GhostboxImageRecord = try session.value(for: reference, expectedKind: "image")
    return (reference, record)
}

private func ghostboxContent(
    _ parameters: GhostboxParameters,
    session: GhostboxSession
) throws -> GhostboxContentRecord {
    let reference = try parameters.requiredReference("content", expectedKind: "content")
    return try session.value(for: reference, expectedKind: "content")
}

private func ghostboxContentStore(
    _ reference: String?,
    session: GhostboxSession
) throws -> (any ContentStore)? {
    guard let reference else { return nil }
    let store: any ContentStore = try session.value(
        for: reference,
        expectedKind: "content-store",
        as: (any ContentStore).self
    )
    return store
}

private func ghostboxAuthentication(
    _ reference: String?,
    session: GhostboxSession
) throws -> (any Authentication)? {
    guard let reference else { return nil }
    let authentication: GhostboxAuthenticationRecord = try session.value(
        for: reference,
        expectedKind: "authentication"
    )
    return authentication.value
}

func ghostboxProgressHandler(
    _ reference: String?,
    session: GhostboxSession
) throws -> ProgressHandler? {
    guard let reference else { return nil }
    let box: GhostboxProgressHandlerBox = try session.value(
        for: reference,
        expectedKind: "progress-handler"
    )
    return box.handler
}

private func ghostboxProgressEventData(_ event: ProgressEvent) -> Data {
    let value: Int64
    switch event {
    case .addItems(let count), .addTotalItems(let count): value = Int64(count)
    case .addSize(let bytes), .addTotalSize(let bytes): value = bytes
    }
    let object = GhostboxJSONValue.object([
        "event": .string(event.event),
        "value": value >= 0 ? .unsignedInteger(UInt64(value)) : .integer(value),
    ])
    var data = (try? JSONEncoder().encode(object)) ?? Data()
    data.append(0x0a)
    return data
}

func ghostboxImageValue(_ reference: String, session: GhostboxSession) throws -> Containerization.Image {
    let canonical = try GhostboxReference.canonical(reference, expectedKind: "image")
    let record: GhostboxImageRecord = try session.value(for: canonical, expectedKind: "image")
    return record.image
}

private func ghostboxRegisterImage(
    _ image: Containerization.Image,
    provenance: String,
    session: GhostboxSession
) throws -> GhostboxDirectValue {
    .reference(try ghostboxRegisterImageReference(image, provenance: provenance, session: session))
}

private func ghostboxRegisterImageReference(
    _ image: Containerization.Image,
    provenance: String,
    session: GhostboxSession
) throws -> String {
    let record = GhostboxImageRecord(image: image, provenance: provenance)
    let name = ghostboxStableName(["image", provenance, image.reference, image.digest])
    return try session.register(
        kind: "image",
        name: name,
        value: record,
        equivalent: ghostboxImageRecordsEqual
    )
}

private func ghostboxImageDescriptionRecordsEqual(
    _ lhs: GhostboxImageDescriptionRecord,
    _ rhs: GhostboxImageDescriptionRecord
) -> Bool {
    lhs.provenance == rhs.provenance
        && lhs.description.reference == rhs.description.reference
        && lhs.description.descriptor == rhs.description.descriptor
}

private func ghostboxImageRecordsEqual(_ lhs: GhostboxImageRecord, _ rhs: GhostboxImageRecord) -> Bool {
    lhs.provenance == rhs.provenance
        && lhs.image.reference == rhs.image.reference
        && lhs.image.descriptor == rhs.image.descriptor
}

private func ghostboxContentRecordsEqual(_ lhs: GhostboxContentRecord, _ rhs: GhostboxContentRecord) -> Bool {
    lhs.imageReference == rhs.imageReference
        && lhs.requestedDigest == rhs.requestedDigest
        && lhs.content.path.standardizedFileURL == rhs.content.path.standardizedFileURL
}

private func ghostboxDescriptor(
    _ parameters: GhostboxParameters,
    name: String
) throws -> Descriptor {
    guard let value = parameters.optionalValue(name) else {
        throw DirectDispatchError(.invalidArgument, "missing required parameter '\(name)'")
    }
    if case .object(let object) = value {
        return try ghostboxDecode(Descriptor.self, from: .object(object), parameter: name)
    }
    guard case .string(let raw) = value else {
        throw DirectDispatchError(.invalidArgument, "parameter '\(name)' must be a JSON string or object")
    }
    do {
        return try JSONDecoder().decode(Descriptor.self, from: Data(raw.utf8))
    } catch {
        throw DirectDispatchError(.invalidArgument, "parameter '\(name)' is not a valid OCI descriptor: \(error.localizedDescription)")
    }
}

func ghostboxOptionalPlatform(
    _ parameters: GhostboxParameters,
    name: String
) throws -> Platform? {
    guard let value = parameters.optionalValue(name) else { return nil }
    if case .object(let object) = value {
        return try ghostboxDecode(Platform.self, from: .object(object), parameter: name)
    }
    guard case .string(let raw) = value else {
        throw DirectDispatchError(.invalidArgument, "parameter '\(name)' must be a platform string or object")
    }
    do {
        if raw.first == "{" {
            return try JSONDecoder().decode(Platform.self, from: Data(raw.utf8))
        }
        return try Platform(from: raw)
    } catch {
        throw DirectDispatchError(.invalidArgument, "parameter '\(name)' is not a valid OCI platform: \(error.localizedDescription)")
    }
}

private func ghostboxPlatform(
    _ parameters: GhostboxParameters,
    name: String
) throws -> Platform {
    guard let platform = try ghostboxOptionalPlatform(parameters, name: name) else {
        throw DirectDispatchError(.invalidArgument, "missing required parameter '\(name)'")
    }
    return platform
}

private func ghostboxDecode<Value: Decodable>(
    _ type: Value.Type,
    from value: GhostboxJSONValue,
    parameter: String
) throws -> Value {
    do {
        return try JSONDecoder().decode(type, from: JSONEncoder().encode(value))
    } catch {
        throw DirectDispatchError(.invalidArgument, "parameter '\(parameter)' is invalid: \(error.localizedDescription)")
    }
}

private func ghostboxCodableValue<Value: Encodable>(_ value: Value) throws -> GhostboxDirectValue {
    let data = try JSONEncoder().encode(value)
    let json = try JSONDecoder().decode(GhostboxJSONValue.self, from: data)
    return ghostboxDirectValue(json)
}

private func ghostboxDirectValue(_ value: GhostboxJSONValue) -> GhostboxDirectValue {
    switch value {
    case .null:
        return .null
    case .boolean(let value):
        return .boolean(value)
    case .string(let value):
        return .string(value)
    case .integer(let value):
        return .integer(value)
    case .unsignedInteger(let value):
        return .unsignedInteger(value)
    case .array(let values):
        return .array(values.map(ghostboxDirectValue))
    case .object(let values):
        return .object(values.mapValues(ghostboxDirectValue))
    }
}

private func ghostboxHostURL(_ value: String, parameter: String) throws -> URL {
    if value.hasPrefix("file://") {
        guard let url = URL(string: value), url.isFileURL else {
            throw DirectDispatchError(.invalidArgument, "parameter '\(parameter)' must be a file URL or path")
        }
        return url
    }
    return URL(fileURLWithPath: value)
}

private func ghostboxCheckBytePayload<T: BinaryInteger>(_ count: T) throws {
    guard count <= T(GhostboxDirectLimits.bytePayloadBytes) else {
        throw DirectDispatchError(
            .resourceExhausted,
            "content payload exceeds the \(GhostboxDirectLimits.bytePayloadBytes)-byte direct transport limit"
        )
    }
}

private func ghostboxStableName(_ components: [String]) -> String {
    var hash: UInt64 = 0xcbf29ce484222325
    for component in components {
        for byte in component.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        hash ^= 0xff
        hash &*= 0x100000001b3
    }
    return String(hash, radix: 16)
}

private func ghostboxUnsupportedImageMethod(_ method: GhostboxDirectMethod) -> DirectDispatchError {
    DirectDispatchError(.unsupported, "unsupported direct method '\(method.rawValue)'")
}
