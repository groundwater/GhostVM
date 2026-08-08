import Foundation

let ghostboxHelp = renderRootGhostboxHelp()

func renderGhostboxHelp(_ topic: [String]) -> Result<String, ParseError> {
    guard !topic.isEmpty else { return .success(ghostboxHelp) }

    if topic.count == 1, let namespace = canonicalHelpNamespace(topic[0]) {
        return .success(renderNamespaceHelp(namespace))
    }
    if topic.count == 2, let namespace = canonicalHelpNamespace(topic[0]) {
        return renderResourceHelp(namespace: namespace, resource: topic[1])
    }
    guard topic.count == 1, let qualified = GhostboxQualifiedCommand(topic[0]) else {
        return .failure(.invalidDirect(
            "help expects cn:help, cr:help, NAMESPACE:RESOURCE:help, or NAMESPACE:RESOURCE:OPERATION"
        ))
    }
    if qualified.operation == "help" {
        return renderResourceHelp(namespace: qualified.namespace, resource: qualified.resource)
    }
    if let command = ghostboxCommandCatalog.first(where: {
        $0.commandID == qualified.canonical || $0.aliases.contains(topic[0])
    }) {
        return .success(renderCommandHelp(command))
    }
    if qualified.namespace == "cn", let help = renderContainerizationExtensionHelp(qualified) {
        return .success(help)
    }
    return .failure(.invalidDirect(
        "unknown help command '\(topic[0])'; run 'ghostbox \(qualified.namespace):\(qualified.resource):help'"
    ))
}

private func canonicalHelpNamespace(_ value: String) -> String? {
    switch value {
    case "cn", "containerization": "cn"
    case "cr", "container": "cr"
    default: nil
    }
}

private func renderNamespaceHelp(_ namespace: String) -> String {
    let commands = ghostboxCommandCatalog.filter { $0.namespace == namespace }
    var lines = [
        namespace == "cn" ? "Containerization namespace (cn):" : "Container namespace (cr):",
        "",
        "Use 'ghostbox \(namespace):RESOURCE:help' for resource help.",
    ]
    for resource in Set(commands.map(\.resource)).sorted() {
        lines.append("")
        lines.append("\(resource):")
        for command in commands where command.resource == resource {
            lines.append(contentsOf: renderSignatureReference(command, indent: "  "))
        }
    }
    if namespace == "cn" {
        lines.append("\nGhostVM Containerization extensions: kernel, cleanup, guest-share, forwarding, and I/O proxy commands.")
    }
    return lines.joined(separator: "\n")
}

private func renderResourceHelp(namespace: String, resource: String) -> Result<String, ParseError> {
    let commands = ghostboxCommandCatalog.filter { $0.namespace == namespace && $0.resource == resource }
    if commands.isEmpty {
        if namespace == "cn", let help = renderContainerizationExtensionResourceHelp(resource) {
            return .success(help)
        }
        return .failure(.invalidDirect("unknown resource '\(resource)' in namespace '\(namespace)'"))
    }
    var help = renderResourceHelp(namespace, resource: resource, commands: commands)
    guard namespace == "cn" else { return .success(help) }
    if resource == "kernel" {
        help += "\n\nHost extensions:\n  ghostbox cn:kernel:install-recommended -> @kernel/default\n  ghostbox cn:kernel:default -> @kernel/default"
    }
    if let extensionSignature = ghostboxCleanupExtensionSignatures[resource] {
        help += "\n\nGhostVM cleanup extension:\n  \(extensionSignature)"
    }
    if resource == "mount" {
        help += "\n\nGhostVM guest-share extension:\n  ghostbox cn:mount:guest-share NAME --source GUEST_PATH --destination CONTAINER_PATH [--read-only=true|false] [--cache-ttl SECONDS]"
    } else if resource == "container" {
        help += "\n\nGhostVM port-forward extension:\n  ghostbox cn:container:forward @container/NAME -p [GUEST_IP:]GUEST_PORT:CONTAINER_PORT[/tcp]"
    }
    return .success(help)
}

