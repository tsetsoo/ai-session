#if os(iOS)
import AISessionCore
import Observation
import UIKit

/// A photo on the clipboard, read, scaled and encoded away from the main thread, then copied
/// to a computer with `PhotoUpload`. Used by the chat's message field and the terminal's Paste.
/// The item provider loads on its own queue, and nothing else touches the image once loaded.
struct PastedPhoto: @unchecked Sendable {
    enum Unreadable: Error { case photo }

    let provider: NSItemProvider

    /// The clipboard's photo, if it has one. With `textWins` a clipboard that also holds text
    /// gives nil, so the text pastes: the terminal's choice, where text is the usual paste.
    /// The chat lets the photo win (Safari's Copy Image adds the link as text).
    static func fromClipboard(textWins: Bool) -> PastedPhoto? {
        let board = UIPasteboard.general
        guard board.hasImages, !(textWins && board.hasStrings) else { return nil }
        guard let provider = board.itemProviders.first(where: { $0.canLoadObject(ofClass: UIImage.self) }) else {
            return nil
        }
        return PastedPhoto(provider: provider)
    }

    /// Loads, scales and encodes, then uploads. Returns the photo's absolute path on the computer.
    func upload(config: HostConnectionConfig) async throws -> String {
        let photo = self
        guard let data = await Task.detached(priority: .userInitiated, operation: { await photo.jpeg() }).value else {
            throw Unreadable.photo
        }
        let name = "\(UUID().uuidString.lowercased()).jpg"
        return try await PhotoUpload.upload(data, name: name, config: config, ssh: NIOSSHClient())
    }

    private func image() async -> UIImage? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: UIImage.self) { object, _ in
                continuation.resume(returning: object as? UIImage)
            }
        }
    }

    /// The model scales images down to about this long edge anyway, so a bigger one only
    /// costs upload time. Transparent areas become white, as JPEG has no transparency.
    private func jpeg(longEdge: CGFloat = 1568) async -> Data? {
        guard let image = await image() else { return nil }
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

/// Pasted photos on their way to one computer, and what to show about them. Several can upload
/// at once. A failure shows for a few seconds, ahead of "Uploading…", so it is never hidden by
/// another photo still on its way. Main thread only.
@Observable
final class PhotoUploads {
    /// "Uploading photo…", a failure for a few seconds, or nil.
    var status: String? {
        if let error { return error }
        switch tasks.count {
        case 0: return nil
        case 1: return "Uploading photo…"
        case let count: return "Uploading \(count) photos…"
        }
    }

    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var error: String?

    /// Uploads `photo` and hands its path to `onUploaded` on the main thread, unless cancelled.
    /// `computerName` words the failure.
    func start(
        _ photo: PastedPhoto, config: HostConnectionConfig, computerName: String? = nil,
        onUploaded: @escaping @MainActor (String) -> Void
    ) {
        error = nil
        let id = UUID()
        tasks[id] = Task { @MainActor [weak self] in
            defer { self?.tasks[id] = nil }
            do {
                let path = try await photo.upload(config: config)
                guard !Task.isCancelled else { return }
                onUploaded(path)
            } catch where Task.isCancelled || error is CancellationError {
                // Cancelled: the partial file is already being removed.
            } catch PastedPhoto.Unreadable.photo {
                self?.fail("Couldn’t read that photo.")
            } catch {
                let place = computerName.map { " to \($0)" } ?? ""
                self?.fail("Couldn’t copy the photo\(place). Try pasting it again.")
            }
        }
    }

    func cancelAll() {
        tasks.values.forEach { $0.cancel() }
        tasks = [:]
        error = nil
    }

    func clearError() { error = nil }

    private func fail(_ message: String) {
        error = message
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(6))
            if self?.error == message { self?.error = nil }
        }
    }
}
#endif
