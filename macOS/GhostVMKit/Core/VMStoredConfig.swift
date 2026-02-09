import Foundation

/// Configuration for a single port forward rule.
public struct PortForwardConfig: Codable, Equatable, Hashable, Identifiable {
    public var id: UUID
    public var hostPort: UInt16
    public var guestPort: UInt16
    public var enabled: Bool

    public init(id: UUID = UUID(), hostPort: UInt16, guestPort: UInt16, enabled: Bool = true) {
        self.id = id
        self.hostPort = hostPort
        self.guestPort = guestPort
        self.enabled = enabled
    }
}

/// Persisted VM metadata. Everything lives in config.json inside the bundle.
public struct VMStoredConfig: Codable {
    public var version: Int
    public var createdAt: Date
    public var modifiedAt: Date
    public var cpus: Int
    public var memoryBytes: UInt64
    public var diskBytes: UInt64
    public var restoreImagePath: String
    public var hardwareModelPath: String
    public var machineIdentifierPath: String
    public var auxiliaryStoragePath: String
    public var diskPath: String
    public var sharedFolderPath: String?
    public var sharedFolderReadOnly: Bool
    public var sharedFolders: [SharedFolderConfig]
    public var installed: Bool
    public var lastInstallBuild: String?
    public var lastInstallVersion: String?
    public var lastInstallDate: Date?
    public var legacyName: String?
    public var isSuspended: Bool
    public var macAddress: String?
    // Port forwarding configuration
    public var portForwards: [PortForwardConfig]
    // Icon mode: nil = static (icon.png), "dynamic" = mirror guest foreground app
    public var iconMode: String?

    public enum CodingKeys: String, CodingKey {
        case version
        case createdAt
        case modifiedAt
        case cpus
        case memoryBytes
        case diskBytes
        case restoreImagePath
        case hardwareModelPath
        case machineIdentifierPath
        case auxiliaryStoragePath
        case diskPath
        case sharedFolderPath
        case sharedFolderReadOnly
        case sharedFolders
        case installed
        case lastInstallBuild
        case lastInstallVersion
        case lastInstallDate
        case legacyName = "name"
        case isSuspended
        case macAddress
        case portForwards
        case iconMode
    }

    public init(
        version: Int,
        createdAt: Date,
        modifiedAt: Date,
        cpus: Int,
        memoryBytes: UInt64,
        diskBytes: UInt64,
        restoreImagePath: String,
        hardwareModelPath: String,
        machineIdentifierPath: String,
        auxiliaryStoragePath: String,
        diskPath: String,
        sharedFolderPath: String?,
        sharedFolderReadOnly: Bool,
        sharedFolders: [SharedFolderConfig] = [],
        installed: Bool,
        lastInstallBuild: String?,
        lastInstallVersion: String?,
        lastInstallDate: Date?,
        legacyName: String?,
        isSuspended: Bool = false,
        macAddress: String? = nil,
        portForwards: [PortForwardConfig] = [],
        iconMode: String? = nil
    ) {
        self.version = version
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.cpus = cpus
        self.memoryBytes = memoryBytes
        self.diskBytes = diskBytes
        self.restoreImagePath = restoreImagePath
        self.hardwareModelPath = hardwareModelPath
        self.machineIdentifierPath = machineIdentifierPath
        self.auxiliaryStoragePath = auxiliaryStoragePath
        self.diskPath = diskPath
        self.sharedFolderPath = sharedFolderPath
        self.sharedFolderReadOnly = sharedFolderReadOnly
        self.sharedFolders = sharedFolders
        self.installed = installed
        self.lastInstallBuild = lastInstallBuild
        self.lastInstallVersion = lastInstallVersion
        self.lastInstallDate = lastInstallDate
        self.legacyName = legacyName
        self.isSuspended = isSuspended
        self.macAddress = macAddress
        self.portForwards = portForwards
        self.iconMode = iconMode
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        modifiedAt = try container.decode(Date.self, forKey: .modifiedAt)
        cpus = try container.decode(Int.self, forKey: .cpus)
        memoryBytes = try container.decode(UInt64.self, forKey: .memoryBytes)
        diskBytes = try container.decode(UInt64.self, forKey: .diskBytes)
        restoreImagePath = try container.decode(String.self, forKey: .restoreImagePath)
        hardwareModelPath = try container.decode(String.self, forKey: .hardwareModelPath)
        machineIdentifierPath = try container.decode(String.self, forKey: .machineIdentifierPath)
        auxiliaryStoragePath = try container.decode(String.self, forKey: .auxiliaryStoragePath)
        diskPath = try container.decode(String.self, forKey: .diskPath)
        sharedFolderPath = try container.decodeIfPresent(String.self, forKey: .sharedFolderPath)
        sharedFolderReadOnly = try container.decode(Bool.self, forKey: .sharedFolderReadOnly)
        sharedFolders = try container.decodeIfPresent([SharedFolderConfig].self, forKey: .sharedFolders) ?? []
        installed = try container.decode(Bool.self, forKey: .installed)
        lastInstallBuild = try container.decodeIfPresent(String.self, forKey: .lastInstallBuild)
        lastInstallVersion = try container.decodeIfPresent(String.self, forKey: .lastInstallVersion)
        lastInstallDate = try container.decodeIfPresent(Date.self, forKey: .lastInstallDate)
        legacyName = try container.decodeIfPresent(String.self, forKey: .legacyName)
        isSuspended = try container.decodeIfPresent(Bool.self, forKey: .isSuspended) ?? false
        macAddress = try container.decodeIfPresent(String.self, forKey: .macAddress)
        // Port forwards - defaults to empty for backwards compatibility
        portForwards = try container.decodeIfPresent([PortForwardConfig].self, forKey: .portForwards) ?? []
        iconMode = try container.decodeIfPresent(String.self, forKey: .iconMode)
    }