private func renderContainerizationExtensionHelp(_ command: GhostboxQualifiedCommand) -> String? {
    if command.resource == "kernel", command.operation == "default" {
        return "Usage:\n  ghostbox cn:kernel:default -> @kernel/default\n\nMethod: kernel.default\nHost API: KernelService.getDefaultKernel(platform: .linuxArm)"
    }
    if command.resource == "kernel", command.operation == "install-recommended" {
        return "Usage:\n  ghostbox cn:kernel:install-recommended -> @kernel/default\n\nMethod: kernel.installRecommended\nHost APIs: ConfigurationLoader.load(configurationFiles:), KernelService.installKernelFrom(...)"
    }
    let legacy = [command.resource, command.operation]
    return renderCleanupExtensionHelp(legacy)
        ?? renderContainerBridgeExtensionHelp(legacy)
        ?? renderIOProxyHelp(legacy)
}

private func renderContainerizationExtensionResourceHelp(_ resource: String) -> String? {
    renderIOProxyHelp([resource])
}

private func renderRootGhostboxHelp() -> String {
    var lines = [
        "Usage:",
        "  ghostbox NAMESPACE:RESOURCE:OPERATION [@RESOURCE/NAME] [ARGUMENTS] [OPTIONS]",
        "  ghostbox NAMESPACE:RESOURCE:help",
        "  ghostbox NAMESPACE:RESOURCE:OPERATION --help",
        "  ghostbox cn:help | cr:help",
        "",
        "Source-qualified diagnostic interface to Apple Containerization and container APIs.",
        "Namespaces: cn (containerization) and cr (container).",
        "Use resource or operation help for argument, type, default, output, and example details.",
        "",
        "Signature conventions:",
        "  <argument:type>       New literal value.",
        "  @<argument:type>      Existing VMHost-owned object reference.",
        "  [argument]            Optional argument.",
        "  argument...           Repeatable argument.",
        "  -> @<argument:type>   Canonical object reference printed on success.",
        "  [--argument=default]  Optional argument using the shown framework default.",
        "",
        "Output conventions:",
        "  Object creation and framework-object results print canonical @ references.",
        "  Property and value results print JSON-compatible values.",
        "  Byte results are written directly to stdout.",
        "",
        "Options:",
        "  --help, -h   Show root, resource, or operation help.",
        "  --version    Show version.",
        "",
        "VM host extensions:",
        "  ghostbox cn:kernel:install-recommended -> @kernel/default",
        "  ghostbox cn:kernel:default -> @kernel/default",
        "  ghostbox cn:dns:delete @dns/NAME",
        "  ghostbox cn:mount:guest-share NAME --source GUEST_PATH --destination CONTAINER_PATH",
        "  ghostbox cr:volume:create NAME [--size BYTES] -> @volume/NAME",
        "  ghostbox cr:volume:mount @volume/NAME MOUNT --destination PATH -> @mount/MOUNT",
        "",
        "VM guest extensions:",
        "  ghostbox cn:container:forward @container/NAME -p [GUEST_IP:]GUEST_PORT:CONTAINER_PORT[/tcp]",
        "",
        "VM I/O proxy extensions:",
        "  ghostbox cn:reader-stream:create <name>",
        "  ghostbox cn:reader-stream:attach|close @reader-stream/NAME",
        "  ghostbox cn:writer:create <name>",
        "  ghostbox cn:writer:attach|close @writer/NAME",
        "  ghostbox cn:terminal:create <name> [--width=80] [--height=24]",
        "  ghostbox cn:terminal:attach @terminal/NAME [--resize-target @container/NAME|@process/NAME]",
        "  ghostbox cn:terminal:wait-attached|close @terminal/NAME",
        "  Proxy attach commands forward raw fd 0 or fd 1; terminal attach requires a TTY.",
        "",
        "Cataloged signatures:",
    ]

    for namespace in ["cn", "cr"] {
        lines.append("")
        lines.append(namespace == "cn" ? "Containerization (cn):" : "Container (cr):")
        for command in ghostboxCommandCatalog where command.namespace == namespace {
            lines.append(contentsOf: renderSignatureReference(command, indent: "  "))
        }
    }
    return lines.joined(separator: "\n")
}

