import Containerization
import ContainerAPIService
import ContainerPersistence
import ContainerPlugin
import ContainerizationOCI
import Foundation
import GhostVMKit
import Logging

struct GhostboxKernelCommandLineCommands: GhostboxDomainHandler {
    let resource = "kernelCommandLine"

    func handle(
        method: GhostboxDirectMethod,
        parameters: [String: GhostboxJSONValue],
        session: GhostboxSession
    ) async throws -> GhostboxDirectValue {
        switch method.rawValue {
        case "kernelCommandLine.create":
            let decoded = try GhostboxParameters(
                parameters,
                allowed: ["commandLine", "kernelArgument", "initArgument"]
            )
            let commandLine = Kernel.CommandLine(
                kernelArgs: try decoded.optionalStringArray("kernelArgument") ?? Kernel.CommandLine.kernelDefaults,
                initArgs: try decoded.optionalStringArray("initArgument") ?? []
            )
            let reference = try session.registerMutable(
                kind: "kernel-command-line",
                name: try decoded.requiredString("commandLine"),
                value: commandLine,
                equivalent: ghostboxCommandLinesEqual
            )
            return .reference(reference)

        case "kernelCommandLine.createDebug":
            let decoded = try GhostboxParameters(
                parameters,
                allowed: ["commandLine", "debug", "panic", "initArgument"]
            )
            let commandLine = Kernel.CommandLine(
                debug: try decoded.requiredBool("debug"),
                panic: try decoded.requiredInt("panic"),
                initArgs: try decoded.optionalStringArray("initArgument") ?? []
            )
            let reference = try session.registerMutable(
                kind: "kernel-command-line",
                name: try decoded.requiredString("commandLine"),
                value: commandLine,
                equivalent: ghostboxCommandLinesEqual
            )
            return .reference(reference)

        case "kernelCommandLine.addDebug":
            let decoded = try GhostboxParameters(parameters, allowed: ["kernelCommandLine"])
            let reference = try decoded.requiredReference("kernelCommandLine", expectedKind: "kernel-command-line")
            try session.updateValue(for: reference, expectedKind: "kernel-command-line", as: Kernel.CommandLine.self) {
                $0.addDebug()
            }
            return .void

        case "kernelCommandLine.addPanic":
            let decoded = try GhostboxParameters(parameters, allowed: ["kernelCommandLine", "level"])
            let reference = try decoded.requiredReference("kernelCommandLine", expectedKind: "kernel-command-line")
            let level = try decoded.requiredInt("level")
            try session.updateValue(for: reference, expectedKind: "kernel-command-line", as: Kernel.CommandLine.self) {
                $0.addPanic(level: level)
            }
            return .void

        case "kernelCommandLine.setAgentLogLevel":
            let decoded = try GhostboxParameters(parameters, allowed: ["kernelCommandLine", "level"])
            let reference = try decoded.requiredReference("kernelCommandLine", expectedKind: "kernel-command-line")
            let rawLevel = try decoded.requiredString("level")
            guard let level = Logger.Level(rawValue: rawLevel.lowercased()) else {
                throw DirectDispatchError(.invalidArgument, "unknown logger level '\(rawLevel)'")
            }
            try session.updateValue(for: reference, expectedKind: "kernel-command-line", as: Kernel.CommandLine.self) {
                $0.setAgentLogLevel(level: level)
            }
            return .void

        case "kernelCommandLine.kernelArguments", "kernelCommandLine.initArguments":
            let decoded = try GhostboxParameters(parameters, allowed: ["kernelCommandLine"])
            let reference = try decoded.requiredReference("kernelCommandLine", expectedKind: "kernel-command-line")
            let commandLine: Kernel.CommandLine = try session.valueSnapshot(
                for: reference,
                expectedKind: "kernel-command-line"
            )
            if method.rawValue == "kernelCommandLine.kernelArguments" {
                return .strings(commandLine.kernelArgs)
            }
            return .strings(commandLine.initArgs)

        default:
            throw ghostboxUnsupportedBootMethod(method)
        }
    }
}

