import Foundation
import Virtualization

/// Write data to a URL, creating parent directories if needed.
public func writeData(_ data: Data, to url: URL) throws {
    let directory = url.deletingLastPathComponent()
    if !FileManager.default.fileExists(atPath: directory.path) {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
    }
    try data.write(to: url, options: .atomic)
}

/// Load a VZMacHardwareModel from a file.
public func loadHardwareModel(from url: URL) throws -> VZMacHardwareModel {
    let data = try Data(contentsOf: url)
    guard let model = VZMacHardwareModel(dataRepresentation: data) else {
        throw VMError.message("Failed to decode hardware model at \(url.path).")
    }
    guard model.isSupported else {
        throw VMError.message("Hardware model stored at \(url.path) is not supported on this host.")
    }
    return model
}

/// Load a VZMacMachineIdentifier from a file.
public func loadMachineIdentifier(from url: URL) throws -> VZMacMachineIdentifier {
    let data = try Data(contentsOf: url)
    guard let identifier = VZMacMachineIdentifier(dataRepresentation: data) else {
        throw VMError.message("Failed to decode machine identifier at \(url.path).")
    }
    return identifier
}
