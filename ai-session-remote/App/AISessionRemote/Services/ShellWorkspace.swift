import Foundation
import Observation

/// Saved shortcuts to tmux shells. The remote process belongs to tmux, so switching views,
/// reconnecting SSH and restarting the app all return to the same shell.
struct WorkspaceShell: Codable, Identifiable, Equatable {
    let id: UUID
    let hostID: UUID
    let computerName: String
    let title: String

    var tmuxName: String { "remote-shell-\(id.uuidString.lowercased())" }
    var label: String { "\(title) · \(computerName)" }
}

@MainActor @Observable
final class ShellWorkspace {
    private(set) var shells: [WorkspaceShell]
    var selectedID: UUID?
    private let defaults: UserDefaults
    private static let key = "shell.workspace.v1"
    private static let selectionKey = "shell.workspace.selection.v1"
    private var rememberedSelection: [UUID: UUID]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        shells = defaults.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode([WorkspaceShell].self, from: $0) } ?? []
        rememberedSelection = defaults.data(forKey: Self.selectionKey)
            .flatMap { try? JSONDecoder().decode([UUID: UUID].self, from: $0) } ?? [:]
    }

    /// Keep a mounted screen's selection, then the last shell used on this host, then its
    /// first shell. A deleted selection or one from another host is never restored.
    func selection(for hostID: UUID, current: UUID? = nil) -> UUID? {
        let available = shells.filter { $0.hostID == hostID }
        if let current, available.contains(where: { $0.id == current }) { return current }
        if let remembered = rememberedSelection[hostID], available.contains(where: { $0.id == remembered }) {
            return remembered
        }
        return available.first?.id
    }

    func rememberSelection(_ id: UUID?, for hostID: UUID) {
        guard let id, shells.contains(where: { $0.id == id && $0.hostID == hostID }),
              rememberedSelection[hostID] != id else { return }
        rememberedSelection[hostID] = id
        save()
    }

    @discardableResult
    func create(hostID: UUID, computerName: String) -> WorkspaceShell {
        let used = Set(shells.filter { $0.hostID == hostID }.map(\.title))
        var number = 1
        while used.contains("Shell \(number)") { number += 1 }
        let shell = WorkspaceShell(id: UUID(), hostID: hostID, computerName: computerName, title: "Shell \(number)")
        shells.append(shell)
        selectedID = shell.id
        rememberedSelection[hostID] = shell.id
        save()
        return shell
    }

    /// Forgetting a shortcut detaches its client; it does not kill work running in tmux.
    func forget(_ shell: WorkspaceShell) {
        shells.removeAll { $0.id == shell.id }
        if selectedID == shell.id { selectedID = nil }
        if rememberedSelection[shell.hostID] == shell.id { rememberedSelection[shell.hostID] = nil }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(shells) { defaults.set(data, forKey: Self.key) }
        if let data = try? JSONEncoder().encode(rememberedSelection) {
            defaults.set(data, forKey: Self.selectionKey)
        }
    }
}