struct GhostboxKernelCommands: GhostboxDomainHandler {
    let resource = "kernel"

    func handle(
        method: GhostboxDirectMethod,
        parameters: [String: GhostboxJSONValue],
        session: GhostboxSession
    ) async throws -> GhostboxDirectValue {
        switch method.rawValue {
        case "kernel.installRecommended":
            _ = try GhostboxParameters(parameters, allowed: [])
            let configuration = try await ConfigurationLoader.load(configurationFiles: [
                ConfigurationLoader.configurationFile(.appRoot)
            ])
            let service = try ghostboxKernelService()
            let recommendedName = URL(filePath: configuration.kernel.binaryPath).lastPathComponent
            if let kernel = try? await service.getDefaultKernel(platform: .linuxArm),
               kernel.path.lastPathComponent == recommendedName {
                return try ghostboxRegisterDefaultKernel(kernel, session: session)
            }
            try await service.installKernelFrom(
                tar: configuration.kernel.url,
                kernelFilePath: configuration.kernel.binaryPath,
                platform: .linuxArm,
                progressUpdate: nil,
                expectedDigest: configuration.kernel.digest,
                force: true
            )
            return try ghostboxRegisterDefaultKernel(
                try await service.getDefaultKernel(platform: .linuxArm),
                session: session
            )

        case "kernel.default":
            _ = try GhostboxParameters(parameters, allowed: [])
            let service = try ghostboxKernelService()
            let kernel = try await service.getDefaultKernel(platform: .linuxArm)
            return try ghostboxRegisterDefaultKernel(kernel, session: session)

        case "kernel.create":
            let decoded = try GhostboxParameters(
                parameters,
                allowed: ["kernel", "path", "platform", "commandLine"]
            )
            let commandLine: Kernel.CommandLine
            if let reference = try decoded.optionalReference("commandLine", expectedKind: "kernel-command-line") {
                commandLine = try session.valueSnapshot(for: reference, expectedKind: "kernel-command-line")
            } else {
                commandLine = Kernel.CommandLine(debug: false, panic: 0)
            }
            let kernel = Kernel(
                path: try ghostboxURL(decoded.requiredString("path"), parameter: "path"),
                platform: try ghostboxSystemPlatform(parameters, "platform"),
                commandline: commandLine
            )
            let reference = try session.register(
                kind: "kernel",
                name: try decoded.requiredString("kernel"),
                value: kernel,
                equivalent: ghostboxKernelsEqual
            )
            return .reference(reference)

        case "kernel.path", "kernel.platform", "kernel.kernelArguments", "kernel.initArguments":
            let decoded = try GhostboxParameters(parameters, allowed: ["kernel"])
            let reference = try decoded.requiredReference("kernel", expectedKind: "kernel")
            let kernel: Kernel = try session.value(for: reference, expectedKind: "kernel")
            switch method.rawValue {
            case "kernel.path": return .string(kernel.path.absoluteString)
            case "kernel.platform": return ghostboxSystemPlatformValue(kernel.platform)
            case "kernel.kernelArguments": return .strings(kernel.kernelArgs)
            default: return .strings(kernel.initArgs)
            }

        default:
            throw ghostboxUnsupportedBootMethod(method)
        }
    }
}

private func ghostboxKernelService() throws -> KernelService {
    try KernelService(
        log: Logger(label: "org.ghostvm.ghostbox.kernel"),
        appRoot: URL(filePath: ApplicationRoot.pathname)
    )
}

private func ghostboxRegisterDefaultKernel(
    _ kernel: Kernel,
    session: GhostboxSession
) throws -> GhostboxDirectValue {
    .reference(try session.register(
        kind: "kernel",
        name: "default",
        value: kernel,
        equivalent: ghostboxKernelsEqual
    ))
}

