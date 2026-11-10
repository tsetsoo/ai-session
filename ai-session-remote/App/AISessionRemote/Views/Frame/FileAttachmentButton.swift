import AISessionCore
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// Shared by file pickers and native terminal file drops. Runs on the UI actor.
@MainActor @Observable
final class FileAttachments {
    var progress: Double?
    var status: String?
    var failure: String?
    private var pending: [URL] = []
    private var task: Task<Void, Never>?
    var isUploading: Bool { task != nil }

    func upload(_ urls: [URL], config: HostConnectionConfig, onUploaded: @escaping (String) -> Void) {
        pending.append(contentsOf: urls)
        guard task == nil else { return }
        task = Task {
            defer { status = nil; progress = nil; task = nil; pending = [] }
            while !pending.isEmpty {
                let url = pending.removeFirst()
                do {
                    progress = nil
                    status = "Preparing \(url.lastPathComponent)…"
                    let data = try await Task.detached(priority: .userInitiated) {
                        let scoped = url.startAccessingSecurityScopedResource()
                        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                        guard values.isRegularFile == true else { throw ReadFailure.regularFile }
                        guard (values.fileSize ?? 0) <= FileUpload.maximumBytes else { throw ReadFailure.tooLarge }
                        let handle = try FileHandle(forReadingFrom: url)
                        defer { try? handle.close() }
                        let data = try handle.read(upToCount: FileUpload.maximumBytes + 1) ?? Data()
                        guard data.count <= FileUpload.maximumBytes else { throw ReadFailure.tooLarge }
                        return data
                    }.value
                    try Task.checkCancellation()
                    let path = try await PhotoUpload.upload(
                        data, name: FileUpload.remoteName(for: url.lastPathComponent), config: config, ssh: NIOSSHClient(),
                        onProgress: { sent, total in
                            await MainActor.run {
                                self.progress = total > 0 ? Double(sent) / Double(total) : 1
                                self.status = sent == total
                                    ? "Finishing \(url.lastPathComponent)…"
                                    : "Uploading \(url.lastPathComponent)…"
                            }
                        }
                    )
                    try Task.checkCancellation()
                    onUploaded(path)
                } catch where Task.isCancelled || error is CancellationError {
                    return
                } catch {
                    failure = "\(url.lastPathComponent): \(error.localizedDescription)"
                    return
                }
            }
        }
    }

    func cancel() {
        task?.cancel()
        pending = []
    }

    private enum ReadFailure: LocalizedError {
        case regularFile, tooLarge
        var errorDescription: String? {
            switch self {
            case .regularFile: "Choose a file. Folders must be compressed first."
            case .tooLarge: "Files must be 100 MB or smaller."
            }
        }
    }
}

/// The picker remains available on touch devices; computers can drop onto the terminal.
struct FileAttachmentButton: View {
    let config: HostConnectionConfig
    let connected: Bool
    @Bindable var attachments: FileAttachments
    let onUploaded: (String) -> Void
    @State private var choosing = false

    var body: some View {
        Button { choosing = true } label: {
            Label("Attach Files…", systemImage: "paperclip")
        }
        .disabled(!connected)
        .help("Copy files to this conversation’s computer (up to 100 MB each)")
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result {
            case let .success(urls): attachments.upload(urls, config: config, onUploaded: onUploaded)
            case let .failure(error): attachments.failure = error.localizedDescription
            }
        }
    }
}

struct FileAttachmentStatus: View {
    @Bindable var attachments: FileAttachments

    var body: some View {
        Group {
            if let status = attachments.status {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(status).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 4)
                        if let progress = attachments.progress {
                            Text(progress, format: .percent.precision(.fractionLength(0)))
                                .monospacedDigit()
                        }
                    }
                    .font(.caption)
                    ProgressView(value: attachments.progress)
                        .progressViewStyle(.linear)
                        .accessibilityLabel("File upload progress")
                }
                .padding(12)
                .frame(maxWidth: 320)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .alert("Couldn’t Attach File", isPresented: Binding(
            get: { attachments.failure != nil },
            set: { if !$0 { attachments.failure = nil } }
        )) {
            Button("OK") { attachments.failure = nil }
        } message: { Text(attachments.failure ?? "") }
    }
}