private func renderVolumeHelp(_ topic: [String]) -> String? {
    guard topic.first == "volume" else { return nil }
    if topic.count == 1 {
        return """
        Usage:
          ghostbox cr:volume:create NAME [--size BYTES] -> @volume/NAME
          ghostbox cr:volume:list -> @volume/NAME...
          ghostbox cr:volume:inspect @volume/NAME
          ghostbox cr:volume:mount @volume/NAME MOUNT --destination PATH [--read-only=true|false] -> @mount/MOUNT
          ghostbox cr:volume:delete @volume/NAME

        Persistent ext4 volumes are stored with the VM and survive container and VM restarts.
        Delete the returned mount reference before deleting its volume.
        """
    }
    let operation = topic.last
    switch operation {
    case "create":
        return "Usage:\n  ghostbox cr:volume:create NAME [--size BYTES] -> @volume/NAME\n\nCreates a persistent ext4 volume. The default size is 8 GiB."
    case "list":
        return "Usage:\n  ghostbox cr:volume:list -> @volume/NAME...\n\nLists persistent volumes in lexical order."
    case "inspect":
        return "Usage:\n  ghostbox cr:volume:inspect @volume/NAME\n\nPrints volume metadata without exposing the outer-host backing path."
    case "mount":
        return "Usage:\n  ghostbox cr:volume:mount @volume/NAME MOUNT --destination PATH [--read-only=true|false] -> @mount/MOUNT\n\nCreates an ext4 block-mount reference for a container configuration."
    case "delete":
        return "Usage:\n  ghostbox cr:volume:delete @volume/NAME\n\nDeletes an unused volume and its contents."
    default:
        return nil
    }
}

private let ghostboxCleanupExtensionSignatures = [
    "dns": "ghostbox cn:dns:delete @dns/NAME",
    "process-config": "ghostbox cn:process-config:delete @process-config/NAME",
    "network": "ghostbox cn:network:delete @network/NAME",
    "manager": "ghostbox cn:manager:close @manager/NAME",
    "mount": "ghostbox cn:mount:delete @mount/NAME",
]

private func renderCleanupExtensionHelp(_ topic: [String]) -> String? {
    guard topic.count == 2 || (topic.count == 3 && topic[1].hasPrefix("@")) else { return nil }
    let resource = topic[0]
    let operation = topic.last!
    let expectedOperation = resource == "manager" ? "close" : "delete"
    guard let signature = ghostboxCleanupExtensionSignatures[resource],
          operation == expectedOperation else { return nil }
    let detail: String
    switch resource {
    case "network":
        detail = "Removes the host reference after all interfaces allocated from it have been released."
    case "manager":
        detail = "Closes the manager reference after all of its managed containers have been deleted."
    default:
        detail = "Removes the host-owned configuration reference. Existing containers retain copied configuration."
    }
    return """
    Usage:
      \(signature)

    Method: \(resource == "process-config" ? "processConfig" : resource).\(operation)
    GhostVM host extension

    \(detail)
    """
}

private func renderContainerBridgeExtensionHelp(_ topic: [String]) -> String? {
    if topic == ["mount", "guest-share"] {
        return """
        Usage:
          ghostbox cn:mount:guest-share NAME --source GUEST_PATH --destination CONTAINER_PATH [--read-only=true|false] [--cache-ttl SECONDS] [--option VALUE]... [--runtime-option VALUE]...

        Method: mount.guestShare
        GhostVM host extension

        Exports the guest path through the private GhostFile bridge, mounts it on the outer host through GhostVMFS, and returns a Containerization Mount.share reference.
        """
    }
    if topic == ["container", "forward"]
        || (topic.count == 3 && topic[0] == "container" && topic[1].hasPrefix("@") && topic[2] == "forward") {
        return """
        Usage:
          ghostbox cn:container:forward @container/NAME -p|-P [GUEST_IP:]GUEST_PORT:CONTAINER_PORT[/tcp] [-p ...]

        GhostVM guest extension

        Listens in this guest and forwards TCP directly to the container's shared-vmnet IPv4 address until interrupted.
        """
    }
    return nil
}