struct GhostboxKernelImageCommands: GhostboxDomainHandler {
    let resource = "kernelImage"

    func handle(
        method: GhostboxDirectMethod,
        parameters: [String: GhostboxJSONValue],
        session: GhostboxSession
    ) async throws -> GhostboxDirectValue {
        switch method.rawValue {
        case "kernelImage.fromImage":
            let decoded = try GhostboxParameters(parameters, allowed: ["kernelImage", "image"])
            let imageReference = try decoded.requiredReference("image", expectedKind: "image")
            let image = try ghostboxImageValue(imageReference, session: session)
            return try ghostboxRegisterKernelImage(
                KernelImage(image: image),
                name: decoded.requiredString("kernelImage"),
                session: session
            )

        case "kernelImage.create":
            let decoded = try GhostboxParameters(
                parameters,
                allowed: ["kernelImage", "reference", "kernel", "label", "imageStore", "contentStore"]
            )
            let kernels: [Kernel] = try decoded.requiredReferences("kernel", expectedKind: "kernel").map {
                try session.value(for: $0, expectedKind: "kernel")
            }
            let imageStoreReference = try decoded.requiredReference("imageStore", expectedKind: "image-store")
            let imageStore: ImageStore = try session.value(for: imageStoreReference, expectedKind: "image-store")
            let contentStoreReference = try decoded.requiredReference("contentStore", expectedKind: "content-store")
            let contentStore: any ContentStore = try session.value(
                for: contentStoreReference,
                expectedKind: "content-store",
                as: (any ContentStore).self
            )
            let image = try await KernelImage.create(
                reference: decoded.requiredString("reference"),
                binaries: kernels,
                labels: try ghostboxLabels(decoded.optionalStringArray("label") ?? []),
                imageStore: imageStore,
                contentStore: contentStore
            )
            return try ghostboxRegisterKernelImage(
                image,
                name: decoded.requiredString("kernelImage"),
                session: session
            )

        case "kernelImage.kernel":
            let decoded = try GhostboxParameters(parameters, allowed: ["kernelImage", "platform"])
            let reference = try decoded.requiredReference("kernelImage", expectedKind: "kernel-image")
            let image: KernelImage = try session.value(for: reference, expectedKind: "kernel-image")
            let platform = try ghostboxSystemPlatform(parameters, "platform")
            let kernel = try await image.kernel(for: platform)
            let name = ghostboxDerivedName(
                reference: reference,
                operation: "kernel",
                discriminator: "\(platform.os.rawValue)/\(platform.architecture.rawValue)"
            )
            let kernelReference = try session.register(
                kind: "kernel",
                name: name,
                value: kernel,
                equivalent: ghostboxKernelsEqual
            )
            return .reference(kernelReference)

        case "kernelImage.name":
            let decoded = try GhostboxParameters(parameters, allowed: ["kernelImage"])
            let reference = try decoded.requiredReference("kernelImage", expectedKind: "kernel-image")
            let image: KernelImage = try session.value(for: reference, expectedKind: "kernel-image")
            return .string(image.name)

        case "kernelImage.mediaType":
            _ = try GhostboxParameters(parameters, allowed: [])
            return .string(KernelImage.mediaType)

        default:
            throw ghostboxUnsupportedBootMethod(method)
        }
    }
}

struct GhostboxInitImageCommands: GhostboxDomainHandler {
    let resource = "initImage"

