import AISessionCore
import SwiftUI

struct PromoteSessionSheet: View {
    let host: HostEntity
    let session: RemoteSession
    let onPromoted: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var tool: AITool = .claude
    @State private var slug: String
    @State private var isPromoting = false
    @State private var errorMessage: String?

    init(host: HostEntity, session: RemoteSession, onPromoted: @escaping () -> Void) {
        self.host = host
        self.session = session
        self.onPromoted = onPromoted
        _slug = State(initialValue: Self.slugify(session.slug))
    }

    private var valid: Bool {
        SessionName.isValidSlug(slug.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Tool", selection: $tool) {
                    ForEach(AITool.allCases, id: \.self) { tool in
                        Text(AppTheme.displayName(for: tool)).tag(tool)
                    }
                }
                TextField("Slug", text: $slug)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
                Text("tmux/\(session.tmuxName)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .navigationTitle("Add to Managed")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isPromoting {
                        ProgressView()
                    } else {
                        Button("Add") { promote() }
                            .disabled(!valid)
                            .fontWeight(.semibold)
                    }
                }
            }
            .disabled(isPromoting)
            .alert("Could Not Add Session", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func promote() {
        let trimmedSlug = slug.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let name = SessionName(tool: tool, slug: trimmedSlug) else { return }
        isPromoting = true
        Task {
            defer { isPromoting = false }
            do {
                let connection = try SessionServiceFactory().make(for: host)
                try await connection.service.promoteSession(
                    config: connection.config,
                    fromTmuxName: session.tmuxName,
                    to: name
                )
                onPromoted()
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private static func slugify(_ raw: String) -> String {
        var result = ""
        var lastWasHyphen = true
        for scalar in raw.lowercased().unicodeScalars {
            let value = scalar.value
            if (0x61...0x7A).contains(value) || (0x30...0x39).contains(value) {
                result.unicodeScalars.append(scalar)
                lastWasHyphen = false
            } else if !lastWasHyphen {
                result.append("-")
                lastWasHyphen = true
            }
        }
        while result.hasSuffix("-") { result.removeLast() }
        return result
    }
}
