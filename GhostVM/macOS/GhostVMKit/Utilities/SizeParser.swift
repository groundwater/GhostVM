import Foundation

/// Parse a size string like "8G", "512M", or raw bytes into UInt64 bytes.
public func parseBytes(from argument: String, defaultUnit: UInt64 = 1) throws -> UInt64 {
    let lower = argument.lowercased()
    if let value = UInt64(lower) {
        return value * defaultUnit
    }
    let suffixes: [(String, UInt64)] = [
        ("tb", 1 << 40),
        ("t", 1 << 40),
        ("gb", 1 << 30),
        ("g", 1 << 30),
        ("mb", 1 << 20),
        ("m", 1 << 20),
        ("kb", 1 << 10),
        ("k", 1 << 10)
    ]
    for (suffix, multiplier) in suffixes {
        if lower.hasSuffix(suffix) {
            let numericPart = lower.dropLast(suffix.count)
            guard let value = UInt64(numericPart) else {
                throw VMError.message("Could not parse size from '\(argument)'.")
            }
            return value * multiplier
        }
    }
    throw VMError.message("Unrecognized size '\(argument)'. Use values like 64G, 8192M, or 65536.")
}
