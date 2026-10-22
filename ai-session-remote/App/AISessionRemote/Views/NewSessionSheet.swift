import AISessionCore
import SwiftUI

struct NewSessionSheet: View {
    let host: HostEntity
    /// Called once the remote tmux session actually exists, right before this sheet dismisses
    /// itself — the caller is responsible for navigating to the terminal (see
    /// `SessionsListView`'s `pendingSession`), since a sheet is the wrong place to push a
    /// `NavigationStack` destination that needs to outlive it.
    let onCreated: (SessionName) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var tool: AITool
    @State private var path: String
    @State private var slug: String
    @State private var isStarting = false
    @State private var errorMessage: String?
    @State private var showingHostEditor = false
    @State private var canEditHost = false

    init(host: HostEntity, onCreated: @escaping (SessionName) -> Void) {
        self.host = host
        self.onCreated = onCreated
        let initialTool = host.preferredTool ?? .claude
        let initialPath = host.lastUsedPath ?? host.defaultPaths.first ?? ""
        _tool = State(initialValue: initialTool)
        _path = State(initialValue: initialPath)
        _slug = State(initialValue: Self.slugify(initialPath.split(separator: "/").last.map(String.init) ?? ""))
    }

    private var trimmedSlug: String {
        slug.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedPath: String {
        path.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var slugIsInvalid: Bool {
        !trimmedSlug.isEmpty && !SessionName.isValidSlug(trimmedSlug)
    }

    private var computerName: String {
        host.displayName.isEmpty ? host.hostname : host.displayName
    }

    private var canStart: Bool {
        !isStarting
            && !trimmedPath.isEmpty
            && !trimmedSlug.isEmpty
            && !slugIsInvalid
    }

    private var toolHint: String {
        switch tool {
        case .shell:
            return "Starts a shell in a new session. It keeps running after you leave."
        case .claude, .codex, .cursor:
            return "Starts \(AppTheme.displayName(for: tool)) in a new session."
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Tool", selection: $tool) {
                        ForEach(AITool.allCases, id: \.self) { tool in
                            Text(AppTheme.displayName(for: tool)).tag(tool)
                        }
                    }
                    .pickerStyle(.segmented)

                    HStack(spacing: 10) {
                        ToolIcon(tool: tool.rawValue, side: 22)
                        Text(toolHint)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Tool")
                }

                Section {
                    TextField("/path/to/project", text: $path)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())

                    if !host.defaultPaths.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(host.defaultPaths, id: \.self) { bookmark in
                                    Button {
                                        path = bookmark
                                        slug = Self.slugify(
                                            bookmark.split(separator: "/").last.map(String.init) ?? ""
                                        )
                                    } label: {
                                        Text(shortPathLabel(bookmark))
                                            .font(.caption.weight(.medium))
                                    }
                                    .buttonStyle(.bordered)
                                    .tint(path == bookmark ? AppTheme.color(for: tool) : .secondary)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                } header: {
                    Text("Folder")
                } footer: {
                    Text("Starts in this folder on \(computerName).")
                }

                Section {
                    TextField("Name", text: $slug)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                    if slugIsInvalid {
                        Label("Use lowercase letters, numbers, and hyphens only.", systemImage: "exclamationmark.circle")
                            .font(.caption)
                            .foregroundStyle(DS.error)
                    }
                } header: {
                    Text("Name")
                } footer: {
                    Text("Shown in the list. Each name can be used once per tool on \(computerName).")
                }
            }
            .navigationTitle("New Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isStarting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isStarting {
                        ProgressView()
                    } else {
                        Button("Start", action: start)
                            .disabled(!canStart)
                            .fontWeight(.semibold)
                    }
                }
            }
            .interactiveDismissDisabled(isStarting)
            .disabled(isStarting)
            .overlay {
                if isStarting {
                    ZStack {
                        Color.black.opacity(0.12).ignoresSafeArea()
                        VStack(spacing: 12) {
                            ProgressView()
                            Text("Starting session…")
                                .font(.subheadline.weight(.medium))
                        }
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Starting session")
                }
            }
            .alert("Could not start session", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                if canEditHost {
                    Button("Edit Access…") { showingHostEditor = true }
                }
                Button("OK", role: .cancel) { canEditHost = false }
            } message: {
                Text(errorMessage ?? "")
            }
            .sheet(isPresented: $showingHostEditor) {
                HostEditorView(host: host)
            }
        }
    }

    private func shortPathLabel(_ path: String) -> String {
        if let last = path.split(separator: "/").last, !last.isEmpty {
            return String(last)
        }
        return path
    }

    private func start() {
        let pathToUse = trimmedPath
        let slugToUse = trimmedSlug
        guard !pathToUse.isEmpty, !slugToUse.isEmpty else { return }
        guard SessionName.isValidSlug(slugToUse) else {
            canEditHost = false
            errorMessage = "\"\(slugToUse)\" is not a valid session name. Use lowercase letters, numbers, and hyphens only."
            return
        }
        isStarting = true

        Task {
            defer { isStarting = false }
            do {
                let connection = try SessionServiceFactory().make(for: host)
                try await connection.service.probeTmux(config: connection.config)
                let session = try await connection.service.createSession(
                    config: connection.config,
                    tool: tool,
                    slug: slugToUse,
                    cwd: pathToUse,
                    title: nil
                )
                host.preferredTool = tool
                host.lastUsedPath = pathToUse
                try? modelContext.save()
                onCreated(session)
                dismiss()
            } catch {
                canEditHost = ComputerErrorText.isAccessProblem(error)
                errorMessage = ComputerErrorText.message(for: error, computer: computerName)
            }
        }
    }

    /// Normalizes a raw path segment into a slug `SessionName` will accept: lowercase, with any
    /// run of characters outside `[a-z0-9-]` collapsed to a single hyphen, and no leading/trailing
    /// hyphens. Used for the slug derived from a working directory so the field starts valid
    /// instead of silently failing at submit time (e.g. `My_Project` -> `my-project`).
    private static func slugify(_ raw: String) -> String {
        var result = ""
        var lastWasHyphen = true // avoid leading hyphen
        for scalar in raw.lowercased().unicodeScalars {
            let value = scalar.value
            let isLowercaseASCII = value >= 0x61 && value <= 0x7A
            let isDigitASCII = value >= 0x30 && value <= 0x39
            if isLowercaseASCII || isDigitASCII {
                result.unicodeScalars.append(scalar)
                lastWasHyphen = false
            } else if !lastWasHyphen {
                result.append("-")
                lastWasHyphen = true
            }
        }
        while result.hasSuffix("-") {
            result.removeLast()
        }
        return result
    }
}