    func handle(
        method: GhostboxDirectMethod,
        parameters: [String: GhostboxJSONValue],
        session: GhostboxSession
    ) async throws -> GhostboxDirectValue {
        switch method.rawValue {
        case "initImage.fromImage":
            let decoded = try GhostboxParameters(parameters, allowed: ["initImage", "image"])
            let imageReference = try decoded.requiredReference("image", expectedKind: "image")
            let image = try ghostboxImageValue(imageReference, session: session)
            return try ghostboxRegisterInitImage(
                InitImage(image: image),
                name: decoded.requiredString("initImage"),
                session: session
            )

        case "initImage.create":
            let decoded = try GhostboxParameters(
                parameters,
                allowed: ["initImage", "reference", "rootfs", "platform", "label", "imageStore", "contentStore"]
            )
            let imageStoreReference = try decoded.requiredReference("imageStore", expectedKind: "image-store")
            let imageStore: ImageStore = try session.value(for: imageStoreReference, expectedKind: "image-store")
            let contentStoreReference = try decoded.requiredReference("contentStore", expectedKind: "content-store")
            let contentStore: any ContentStore = try session.value(
                for: contentStoreReference,
                expectedKind: "content-store",
                as: (any ContentStore).self
            )
            let image = try await InitImage.create(
                reference: decoded.requiredString("reference"),
                rootfs: try ghostboxURL(decoded.requiredString("rootfs"), parameter: "rootfs"),
                platform: try ghostboxOCIPlatform(parameters, "platform"),
                labels: try ghostboxLabels(decoded.optionalStringArray("label") ?? []),
                imageStore: imageStore,
                contentStore: contentStore
            )
            return try ghostboxRegisterInitImage(
                image,
                name: decoded.requiredString("initImage"),
                session: session
            )

        case "initImage.initBlock":
            let decoded = try GhostboxParameters(parameters, allowed: ["initImage", "at", "platform"])
            let reference = try decoded.requiredReference("initImage", expectedKind: "init-image")
            let image: InitImage = try session.value(for: reference, expectedKind: "init-image")
            let platform = try ghostboxSystemPlatform(parameters, "platform")
            let destination = try decoded.requiredString("at")
            let mount = try await image.initBlock(
                at: try ghostboxURL(destination, parameter: "at"),
                for: platform
            )
            let name = ghostboxDerivedName(
                reference: reference,
                operation: "init-block",
                discriminator: "\(destination)|\(platform.os.rawValue)/\(platform.architecture.rawValue)"
            )
            let mountReference = try session.register(
                kind: "mount",
                name: name,
                value: mount,
                equivalent: ghostboxMountsEqual
            )
            return .reference(mountReference)

        case "initImage.name":
            let decoded = try GhostboxParameters(parameters, allowed: ["initImage"])
            let reference = try decoded.requiredReference("initImage", expectedKind: "init-image")
            let image: InitImage = try session.value(for: reference, expectedKind: "init-image")
            return .string(image.name)

        default:
            throw ghostboxUnsupportedBootMethod(method)
        }
    }
}

struct GhostboxMountCommands: GhostboxDomainHandler {
    let resource = "mount"