private func renderIOProxyHelp(_ topic: [String]) -> String? {
    guard let resource = topic.first,
          ["reader-stream", "writer", "terminal"].contains(resource) else { return nil }
    if topic.count == 1 {
        switch resource {
        case "reader-stream":
            return """
            Usage:
              ghostbox cn:reader-stream:create <name>
              ghostbox cn:reader-stream:attach @reader-stream/NAME
              ghostbox cn:reader-stream:close @reader-stream/NAME

            Creates a VM-backed Apple ReaderStream. Attach copies raw stdin into it until EOF.
            """
        case "writer":
            return """
            Usage:
              ghostbox cn:writer:create <name>
              ghostbox cn:writer:attach @writer/NAME
              ghostbox cn:writer:close @writer/NAME

            Creates a VM-backed Apple Writer. Attach copies its raw bytes to stdout until closed.
            """
        default:
            return """
            Usage:
              ghostbox cn:terminal:create <name> [--width=80] [--height=24]
              ghostbox cn:terminal:attach @terminal/NAME [--resize-target @container/NAME|@process/NAME]
              ghostbox cn:terminal:wait-attached @terminal/NAME
              ghostbox cn:terminal:close @terminal/NAME

            Creates a VM-backed Apple Terminal. Attach proxies a local TTY in raw mode. Wait-attached blocks until client terminal initialization completes. A resize target forwards dimensions to the container or process PTY.
            """
        }
    }

    let operation: String
    if topic.count == 2 {
        operation = topic[1]
    } else if topic.count == 3, topic[1].hasPrefix("@") {
        operation = topic[2]
    } else {
        return nil
    }
    let signatures: [String: Set<String>] = [
        "reader-stream": ["create", "attach", "close"],
        "writer": ["create", "attach", "close"],
        "terminal": ["create", "attach", "wait-attached", "close"],
    ]
    guard signatures[resource]?.contains(operation) == true else { return nil }
    return renderIOProxyHelp([resource])
}

private func renderResourceHelp(
    _ namespace: String,
    resource: String,
    commands: [GhostboxCommandSignature]
) -> String {
    var lines = [
        "Usage:",
        "  ghostbox \(namespace):\(resource):OPERATION [@\(resource)/NAME] [ARGUMENTS] [OPTIONS]",
        "",
        "\(resource) signatures:",
    ]
    for command in commands {
        lines.append(contentsOf: renderSignatureReference(command, indent: "  "))
    }
    lines.append("")
    lines.append("Run 'ghostbox \(namespace):\(resource):OPERATION --help' for argument and output details.")
    lines.append("Reference operations do not require a real receiver when requesting help.")
    return lines.joined(separator: "\n")
}

private func renderSignatureReference(
    _ command: GhostboxCommandSignature,
    indent: String
) -> [String] {
    var lines = command.signature.split(separator: "\n", omittingEmptySubsequences: false).enumerated().map {
        (index, line) in (index == 0 ? indent : indent + "  ") + line
    }
    lines.append("\(indent)Apple API: \(command.appleAPISymbol)")
    lines.append("\(indent)Apple docs: \(command.appleDocumentationURL)")
    return lines
}

