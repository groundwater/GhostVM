import Foundation

/// Identifies the format of a VM disk image.
public enum DiskFormat: String {
    /// Raw sparse file (created via truncate)
    case raw
    /// Apple Sparse Image Format (macOS 26+)
    case asif
    /// Unrecognized format
    case unknown

    /// ASIF magic bytes: "shdw"
    private static let asifMagic: [UInt8] = [0x73, 0x68, 0x64, 0x77]

    /// Detect the disk format by reading the first 4 bytes.
    public static func detect(at url: URL) -> DiskFormat {
        guard let handle = FileHandle(forReadingAtPath: url.path) else {
            return .unknown
        }
        defer { try? handle.close() }

        guard let data = try? handle.read(upToCount: 4), data.count == 4 else {
            return .unknown
        }

        if data.elementsEqual(asifMagic) {
            return .asif
        }

        // Raw sparse files start with zeros (empty partition table area)
        // or with an EFI partition header (after macOS install)
        return .raw
    }

    public var isASIF: Bool { self == .asif }
}