    func handle(
        method: GhostboxDirectMethod,
        parameters: [String: GhostboxJSONValue],
        session: GhostboxSession
    ) async throws -> GhostboxDirectValue {
        switch method.rawValue {
        case "mount.create":
            let decoded = try GhostboxParameters(
                parameters,
                allowed: ["mount", "type", "source", "destination", "option", "runtimeOptions"]
            )
            let mount = Containerization.Mount(
                type: try decoded.requiredString("type"),
                source: try decoded.requiredString("source"),
                destination: try decoded.requiredString("destination"),
                options: try decoded.requiredStringArray("option"),
                runtimeOptions: try ghostboxMountRuntimeOptions(parameters, "runtimeOptions")
            )
            return try ghostboxRegisterMount(
                mount,
                name: decoded.requiredString("mount"),
                session: session
            )

        case "mount.block":
            let decoded = try GhostboxParameters(
                parameters,
                allowed: ["mount", "format", "source", "destination", "option", "runtimeOption"]
            )
            return try ghostboxRegisterMount(
                Containerization.Mount.block(
                    format: decoded.requiredString("format"),
                    source: decoded.requiredString("source"),
                    destination: decoded.requiredString("destination"),
                    options: try decoded.optionalStringArray("option") ?? [],
                    runtimeOptions: try decoded.optionalStringArray("runtimeOption") ?? []
                ),
                name: decoded.requiredString("mount"),
                session: session
            )

        case "mount.share":
            let decoded = try GhostboxParameters(
                parameters,
                allowed: ["mount", "source", "destination", "option", "runtimeOption"]
            )
            return try ghostboxRegisterMount(
                Containerization.Mount.share(
                    source: decoded.requiredString("source"),
                    destination: decoded.requiredString("destination"),
                    options: try decoded.optionalStringArray("option") ?? [],
                    runtimeOptions: try decoded.optionalStringArray("runtimeOption") ?? []
                ),
                name: decoded.requiredString("mount"),
                session: session
            )

        case "mount.any":
            let decoded = try GhostboxParameters(
                parameters,
                allowed: ["mount", "type", "source", "destination", "option", "runtimeOption"]
            )
            return try ghostboxRegisterMount(
                Containerization.Mount.any(
                    type: decoded.requiredString("type"),
                    source: decoded.requiredString("source"),
                    destination: decoded.requiredString("destination"),
                    options: try decoded.optionalStringArray("option") ?? [],
                    runtimeOptions: try decoded.optionalStringArray("runtimeOption") ?? []
                ),
                name: decoded.requiredString("mount"),
                session: session
            )

        case "mount.sharedMount":
            let decoded = try GhostboxParameters(
                parameters,
                allowed: ["mount", "name", "destination", "option"]
            )
            return try ghostboxRegisterMount(
                Containerization.Mount.sharedMount(
                    name: decoded.requiredString("name"),
                    destination: decoded.requiredString("destination"),
                    options: try decoded.optionalStringArray("option") ?? []
                ),
                name: decoded.requiredString("mount"),
                session: session
            )

        case "mount.clone":
            let decoded = try GhostboxParameters(parameters, allowed: ["mount", "to"])
            let reference = try decoded.requiredReference("mount", expectedKind: "mount")
            let mount: Containerization.Mount = try session.value(for: reference, expectedKind: "mount")
            let destination = try decoded.requiredString("to")
            let clone = try mount.clone(to: destination)
            let name = ghostboxDerivedName(
                reference: reference,
                operation: "clone",
                discriminator: destination
            )
            return try ghostboxRegisterMount(clone, name: name, session: session)

        case GhostboxDirectMethod.mountDelete.rawValue:
            let decoded = try GhostboxParameters(parameters, allowed: ["mount"])
            let reference = try decoded.requiredReference("mount", expectedKind: "mount")
            let mount: Containerization.Mount = try session.value(for: reference, expectedKind: "mount")
            try await session.unregisterAndCleanup(reference, expectedKind: "mount", matching: mount)
            return .void

        case "mount.isBlock", "mount.type", "mount.source", "mount.destination", "mount.options", "mount.runtimeOptions":
            let decoded = try GhostboxParameters(parameters, allowed: ["mount"])
            let reference = try decoded.requiredReference("mount", expectedKind: "mount")
            let mount: Containerization.Mount = try session.value(for: reference, expectedKind: "mount")
            switch method.rawValue {
            case "mount.isBlock": return .boolean(mount.isBlock)
            case "mount.type": return .string(mount.type)
            case "mount.source":
                if let store = session.contextValue(ghostboxVolumeStoreContextKey, as: GhostboxVolumeStore.self),
                   let source = await store.redactedSource(for: reference) {
                    return .string(source)
                }
                return .string(mount.source)
            case "mount.destination": return .string(mount.destination)
            case "mount.options": return .strings(mount.options)
            default: return ghostboxMountRuntimeOptionsValue(mount.runtimeOptions)
            }

        default:
            throw ghostboxUnsupportedBootMethod(method)
        }
    }
}

struct GhostboxBootLogCommands: GhostboxDomainHandler {
    let resource = "bootLog"

