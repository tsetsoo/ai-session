#if os(iOS)
import AISessionCore
import UIKit

/// A pasted photo, scaled and encoded away from the main thread, then copied to a computer
/// with `PhotoUpload`. Used by the chat's message field and the terminal's Paste.
/// UIImage is safe to read from any thread once made, and nothing changes this one.
struct PastedPhoto: @unchecked Sendable {
    enum Unreadable: Error { case photo }

    let image: UIImage

    /// A new upload's file name.
    static func newName() -> String { "\(UUID().uuidString.lowercased()).jpg" }

    /// Scales and encodes off the main thread (a 48 MP photo takes a while), then uploads.
    /// Returns the photo's absolute path on the computer.
    func upload(name: String = newName(), config: HostConnectionConfig) async throws -> String {
        let photo = self
        guard let data = await Task.detached(priority: .userInitiated, operation: { photo.jpeg() }).value else {
            throw Unreadable.photo
        }
        return try await PhotoUpload.upload(data, name: name, config: config, ssh: NIOSSHClient())
    }

    /// The model scales images down to about this long edge anyway, so a bigger one only
    /// costs upload time. Transparent areas become white, as JPEG has no transparency.
    func jpeg(longEdge: CGFloat = 1568) -> Data? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(1, longEdge / max(size.width, size.height))
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let resized = UIGraphicsImageRenderer(size: target, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: target))
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return resized.jpegData(compressionQuality: 0.85)
    }
}
#endif