private func renderCommandHelp(_ command: GhostboxCommandSignature) -> String {
    var lines = [
        "Usage:",
    ]
    lines.append(contentsOf: command.signature.split(separator: "\n", omittingEmptySubsequences: false).enumerated().map {
        (index, line) in (index == 0 ? "  " : "    ") + line
    })
    lines.append("")
    lines.append("Method: \(command.methodID)")
    lines.append("Apple API: \(command.appleAPISymbol)")
    lines.append("Apple docs: \(command.appleDocumentationURL)")

    if !command.positionals.isEmpty {
        lines.append("")
        lines.append("Arguments:")
        for (index, argument) in command.positionals.enumerated() {
            let receiver = command.shape == .reference && index == 0
            var traits = [argument.required ? "required" : "optional"]
            if receiver { traits.append("receiver") }
            if argument.repeatable { traits.append("repeatable") }
            lines.append(
                "  \(valueSyntax(name: argument.name, type: argument.type))  " +
                "\(traits.joined(separator: ", ")); \(describeType(argument.type))"
            )
        }
    }

    if !command.options.isEmpty {
        lines.append("")
        lines.append("Options:")
        for option in command.options {
            var traits = [option.required ? "required" : "optional"]
            if option.repeatable { traits.append("repeatable") }
            if let defaultValue = option.defaultValue {
                traits.append("default: \(renderHelpValue(defaultValue))")
            }
            let names = option.names.joined(separator: ", ")
            lines.append(
                "  \(names)  \(traits.joined(separator: ", ")); " +
                "type: \(option.type); \(describeType(option.type))"
            )
        }
    }

    if !command.implicitDefaults.isEmpty {
        lines.append("")
        lines.append("Implicit defaults:")
        for (name, value) in command.implicitDefaults.sorted(by: { $0.key < $1.key }) {
            lines.append("  \(name): \(renderHelpValue(value))")
        }
    }

    lines.append("")
    lines.append("Output:")
    if command.resultType == "void" {
        lines.append("  No output on success.")
    } else {
        lines.append("  \(command.resultType): \(describeResultType(command.resultType))")
    }
    lines.append("")
    lines.append("Example:")
    lines.append("  ghostbox " + command.exampleArguments.map(shellQuoted).joined(separator: " "))
    return lines.joined(separator: "\n")
}

private func valueSyntax(name: String, type: String) -> String {
    let baseType = type.hasSuffix("?") ? String(type.dropLast()) : type
    if baseType.hasPrefix("reference:") {
        return "@<\(name):id>"
    }
    return "<\(name):\(type)>"
}

private func describeType(_ type: String) -> String {
    var baseType = type
    var traits: [String] = []
    if baseType.hasSuffix("[]") {
        baseType.removeLast(2)
        traits.append("array")
    }
    if baseType.hasSuffix("?") {
        baseType.removeLast()
        traits.append("null accepted")
    }

    let description: String
    if baseType.hasPrefix("reference:") {
        let kind = String(baseType.dropFirst("reference:".count))
        description = "existing host-owned \(kind) in @\(kind)/NAME form"
    } else if let separator = baseType.firstIndex(of: "=") {
        let keyType = String(baseType[..<separator])
        let valueType = String(baseType[baseType.index(after: separator)...])
        description = "\(describeType(keyType))=\(describeType(valueType)) assignment"
    } else if baseType.contains("|") {
        description = "one of: \(baseType.split(separator: "|").joined(separator: ", "))"
    } else {
        description = typeDescriptions[baseType] ?? "\(baseType) value"
    }
    guard !traits.isEmpty else { return description }
    return "\(traits.joined(separator: ", ")) of \(description)"
}

private func describeResultType(_ type: String) -> String {
    var baseType = type
    var traits: [String] = []
    if baseType.hasSuffix("[]") {
        baseType.removeLast(2)
        traits.append("array")
    }
    if baseType.hasSuffix("?") {
        baseType.removeLast()
        traits.append("nullable")
    }
    guard baseType.hasPrefix("reference:") else {
        return describeType(type)
    }

    let kind = String(baseType.dropFirst("reference:".count))
    let reference = "canonical host-owned \(kind) reference in @\(kind)/NAME form"
    guard !traits.isEmpty else { return reference }
    return "\(traits.joined(separator: ", ")) of \(reference)"
}

