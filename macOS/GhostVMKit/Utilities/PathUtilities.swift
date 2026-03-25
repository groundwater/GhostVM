import Foundation

/// Expand tilde and standardize a path to an absolute path.
public func standardizedAbsolutePath(_ path: String) -> String {
    let expanded = (path as NSString).expandingTildeInPath
    let resolved = expanded.isEmpty ? path : expanded
    return URL(fileURLWithPath: resolved).standardizedFileURL.path
}
