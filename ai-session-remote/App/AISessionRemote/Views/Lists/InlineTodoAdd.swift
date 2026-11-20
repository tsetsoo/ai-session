import AISessionCore
import SwiftUI

/// Expands an Add Todo row into a title field for this project.
struct InlineTodoAdd: View {
    let project: Project

    @Environment(AppModel.self) private var model
    @State private var draft = TodoAddDraft()
    @FocusState private var focused: Bool
    @State private var isExpanded = false
    /// Set by `expand()`: the title field takes focus once it is in the list.
    @State private var focusWhenShown = false

    private var store: TodoHubStore { model.store }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.spacing.xs) {
            if !isExpanded {
                Button(action: expand) {
                    Label("Add Todo", systemImage: "plus")
                        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
            } else {
                formHeader
                HStack(alignment: .firstTextBaseline, spacing: DS.spacing.s) {
                    TodoTitleField(title: $draft.title, focused: $focused, onSubmit: submit)
                    // Borderless: in a list row a plain button would take the whole row's taps.
                    Button("Add", action: submit)
                        .buttonStyle(.borderless)
                        .disabled(!draft.canSubmit(hasComputer: true, lockedProjectID: project.id))
                }
                .onAppear {
                    guard focusWhenShown else { return }
                    focusWhenShown = false
                    // A list row's field can't take focus in the pass that inserts it.
                    Task { @MainActor in focused = true }
                }
            }
            if let localError = draft.localError {
                Text(localError)
                    .font(.footnote)
                    .foregroundStyle(DS.error)
            }
        }
        .selectionDisabled()
        .disabled(store.isOffline)
        .focusedValue(\.isEditingTodoText, isExpanded ? true : nil)
    }

    private var formHeader: some View {
        HStack(spacing: DS.spacing.s) {
            Text("New todo on \(project.computer.name)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: DS.spacing.s)
            Button("Cancel", action: collapse)
                .buttonStyle(.borderless)
                .font(.caption)
        }
    }

    private func expand() {
        draft.localError = nil
        if isExpanded {
            focused = true
        } else {
            focusWhenShown = true
            withAnimation { isExpanded = true }
        }
    }

    /// Cancel, or after a successful add: the typed title goes with it.
    private func collapse() {
        focused = false
        draft.title = ""
        draft.localError = nil
        withAnimation { isExpanded = false }
    }

    private func submit() {
        Task {
            if await draft.submit(store: store, section: project.section, hasComputer: true,
                                  lockedProjectID: project.id) {
                collapse()
            }
        }
    }
}

/// The title of a new todo. Multiline, so the text stays visible while typing. On iPhone the
/// mic sits on the field.
struct TodoTitleField: View {
    @Binding var title: String
    var focused: FocusState<Bool>.Binding
    var onSubmit: () -> Void
    var placeholder = "Title"
    /// Lines the field keeps open while empty (the New Todo sheet asks for more than a row).
    var minLines = 1

    @State private var note: String?
    #if os(iOS)
    @State private var dictation = Dictation()
    @State private var typedBeforeDictation = ""
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: DS.spacing.xs) {
            HStack(alignment: .top, spacing: DS.spacing.xs) {
                FormTextField(placeholder, text: $title, axis: .vertical)
                    .lineLimit(minLines...max(minLines, 8))
                    .focused(focused)
                    .onSubmit(onSubmit)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity, minHeight: 28)
                #if os(iOS)
                dictateButton
                #endif
            }
            if let note {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .onChange(of: title) { _, _ in
            #if os(iOS)
            if dictation.isRunning { return }
            #endif
            note = nil
        }
        #if os(iOS)
        .onChange(of: dictation.transcript) { _, transcript in
            title = QuickAdd.text(typed: typedBeforeDictation, dictated: transcript)
        }
        .onDisappear { dictation.cancel() }
        #endif
    }

    #if os(iOS)
    private var dictateButton: some View {
        Button(action: toggleDictation) {
            Image(systemName: dictation.isRunning ? "stop.fill" : "mic.fill")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 34, height: 34)
        }
        .buttonStyle(DictateButtonStyle(isRunning: dictation.isRunning))
        .accessibilityLabel(dictation.isRunning ? "Stop Dictation" : "Dictate")
    }

    private func toggleDictation() {
        if dictation.isRunning {
            dictation.stop()
            return
        }
        note = nil
        typedBeforeDictation = title
        Task {
            do {
                try await dictation.start()
            } catch {
                note = (error as? Dictation.Failure)?.errorDescription ?? Dictation.Failure.unavailable.errorDescription
            }
        }
    }
    #endif
}

#if os(iOS)
private struct DictateButtonStyle: ButtonStyle {
    let isRunning: Bool

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(DS.onAccent)
            .background(DS.accent, in: Circle())
            .overlay {
                if isRunning {
                    Circle().stroke(DS.accent.opacity(0.35), lineWidth: 4).padding(-3)
                }
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
    }
}
#endif