    func handle(
        method: GhostboxDirectMethod,
        parameters: [String: GhostboxJSONValue],
        session: GhostboxSession
    ) async throws -> GhostboxDirectValue {
        guard method.rawValue == "bootLog.file" else {
            throw ghostboxUnsupportedBootMethod(method)
        }
        let decoded = try GhostboxParameters(parameters, allowed: ["bootLog", "path", "append"])
        let bootLog = BootLog.file(
            path: try ghostboxURL(decoded.requiredString("path"), parameter: "path"),
            append: try decoded.optionalBool("append") ?? true
        )
        let reference = try session.register(
            kind: "boot-log",
            name: decoded.requiredString("bootLog"),
            value: bootLog,
            equivalent: { _, _ in false }
        )
        return .reference(reference)
    }
}

enum GhostboxBootCommandHandlers {
    static let all: [any GhostboxDomainHandler] = [
        GhostboxKernelCommandLineCommands(),
        GhostboxKernelCommands(),
        GhostboxKernelImageCommands(),
        GhostboxInitImageCommands(),
        GhostboxMountCommands(),
        GhostboxBootLogCommands(),
    ]
}

private func ghostboxUnsupportedBootMethod(_ method: GhostboxDirectMethod) -> DirectDispatchError {
    DirectDispatchError(.unsupported, "unsupported direct method '\(method.rawValue)'")
}

private func ghostboxLabels(_ assignments: [String]) throws -> [String: String] {
    var result: [String: String] = [:]
    for assignment in assignments {
        guard let separator = assignment.firstIndex(of: "="), separator != assignment.startIndex else {
            throw DirectDispatchError(.invalidArgument, "parameter 'label' values must use key=value")
        }
        let key = String(assignment[..<separator])
        let value = String(assignment[assignment.index(after: separator)...])
        guard result.updateValue(value, forKey: key) == nil else {
            throw DirectDispatchError(.invalidArgument, "parameter 'label' contains duplicate key '\(key)'")
        }
    }
    return result
}

private func ghostboxURL(_ raw: String, parameter: String) throws -> URL {
    guard !raw.isEmpty, !raw.contains("\0") else {
        throw DirectDispatchError(.invalidArgument, "parameter '\(parameter)' must be a non-empty URL")
    }
    if let url = URL(string: raw), url.scheme != nil {
        return url
    }
    return URL(filePath: raw)
}

private func ghostboxSystemPlatform(
    _ parameters: [String: GhostboxJSONValue],
    _ name: String
) throws -> SystemPlatform {
    guard let value = parameters[name] else {
        throw DirectDispatchError(.invalidArgument, "missing required parameter '\(name)'")
    }
    let os: String
    let architecture: String
    switch value {
    case .string(let raw):
        let components = raw.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2 else {
            throw DirectDispatchError(.invalidArgument, "parameter '\(name)' must use os/architecture")
        }
        os = String(components[0])
        architecture = String(components[1])
    case .object(let object):
        let unknown = Set(object.keys).subtracting(["os", "architecture"])
        guard unknown.isEmpty else {
            throw DirectDispatchError(.invalidArgument, "parameter '\(name)' has unknown field '\(unknown.sorted()[0])'")
        }
        guard case .string(let decodedOS)? = object["os"],
              case .string(let decodedArchitecture)? = object["architecture"] else {
            throw DirectDispatchError(.invalidArgument, "parameter '\(name)' requires string os and architecture fields")
        }
        os = decodedOS
        architecture = decodedArchitecture
    default:
        throw DirectDispatchError(.invalidArgument, "parameter '\(name)' must be an os/architecture string or object")
    }
    guard let decodedOS = SystemPlatform.OS(rawValue: os),
          let decodedArchitecture = SystemPlatform.Architecture(rawValue: architecture) else {
        throw DirectDispatchError(.invalidArgument, "unsupported system platform '\(os)/\(architecture)'")
    }
    return try JSONDecoder().decode(
        SystemPlatform.self,
        from: JSONEncoder().encode([
            "os": decodedOS.rawValue,
            "architecture": decodedArchitecture.rawValue,
        ])
    )
}

