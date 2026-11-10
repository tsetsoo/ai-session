import Foundation

/// Arbitrary files use the same private SSH upload and expiry as pasted photos.
public enum FileUpload {
    public static let maximumBytes = 100 * 1024 * 1024

    /// Keep a recognizable filename and extension, with a unique prefix and shell-safe bytes.
    public static func remoteName(for filename: String) -> String {
        let leaf = (filename as NSString).lastPathComponent
        let safe = String(leaf.map { character -> Character in
            character.isASCII && (character.isLetter || character.isNumber || character == "." || character == "-")
                ? character : "-"
        }.suffix(120))
        return UUID().uuidString.lowercased() + "-" + (safe.isEmpty ? "file" : safe)
    }
}
