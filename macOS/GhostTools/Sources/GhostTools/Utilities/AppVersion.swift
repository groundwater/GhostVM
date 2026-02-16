/// Comparable version with dot-separated numeric components.
/// "1.82.1771275740" is parsed as [1, 82, 1771275740].
/// Comparison is lexicographic by component: 1.83.0 > 1.82.9999999999.
struct AppVersion: Comparable, Equatable, CustomStringConvertible {
    let components: [Int]
    let raw: String

    init(_ string: String) {
        raw = string
        components = string.split(separator: ".").compactMap { Int($0) }
    }

    var description: String { raw }

    /// True if the version parsed at least one numeric component.
    var isValid: Bool { !components.isEmpty }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        for i in 0..<max(lhs.components.count, rhs.components.count) {
            let l = i < lhs.components.count ? lhs.components[i] : 0
            let r = i < rhs.components.count ? rhs.components[i] : 0
            if l != r { return l < r }
        }
        return false
    }
}