private func ghostboxOCIPlatform(
    _ parameters: [String: GhostboxJSONValue],
    _ name: String
) throws -> ContainerizationOCI.Platform {
    guard let value = parameters[name] else {
        throw DirectDispatchError(.invalidArgument, "missing required parameter '\(name)'")
    }
    do {
        switch value {
        case .string(let raw) where raw.first == "{":
            return try JSONDecoder().decode(ContainerizationOCI.Platform.self, from: Data(raw.utf8))
        case .string(let raw):
            return try ContainerizationOCI.Platform(from: raw)
        case .object:
            return try JSONDecoder().decode(
                ContainerizationOCI.Platform.self,
                from: JSONEncoder().encode(value)
            )
        default:
            throw DirectDispatchError(.invalidArgument, "parameter '\(name)' must be a platform string or object")
        }
    } catch let error as DirectDispatchError {
        throw error
    } catch {
        throw DirectDispatchError(.invalidArgument, "parameter '\(name)' is not a valid OCI platform: \(error.localizedDescription)")
    }
}

private func ghostboxSystemPlatformValue(_ platform: SystemPlatform) -> GhostboxDirectValue {
    .object([
        "os": .string(platform.os.rawValue),
        "architecture": .string(platform.architecture.rawValue),
    ])
}

private func ghostboxMountRuntimeOptions(
    _ parameters: [String: GhostboxJSONValue],
    _ name: String
) throws -> Containerization.Mount.RuntimeOptions {
    guard let value = parameters[name] else {
        throw DirectDispatchError(.invalidArgument, "missing required parameter '\(name)'")
    }
    let object: [String: GhostboxJSONValue]
    switch value {
    case .object(let decoded):
        object = decoded
    case .string(let raw):
        do {
            let decoded = try JSONDecoder().decode(GhostboxJSONValue.self, from: Data(raw.utf8))
            guard case .object(let decodedObject) = decoded else {
                throw DirectDispatchError(.invalidArgument, "parameter '\(name)' JSON must be an object")
            }
            object = decodedObject
        } catch let error as DirectDispatchError {
            throw error
        } catch {
            throw DirectDispatchError(.invalidArgument, "parameter '\(name)' is not valid JSON: \(error.localizedDescription)")
        }
    default:
        throw DirectDispatchError(.invalidArgument, "parameter '\(name)' must be a JSON object")
    }

    if object.isEmpty {
        return .any([])
    }
    let unknown = Set(object.keys).subtracting(["kind", "options"])
    guard unknown.isEmpty else {
        throw DirectDispatchError(.invalidArgument, "parameter '\(name)' has unknown field '\(unknown.sorted()[0])'")
    }
    guard case .string(let kind)? = object["kind"] else {
        throw DirectDispatchError(.invalidArgument, "parameter '\(name)' requires a string kind field")
    }
    let options: [String]
    if let rawOptions = object["options"] {
        options = try ghostboxStrings(rawOptions, parameter: "\(name).options")
    } else {
        options = []
    }
    switch kind {
    case "virtioblk": return .virtioblk(options)
    case "virtiofs": return .virtiofs(options)
    case "shared":
        guard options.isEmpty else {
            throw DirectDispatchError(.invalidArgument, "shared runtime options cannot contain options")
        }
        return .shared
    case "any": return .any(options)
    default: throw DirectDispatchError(.invalidArgument, "unknown mount runtime options kind '\(kind)'")
    }
}

private func ghostboxStrings(_ value: GhostboxJSONValue, parameter: String) throws -> [String] {
    guard case .array(let values) = value else {
        throw DirectDispatchError(.invalidArgument, "parameter '\(parameter)' must be an array")
    }
    return try values.enumerated().map { index, value in
        guard case .string(let string) = value else {
            throw DirectDispatchError(.invalidArgument, "parameter '\(parameter)' element \(index) must be a string")
        }
        return string
    }
}

