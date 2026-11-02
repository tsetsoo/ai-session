import Foundation

/// SwiftTerm reports both URLs and plain paths as link text. A plain path passed to
/// `URL(string:)` is a relative URL, which Launch Services cannot open (error -50).
public enum TerminalLink {
    public static func url(for link: String) -> URL? {
        if link.hasPrefix("/") {
            return URL(fileURLWithPath: link)
        }
        if link.hasPrefix("~/") {
            return URL(fileURLWithPath: (link as NSString).expandingTildeInPath)
        }
        guard let url = URL(string: link), let scheme = url.scheme, !scheme.isEmpty else {
            return nil
        }
        return url
    }
}
