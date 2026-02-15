import Foundation

/// Shared URL utilities for host-side code (GhostVM, GhostVMHelper)
///
/// Provides URL filtering and display helpers used by EventStreamService
/// and URLPermissionPanel.
public enum URLUtilities {

    /// Filter an array of URL strings to only http/https schemes.
    /// - Parameter urls: Raw URL strings from the guest
    /// - Returns: Only URLs with http or https schemes
    public static func filterWebURLs(_ urls: [String]) -> [String] {
        urls.filter { urlString in
            guard let url = URL(string: urlString),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else { return false }
            return true
        }
    }

    /// Truncate a string in the middle with a Unicode ellipsis if it exceeds maxLength.
    /// - Parameters:
    ///   - string: The string to truncate
    ///   - maxLength: Maximum allowed character count
    /// - Returns: The original string if within limit, otherwise prefix + \u{2026} + suffix
    public static func truncateMiddle(_ string: String, maxLength: Int) -> String {
        guard string.count > maxLength else { return string }
        let half = (maxLength - 1) / 2
        let start = string.prefix(half)
        let end = string.suffix(half)
        return "\(start)\u{2026}\(end)"
    }
}