    public mutating func normalize(relativeTo layout: VMFileLayout) -> Bool {
        var changed = false
        let basePath = layout.bundleURL.standardizedFileURL.path

        func makeRelative(_ path: String) -> (String, Bool) {
            guard path.hasPrefix("/") else { return (path, false) }
            let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
            if standardized.hasPrefix(basePath + "/") {
                let relative = String(standardized.dropFirst(basePath.count + 1))
                if relative != path {
                    return (relative, true)
                }
            }
            let filename = URL(fileURLWithPath: path).lastPathComponent
            if filename != path {
                return (filename, true)
            }
            return (path, false)
        }

        func makeAbsolute(_ path: String) -> (String, Bool) {
            let expanded = (path as NSString).expandingTildeInPath
            let resolved = expanded.isEmpty ? path : expanded
            let absolute = URL(fileURLWithPath: resolved).standardizedFileURL.path
            if absolute != path {
                return (absolute, true)
            }
            return (path, false)
        }

        let relPaths = [
            ("auxiliaryStoragePath", auxiliaryStoragePath),
            ("diskPath", diskPath),
            ("hardwareModelPath", hardwareModelPath),
            ("machineIdentifierPath", machineIdentifierPath)
        ]

        for (key, value) in relPaths {
            let (relative, didChange) = makeRelative(value)
            if didChange {
                changed = true
            }
            switch key {
            case "auxiliaryStoragePath": auxiliaryStoragePath = relative
            case "diskPath": diskPath = relative
            case "hardwareModelPath": hardwareModelPath = relative
            case "machineIdentifierPath": machineIdentifierPath = relative
            default: break
            }
        }

        let (absoluteRestore, restoreChanged) = makeAbsolute(restoreImagePath)
        if restoreChanged {
            restoreImagePath = absoluteRestore
            changed = true
        }

        if let shared = sharedFolderPath {
            let (absoluteShared, sharedChanged) = makeAbsolute(shared)
            if sharedChanged {
                sharedFolderPath = absoluteShared
                changed = true
            }
        }

        for i in sharedFolders.indices {
            if sharedFolders[i].normalize() {
                changed = true
            }
        }

        if legacyName != nil {
            legacyName = nil
            changed = true
        }

        return changed
    }
}