private func ghostboxMountRuntimeOptionsValue(_ options: Containerization.Mount.RuntimeOptions) -> GhostboxDirectValue {
    let kind: String
    let values: [String]
    switch options {
    case .virtioblk(let options):
        kind = "virtioblk"
        values = options
    case .virtiofs(let options):
        kind = "virtiofs"
        values = options
    case .shared:
        kind = "shared"
        values = []
    case .any(let options):
        kind = "any"
        values = options
    }
    return .object([
        "kind": .string(kind),
        "options": .strings(values),
    ])
}

private func ghostboxRegisterKernelImage(
    _ image: KernelImage,
    name: String,
    session: GhostboxSession
) throws -> GhostboxDirectValue {
    let reference = try session.register(
        kind: "kernel-image",
        name: name,
        value: image,
        equivalent: { $0.name == $1.name }
    )
    return .reference(reference)
}

private func ghostboxRegisterInitImage(
    _ image: InitImage,
    name: String,
    session: GhostboxSession
) throws -> GhostboxDirectValue {
    let reference = try session.register(
        kind: "init-image",
        name: name,
        value: image,
        equivalent: { $0.name == $1.name }
    )
    return .reference(reference)
}

private func ghostboxRegisterMount(
    _ mount: Containerization.Mount,
    name: String,
    session: GhostboxSession
) throws -> GhostboxDirectValue {
    let reference = try session.register(
        kind: "mount",
        name: name,
        value: mount,
        equivalent: ghostboxMountsEqual
    )
    return .reference(reference)
}

private func ghostboxCommandLinesEqual(_ lhs: Kernel.CommandLine, _ rhs: Kernel.CommandLine) -> Bool {
    lhs.kernelArgs == rhs.kernelArgs && lhs.initArgs == rhs.initArgs
}

private func ghostboxKernelsEqual(_ lhs: Kernel, _ rhs: Kernel) -> Bool {
    lhs.path == rhs.path
        && lhs.platform.os == rhs.platform.os
        && lhs.platform.architecture == rhs.platform.architecture
        && ghostboxCommandLinesEqual(lhs.commandLine, rhs.commandLine)
}

private func ghostboxMountsEqual(_ lhs: Containerization.Mount, _ rhs: Containerization.Mount) -> Bool {
    lhs.type == rhs.type
        && lhs.source == rhs.source
        && lhs.destination == rhs.destination
        && lhs.options == rhs.options
        && ghostboxMountRuntimeOptionsEqual(lhs.runtimeOptions, rhs.runtimeOptions)
}

private func ghostboxMountRuntimeOptionsEqual(
    _ lhs: Containerization.Mount.RuntimeOptions,
    _ rhs: Containerization.Mount.RuntimeOptions
) -> Bool {
    switch (lhs, rhs) {
    case (.virtioblk(let lhs), .virtioblk(let rhs)): return lhs == rhs
    case (.virtiofs(let lhs), .virtiofs(let rhs)): return lhs == rhs
    case (.shared, .shared): return true
    case (.any(let lhs), .any(let rhs)): return lhs == rhs
    default: return false
    }
}

private func ghostboxDerivedName(reference: String, operation: String, discriminator: String) -> String {
    let rawName = reference.split(separator: "/", maxSplits: 1).last.map(String.init) ?? "object"
    let prefix = rawName.prefix(80).map { character -> Character in
        character.isLetter || character.isNumber || character == "." || character == "_" || character == "-" ? character : "-"
    }
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in "\(operation)|\(discriminator)".utf8 {
        hash ^= UInt64(byte)
        hash &*= 1_099_511_628_211
    }
    return "\(String(prefix))-\(operation)-\(String(hash, radix: 16))"
}
