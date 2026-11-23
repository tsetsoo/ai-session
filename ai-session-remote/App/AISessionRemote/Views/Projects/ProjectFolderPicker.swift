import AISessionCore
import SwiftUI

/// SSH paths belong to the project's computer, even when browsing from a different device.
struct ProjectFolderPicker: View {
    let computer: Computer
    let config: HostConnectionConfig
    let initialFolder: String
    let registeredFolders: Set<String>
    let onSelect: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var folder: String?
    @State private var browsedFolder: String?
    @State private var directories: [String] = []
    @State private var repositories: [String] = []
    @State private var error: String?
    @State private var lastFolder: String?
    @State private var retryCount = 0
    @State private var scanning = false

    private var requestedFolder: String { folder ?? initialFolder }

    var body: some View {
        NavigationStack {
            List {
                if let error {
                    Text(error).foregroundStyle(DS.error)
                    Button("Retry") { retryCount += 1 }
                    if let lastFolder, lastFolder != requestedFolder {
                        Button("Go Back") { folder = lastFolder }
                    }
                    Button("Go to Home") { folder = "~" }
                        .disabled(requestedFolder == "~")
                } else if let browsedFolder {
                    if scanning || !repositories.isEmpty {
                        Section("Git Repositories") {
                            if scanning {
                                ProgressView("Finding repositories…")
                            }
                            ForEach(repositories, id: \.self) { path in
                                Button { select(path) } label: {
                                    Label(path, systemImage: "arrow.triangle.branch")
                                }
                            }
                        }
                    }
                    Section {
                        if let parent = parent(of: browsedFolder) {
                            Button { folder = parent } label: {
                                Label("Parent Folder", systemImage: "arrow.up")
                            }
                        }
                        ForEach(directories, id: \.self) { path in
                            Button { folder = path } label: {
                                Label(pathName(path), systemImage: "folder")
                            }
                        }
                    } header: {
                        Text(browsedFolder).textCase(nil)
                    }
                } else {
                    ProgressView("Reading folders…")
                }
            }
            .skinnedList()
            .navigationTitle("Choose Folder on \(computer.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Choose This Folder") {
                        if let browsedFolder { select(browsedFolder) }
                    }
                    .disabled(browsedFolder == nil)
                }
            }
            .task(id: Request(folder: requestedFolder, retry: retryCount)) { await load(requestedFolder) }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 460)
        #endif
    }

    private struct Request: Equatable {
        let folder: String
        let retry: Int
    }

    private func select(_ path: String) {
        onSelect(path)
        dismiss()
    }

    private func pathName(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    private func parent(of path: String) -> String? {
        if path == "/" { return nil }
        if path == "~" { return "/" }
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }

    private func load(_ path: String) async {
        browsedFolder = nil
        error = nil
        repositories = []
        scanning = false
        let client = NIOSSHClient()
        do {
            let result = try await client.exec(config, command: TmuxCommandBuilder.browseProjectFolders(path))
            try Task.checkCancellation()
            try RemoteConversations.check(result, computerName: computer.name)
            let paths = result.stdout.split(separator: "\0").map(String.init)
            guard let current = paths.first else {
                error = "The computer returned no folder."
                return
            }
            directories = paths.dropFirst().sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            browsedFolder = current
            lastFolder = current
            scanning = true
            defer { if !Task.isCancelled { scanning = false } }
            if let result = try? await client.exec(config, command: TmuxCommandBuilder.discoverProjectRepositories(in: current)),
               !Task.isCancelled {
                let prefix = current.hasSuffix("/") ? current : current + "/"
                repositories = result.stdout.split(separator: "\0")
                    .filter { $0.hasPrefix("./") && $0.hasSuffix("/.git") }
                    .map { $0 == "./.git" ? current : prefix + $0.dropFirst(2).dropLast(5) }
                    .filter { !registeredFolders.contains($0) }
                    .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            }
        } catch {
            guard !Task.isCancelled else { return }
            self.error = TodoHubStore.message(for: error)
        }
    }
}
