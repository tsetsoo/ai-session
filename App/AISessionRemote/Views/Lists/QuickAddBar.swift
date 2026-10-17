import AISessionCore
import SwiftUI

/// Quick-add rules that don't need a view.
enum QuickAdd {
    /// `@AppStorage` key of the last section picked on the chip (its raw value).
    static let sectionKey = "quickAdd.section"

    /// The stored section, or I when nothing (or something unknown) is stored.
    static func section(from raw: String) -> TodoSection {
        TodoSection(rawValue: raw) ?? .i
    }

    /// What was typed before dictation started, then what was heard, with one space between.
    static func text(typed: String, dictated: String) -> String {
        guard !typed.isEmpty, !dictated.isEmpty else { return typed + dictated }
        return typed.hasSuffix(" ") ? typed + dictated : typed + " " + dictated
    }
}

/// The field pinned under the Todos list: type (or dictate), pick the section, Return adds.
/// The chip keeps the last section used. Disabled while offline.
struct QuickAddBar: View {
    @Environment(AppModel.self) private var model
    @AppStorage(QuickAdd.sectionKey) private var sectionRaw = TodoSection.i.rawValue
    @State private var title = ""
    @FocusState private var focused: Bool
    /// A short note under the field, e.g. why dictation can't start.
    @State private var note: String?
    #if os(iOS)
    @State private var dictation = Dictation()
    /// The field's text when dictation started; the transcript goes after it.
    @State private var typedBeforeDictation = ""
    #endif

    private var section: TodoSection { QuickAdd.section(from: sectionRaw) }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.spacing.xs) {
            HStack(spacing: DS.spacing.s) {
                // A plain TextField keeps the keyboard's own dictation key.
                TextField("New todo…", text: $title)
                    .focused($focused)
                    .submitLabel(.done)
                    .onSubmit(add)
                    .accessibilityLabel("New todo")
                sectionChip
                #if os(iOS)
                dictateButton
                #endif
            }
            .padding(.leading, DS.spacing.m + 2)
            .padding(.trailing, DS.spacing.xs + 2)
            .padding(.vertical, DS.spacing.xs)
            .frame(minHeight: 44)
            .background(Self.fieldBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            if let note {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, DS.spacing.xs)
            }
        }
        .padding(.horizontal, DS.spacing.l)
        .padding(.vertical, DS.spacing.s + 2)
        .background(Self.barBackground)
        .overlay(alignment: .top) { Divider() }
        .disabled(model.store.isOffline)
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
        .onChange(of: model.store.isOffline) { _, offline in
            if offline { dictation.cancel() }
        }
        .onDisappear { dictation.cancel() }
        #endif
    }

    private var sectionChip: some View {
        Menu {
            Picker("Section", selection: $sectionRaw) {
                ForEach(TodoSection.allCases) { Text($0.rawValue).tag($0.rawValue) }
            }
        } label: {
            HStack(spacing: 3) {
                Text(section.rawValue)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(DS.accentOnTint)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(DS.accentTint, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .accessibilityLabel("Section \(section.rawValue)")
        .accessibilityHint("Changes the section of the new todo")
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
        // Starting counts as running, so a second tap while permission is pending stops it.
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

    private func add() {
        #if os(iOS)
        // Cancel, not stop: a late final result would write the added text back.
        dictation.cancel()
        #endif
        let text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !model.store.isOffline else { return }
        let store = model.store
        let section = section
        title = ""
        // Stay in the field for the next one.
        focused = true
        Task { await store.createTodo(section: section, title: text) }
    }

    /// The list's grouped background, opaque so rows never show through; the white field stands
    /// out on it.
    private static var barBackground: Color {
        #if os(iOS)
        Color(uiColor: .systemGroupedBackground)
        #else
        Color(nsColor: .windowBackgroundColor)
        #endif
    }

    private static var fieldBackground: Color {
        #if os(iOS)
        Color(uiColor: .secondarySystemGroupedBackground)
        #else
        Color(nsColor: .controlBackgroundColor)
        #endif
    }
}

#if os(iOS)
/// The accent-filled round mic button. The glyph is dark on the lighter dark-mode accent so it
/// keeps its contrast, like `AccentButtonStyle`.
private struct DictateButtonStyle: ButtonStyle {
    let isRunning: Bool

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(colorScheme == .dark ? Color(PlatformNativeColor(hex: 0x1C1C1E)) : .white)
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