private let typeDescriptions: [String: String] = [
    "attached-filesystem-map": "JSON map of attached virtual-machine filesystems",
    "bool": "true or false",
    "byte-stream": "raw byte stream written directly to stdout",
    "cidrv4": "IPv4 network in CIDR notation, such as 192.0.2.2/24",
    "cidrv6": "IPv6 network in CIDR notation, such as 2001:db8::2/64",
    "container-path": "absolute path inside a container",
    "container-statistics": "JSON-compatible container resource statistics",
    "container-url": "URL or path inside a container",
    "deleted-digests-and-freed-bytes": "JSON-compatible deleted-digest list and freed-byte count",
    "exit-status": "JSON-compatible process exit status",
    "file-permissions": "Unix file mode such as 0644",
    "host-path": "path on the macOS host",
    "host-url": "file URL or path on the macOS host",
    "image-description": "JSON-compatible OCI image description",
    "int": "signed integer",
    "int32": "32-bit signed integer",
    "int64": "64-bit signed integer",
    "ipv4-address": "IPv4 address such as 192.0.2.1",
    "ipv6-address": "IPv6 address such as 2001:db8::1",
    "linux-capability": "Linux capability name such as CAP_CHOWN",
    "linux-signal": "Linux signal name or number such as SIGTERM",
    "logger-level": "agent logger level such as info or debug",
    "mac-address": "MAC address such as 02:00:00:00:00:01",
    "mount-runtime-options": "JSON object matching Apple's mount runtime options",
    "name": "object name using letters, digits, '.', '_', or '-' (maximum 128 bytes)",
    "network-mode": "Apple vmnet network mode, such as shared",
    "oci-descriptor": "JSON-compatible OCI descriptor",
    "oci-descriptor-json": "OCI descriptor encoded as a JSON object",
    "oci-image": "JSON-compatible OCI image value",
    "oci-image-config": "OCI image configuration encoded as a JSON object",
    "oci-index": "JSON-compatible OCI image index",
    "oci-linux-capabilities": "JSON-compatible OCI Linux capabilities",
    "oci-manifest": "JSON-compatible OCI image manifest",
    "oci-mount": "JSON-compatible OCI mount",
    "oci-platform": "OCI platform in OS/architecture form, such as linux/arm64",
    "oci-posix-rlimit": "JSON-compatible OCI POSIX resource limit",
    "oci-user": "OCI user encoded as a JSON object",
    "pod-volume-source": "pod volume source encoded as a JSON object",
    "sha256-digest": "SHA-256 digest in sha256:HEX form",
    "statistics-category": "Apple container-statistics category",
    "string": "string",
    "system-platform": "system platform in OS/architecture form, such as linux/arm64",
    "uint16": "16-bit unsigned integer",
    "uint32": "32-bit unsigned integer",
    "uint64": "64-bit unsigned integer",
    "virtiofs-layout": "JSON-compatible virtual-machine virtiofs layout",
    "vm-state": "virtual-machine lifecycle state",
]

private func renderHelpValue(_ value: GhostboxJSONValue) -> String {
    switch value {
    case .null:
        return "null"
    case .boolean(let value):
        return String(value)
    case .string(let value):
        return value
    case .integer(let value):
        return String(value)
    case .unsignedInteger(let value):
        return String(value)
    case .array(let values):
        return "[" + values.map(renderHelpValue).joined(separator: ", ") + "]"
    case .object(let values):
        return "{" + values.sorted(by: { $0.key < $1.key }).map {
            "\($0.key): \(renderHelpValue($0.value))"
        }.joined(separator: ", ") + "}"
    }
}

private func shellQuoted(_ argument: String) -> String {
    let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_./@:=,+-"))
    if !argument.isEmpty && argument.unicodeScalars.allSatisfy(safe.contains) {
        return argument
    }
    return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
