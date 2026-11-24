import AISessionCore
import SwiftUI

// Today: the morning briefing live, reminders, and people's dates. The Mac shows them as a
// third mode (sidebar, list, form); the phone as its own tab.

// MARK: - Mac columns

struct TodaySidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List(selection: Binding<TodayItem?>(get: { model.todayItem }, set: { if let item = $0 { model.todayItem = item; model.todaySelection = nil } })) {
            ForEach(TodayItem.allCases) { item in
                Label(item.title, systemImage: item.systemImage)
                    .badge(item == .reminders ? model.store.dueReminderCount : 0)
                    .tag(item)
            }
        }
        .skinnedList()
        .navigationTitle("Today")
    }
}

struct TodayListColumn: View {
    @Environment(AppModel.self) private var model
    let onOpenTodo: (String) -> Void
    let onOpenConversation: (Conversation) -> Void

    var body: some View {
        @Bindable var model = model
        Group {
            switch model.todayItem {
            case .today:
                TodaySummaryList(store: model.store, onOpenTodo: onOpenTodo, onOpenConversation: onOpenConversation, onShow: { item in
                    model.todayItem = item
                })
            case .reminders:
                RemindersList(store: model.store, selection: $model.todaySelection)
            case .people:
                PeopleList(store: model.store, selection: $model.todaySelection)
            case .weekly:
                // The recaps need the wide pane: they're in the detail column.
                AutomationEmpty(text: "Each Monday morning, last week's recap is written from your projects' daily updates and the scheduled jobs.")
                    .navigationTitle("Weekly")
            }
        }
        .task(id: model.store.revision) { await model.store.loadToday() }
    }
}

struct TodayDetailColumn: View {
    @Environment(AppModel.self) private var model
    let onOpenTodo: (String) -> Void
    /// Weekly's days: a project's page on that day of its Updates.
    let onOpenDay: (String, String) -> Void

    var body: some View {
        let store = model.store
        switch model.todayItem {
        case .today:
            TodaySettingsPane(store: store)
        case .reminders:
            if let id = model.todaySelection {
                ReminderFormPane(store: store, reminder: store.reminders.first { $0.id == id }) { model.todaySelection = $0 }
                    .id(id)
            } else {
                AutomationEmpty(text: "Choose a reminder, or press + to add one.")
            }
        case .people:
            if let id = model.todaySelection {
                PersonFormPane(store: store, person: store.people.first { $0.id == id }) { model.todaySelection = $0 }
                    .id(id)
            } else {
                AutomationEmpty(text: "Choose a person, or press + to add one.")
            }
        case .weekly:
            WeeklyView(store: store, onOpenTodo: onOpenTodo, onOpenDay: onOpenDay)
        }
    }
}

// MARK: - Today summary

/// Today’s action items, morning briefing, and open conversations.
struct TodaySummaryList: View {
    private typealias ConversationItem = (conversation: Conversation, todo: Todo)

    @Environment(AppModel.self) private var model
    let store: TodoHubStore
    let onOpenTodo: (String) -> Void
    let onOpenConversation: (Conversation) -> Void
    /// Opens Reminders or People.
    let onShow: (TodayItem) -> Void
    /// The phone's "Last week's recap" row on Mondays (Sofia); the Mac has Weekly in the sidebar.
    var showsWeeklyRow = false
    var onOpenDay: (String, String) -> Void = { _, _ in }
    @State private var collapsedProjects: Set<String?> = []

    var body: some View {
        let board = model.board
        let todos = Dictionary(store.todos.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        List {
            attentionSection(board, todos: todos)
            if showsWeeklyRow && WeeklyRecap.isRecapDay(.now) {
                NavigationLink { WeeklyView(store: store, onOpenTodo: onOpenTodo, onOpenDay: onOpenDay) } label: {
                    Label("Last week's recap", systemImage: "calendar.badge.checkmark")
                }
            }
            if let b = store.briefing {
                if b.isEmpty && store.reminders.filter(\.isDue).isEmpty && board.open.isEmpty {
                    Label("Nothing for today.", systemImage: "sun.max").foregroundStyle(.secondary)
                }
                let upcoming = b.reminders.filter { !$0.isDue }
                if !upcoming.isEmpty {
                    Section("Reminders today") {
                        ForEach(upcoming) { r in
                            Button { onShow(.reminders) } label: {
                                LabeledContent(r.title, value: r.time)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .skinnedRows()
                }
                if !b.dates.isEmpty {
                    Section("Dates") {
                        ForEach(b.dates, id: \.self) { d in
                            Button { onShow(.people) } label: { Label(d, systemImage: "gift") }.buttonStyle(.plain)
                        }
                    }
                    .skinnedRows()
                }
                if !b.watch.isEmpty {
                    Section("Also") {
                        Label(watchText(b.watch), systemImage: "exclamationmark.triangle")
                    }
                    .skinnedRows()
                }
            } else {
                Text("Today needs a newer hub.").foregroundStyle(.secondary)
            }
            openConversations(board, todos: todos)
        }
        .skinnedList()
        .navigationTitle("Today")
    }

    @ViewBuilder
    private func attentionSection(_ board: ConversationBoard, todos: [String: Todo]) -> some View {
        let due = store.reminders.filter(\.isDue)
        let conversations = conversationItems(board.needsYou + board.review, todos: todos)
        let liveReviewTodos = Set(board.review.map(\.todoId))
        let otherReviewItems = store.briefing?.readyForReview.filter { !liveReviewTodos.contains($0.todoId) } ?? []
        if !due.isEmpty || !conversations.isEmpty || !otherReviewItems.isEmpty {
            Section("Needs your attention") {
                ForEach(due) { ReminderDueRow(store: store, reminder: $0) }
                ForEach(conversations, id: \.conversation.listKey) { row in
                    Button { onOpenConversation(row.conversation) } label: {
                        LabeledContent(
                            RowText.conversationTitle(todoTitle: row.todo.title, label: row.conversation.label),
                            value: board.status(of: row.conversation).label
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                ForEach(otherReviewItems, id: \.todoId) { item in
                    Button { onOpenTodo(item.todoId) } label: {
                        LabeledContent(item.title, value: "Ready for review")
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .skinnedRows()
        }
    }

    private func conversationItems(_ conversations: [Conversation], todos: [String: Todo]) -> [ConversationItem] {
        conversations.compactMap { conversation in
            todos[conversation.todoId].map { (conversation: conversation, todo: $0) }
        }
    }

    @ViewBuilder
    private func openConversations(_ board: ConversationBoard, todos: [String: Todo]) -> some View {
        let projectIDs = Set(store.projects.map(\.id))
        let rows = conversationItems(board.open, todos: todos)
        let groups = Dictionary(grouping: rows) { row in
            row.todo.projectId.flatMap { projectIDs.contains($0) ? $0 : nil }
        }
        if !groups.isEmpty {
            Section("Open conversations") {
                ForEach(store.projects) { project in
                    if let rows = groups[project.id] {
                        DisclosureGroup("\(project.name) (\(rows.count))", isExpanded: projectExpanded(project.id)) {
                            conversationRows(rows, board: board)
                        }
                    }
                }
                if let rows = groups[nil] {
                    DisclosureGroup("No project (\(rows.count))", isExpanded: projectExpanded(nil)) {
                        conversationRows(rows, board: board)
                    }
                }
            }
            .skinnedRows()
        }
    }

    private func projectExpanded(_ projectID: String?) -> Binding<Bool> {
        Binding(get: { !collapsedProjects.contains(projectID) }, set: { expanded in
            if expanded {
                collapsedProjects.remove(projectID)
            } else {
                collapsedProjects.insert(projectID)
            }
        })
    }

    private func conversationRows(_ rows: [ConversationItem], board: ConversationBoard) -> some View {
        ForEach(rows, id: \.conversation.listKey) { row in
            Button { onOpenConversation(row.conversation) } label: {
                ConversationRow(
                    title: RowText.conversationTitle(todoTitle: row.todo.title, label: row.conversation.label),

                    conversation: row.conversation,
                    status: board.status(of: row.conversation),
                    isBusy: false
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func watchText(_ w: WatchCounts) -> String {
        let parts = [(w.fixed, "fixed, waiting for your merge"), (w.needsYou, "need you"), (w.waiting, "waiting"),
                     (w.working, "being worked on"), (w.cantFix, "can't be fixed"), (w.resolving, "resolving")]
            .filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }
        return "Watchers: " + parts.joined(separator: ", ")
    }
}

struct ReminderDueRow: View {
    let store: TodoHubStore
    let reminder: Reminder
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(reminder.title).font(.body.weight(.medium))
                    Text("\(reminder.day) \(reminder.time)" + (reminder.repeat == .none ? "" : " · \(reminder.repeat.label)"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { act { try await store.doneReminder(id: reminder.id) } }
                    .buttonStyle(.borderedProminent)
                Menu("Snooze") {
                    ForEach(SnoozeOption.available()) { option in
                        Button(option.label) { act { try await store.snoozeReminder(id: reminder.id, option) } }
                    }
                }
                .fixedSize()
            }
            if !reminder.notes.isEmpty { Text(reminder.notes).font(.callout).foregroundStyle(.secondary) }
            if let error { Text(error).font(.caption).foregroundStyle(DS.warning) }
        }
        .padding(.vertical, 2)
    }

    private func act(_ action: @escaping () async throws -> Void) {
        Task {
            do { try await action() } catch { self.error = error.localizedDescription }
        }
    }
}

/// The briefing's settings and the assistant's model.
struct TodaySettingsPane: View {
    let store: TodoHubStore
    @State private var error: String?
    /// The picker's time; saved once it stops changing (typing a time doesn't save each digit).
    @State private var briefingTime: Date?
    @State private var pendingSave: Task<Void, Never>?

    var body: some View {
        Form {
            if let s = store.todaySettings {
                Section {
                    Toggle("Morning notifications", isOn: Binding(get: { s.briefingEnabled }, set: { on in save(TodaySettingsUpdate(briefingEnabled: on)) }))
                    LabeledContent("Morning reminders", value: "09:00 Sofia time")
                    DatePicker("General briefing", selection: Binding(get: { briefingTime ?? time(s.briefingTime) }, set: { new in
                        briefingTime = new
                        pendingSave?.cancel()
                        pendingSave = Task {
                            try? await Task.sleep(for: .seconds(1.5))
                            guard !Task.isCancelled, hhmm(new) != s.briefingTime else { return }
                            save(TodaySettingsUpdate(briefingTime: hhmm(new)))
                        }
                    }), displayedComponents: .hourAndMinute)
                        .environment(\.timeZone, TodayTime.zone)
                        .disabled(!s.briefingEnabled)
                } header: {
                    Text("Morning")
                } footer: {
                    Text("The 09:00 summary covers today’s and overdue reminders. The general briefing covers dates, results ready for review, conversations that need you, and watcher issues. Both use Sofia time and skip empty summaries.")
                }
                .skinnedRows()
                Section {
                    Picker("Model", selection: Binding(get: { s.assistantModel }, set: { save(TodaySettingsUpdate(assistantModel: $0)) })) {
                        Text("Auto (more weekly headroom)").tag("auto")
                        Text("Claude \(s.claudeModel.capitalized)").tag("claude")
                        Text("Codex \(s.codexModel)").tag("codex")
                    }
                } header: {
                    Text("Add with an agent")
                } footer: {
                    Text("Auto picks whichever of Claude \(s.claudeModel) and \(s.codexModel) has more weekly usage left on that Mac.")
                }
                .skinnedRows()
            } else {
                Text("Today needs a newer hub.").foregroundStyle(.secondary)
            }
            if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(DS.warning) }
        }
        .skinnedList()
        .formStyle(.grouped)
        .navigationTitle("Today settings")
    }

    private func save(_ update: TodaySettingsUpdate) {
        Task {
            do { try await store.updateTodaySettings(update) } catch { self.error = error.localizedDescription }
        }
    }

    private func time(_ hhmm: String) -> Date {
        let day = TodayTime.wallClock(.now).prefix(10)
        return TodayTime.date(fromWallClock: "\(day) \(hhmm)") ?? .now
    }

    private func hhmm(_ date: Date) -> String {
        String(TodayTime.wallClock(date).suffix(5))
    }
}

// MARK: - Reminders

struct RemindersList: View {
    let store: TodoHubStore
    @Binding var selection: String?
    @State private var assistant = false

    var body: some View {
        List(selection: $selection) {
            RemindersListContent(store: store) { r in ReminderRow(reminder: r).tag(r.id) }
        }
        .skinnedList()
        .navigationTitle("Reminders")
        .toolbar {
            ToolbarItemGroup {
                Button { assistant = true } label: { Label("Add with an Agent", systemImage: "bubble.left.and.text.bubble.right") }
                Button { selection = "new" } label: { Label("New Reminder", systemImage: "plus") }
            }
        }
        .sheet(isPresented: $assistant) { AssistantSheet(store: store, kind: "reminder") }
    }
}

/// Due, then upcoming, then done this week.
struct RemindersListContent<Row: View>: View {
    let store: TodoHubStore
    @ViewBuilder let row: (Reminder) -> Row

    var body: some View {
        if store.reminders.isEmpty {
            Text("No reminders yet.").foregroundStyle(.secondary)
        }
        let due = store.reminders.filter(\.isDue)
        if !due.isEmpty { Section("Due") { ForEach(due) { row($0) } }
        .skinnedRows() }
        let upcoming = store.reminders.filter { $0.state == "upcoming" }
        if !upcoming.isEmpty { Section("Upcoming") { ForEach(upcoming) { row($0) } }
        .skinnedRows() }
        let done = store.reminders.filter(\.isDone)
        if !done.isEmpty { Section("Done this week") { ForEach(done) { row($0) } }
        .skinnedRows() }
    }
}

struct ReminderRow: View {
    let reminder: Reminder

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(reminder.title).strikethrough(reminder.isDone)
            HStack(spacing: 6) {
                Text("\(reminder.day) \(reminder.time)")
                if reminder.repeat != .none { Label(reminder.repeat.label, systemImage: "repeat") }
                if reminder.source == "agent" { Image(systemName: "sparkles").accessibilityLabel("Added by an agent") }
            }
            .font(.caption).foregroundStyle(reminder.isDue ? DS.warning : .secondary)
        }
    }
}

/// New (`reminder` nil) or edit.
struct ReminderFormPane: View {
    let store: TodoHubStore
    let reminder: Reminder?
    /// The saved reminder's id, or nil when deleted or cancelled.
    let onDone: (String?) -> Void

    @State private var draft = ReminderDraft()
    @State private var loaded = false
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        Form {
            Section(reminder == nil ? "New reminder" : "Reminder") {
                TextField("Title", text: $draft.title)
                DatePicker("When", selection: $draft.date)
                    .environment(\.timeZone, TodayTime.zone)
                Picker("Repeat", selection: $draft.repeat) {
                    ForEach(ReminderRepeat.allCases) { Text($0.label).tag($0) }
                }
                TextField("Notes", text: $draft.notes, axis: .vertical).lineLimit(2...6)
            }
            .skinnedRows()
            if let reminder, reminder.isDue {
                Section {
                    ReminderDueRow(store: store, reminder: reminder)
                }
                .skinnedRows()
            }
            if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(DS.warning) }
            Section {
                HStack {
                    Button(reminder == nil ? "Add" : "Save") { save() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!draft.canSave || saving || store.isOffline)
                    if let reminder {
                        Button("Delete", role: .destructive) {
                            Task {
                                do { try await store.deleteReminder(id: reminder.id); onDone(nil) } catch { self.error = error.localizedDescription }
                            }
                        }
                    }
                }
            }
            .skinnedRows()
        }
        .skinnedList()
        .formStyle(.grouped)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            if let reminder { draft = ReminderDraft(reminder: reminder) }
        }
    }

    private func save() {
        saving = true
        Task {
            do { onDone(try await store.saveReminder(id: reminder?.id, draft.request)) } catch { self.error = error.localizedDescription }
            saving = false
        }
    }
}

// MARK: - People

struct PeopleList: View {
    let store: TodoHubStore
    @Binding var selection: String?
    @State private var assistant = false

    var body: some View {
        List(selection: $selection) {
            PeopleListContent(store: store) { p in PersonRow(person: p).tag(p.id) }
        }
        .skinnedList()
        .navigationTitle("People & Dates")
        .toolbar {
            ToolbarItemGroup {
                Button { assistant = true } label: { Label("Add with an Agent", systemImage: "bubble.left.and.text.bubble.right") }
                Button { selection = "new" } label: { Label("New Date", systemImage: "plus") }
            }
        }
        .sheet(isPresented: $assistant) { AssistantSheet(store: store, kind: "person") }
    }
}

struct PeopleListContent<Row: View>: View {
    let store: TodoHubStore
    @ViewBuilder let row: (Person) -> Row

    var body: some View {
        if store.people.isEmpty { Text("No dates yet.").foregroundStyle(.secondary) }
        ForEach(store.people) { row($0) }
    }
}

struct PersonRow: View {
    let person: Person

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(person.name)
            HStack(spacing: 6) {
                Text(person.kind.label)
                Text(person.dateText)
                if let turns = person.turns, person.kind != .other { Text("· \(turns) on \(person.nextDate)") } else { Text("· next \(person.nextDate)") }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct PersonFormPane: View {
    let store: TodoHubStore
    let person: Person?
    let onDone: (String?) -> Void

    @State private var draft = PersonDraft()
    @State private var loaded = false
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        Form {
            Section(person == nil ? "New date" : "Date") {
                TextField("Name", text: $draft.name)
                Picker("Kind", selection: $draft.kind) {
                    ForEach(PersonKind.allCases) { Text($0.label).tag($0) }
                }
                Picker("Month", selection: $draft.month) {
                    ForEach(1...12, id: \.self) { Text(Calendar.current.monthSymbols[$0 - 1]).tag($0) }
                }
                Stepper("Day: \(draft.day)", value: $draft.day, in: 1...31)
                Toggle("Year known", isOn: $draft.hasYear)
                if draft.hasYear {
                    Stepper("Year: \(String(draft.year))", value: $draft.year, in: 1900...2100)
                }
                TextField("Notes", text: $draft.notes, axis: .vertical).lineLimit(2...6)
            }
            .skinnedRows()
            if !draft.canSave && !draft.name.isEmpty {
                Label("That's not a real date.", systemImage: "calendar.badge.exclamationmark").foregroundStyle(DS.warning)
            }
            if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(DS.warning) }
            Section {
                HStack {
                    Button(person == nil ? "Add" : "Save") { save() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!draft.canSave || saving || store.isOffline)
                    if let person {
                        Button("Delete", role: .destructive) {
                            Task {
                                do { try await store.deletePerson(id: person.id); onDone(nil) } catch { self.error = error.localizedDescription }
                            }
                        }
                    }
                }
            }
            .skinnedRows()
        }
        .skinnedList()
        .formStyle(.grouped)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            if let person { draft = PersonDraft(person: person) }
        }
    }

    private func save() {
        saving = true
        Task {
            do { onDone(try await store.savePerson(id: person?.id, draft.request)) } catch { self.error = error.localizedDescription }
            saving = false
        }
    }
}

// MARK: - Add with an agent

/// The starting text for the assistant's short conversation.
struct AssistantSheet: View {
    let store: TodoHubStore
    /// `reminder` or `person`.
    let kind: String

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var error: String?
    @State private var started = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(kind == "person" ? "Maria's birthday is 14 March, she turns 36…" : "Dentist next Tuesday morning, and pay rent on the 1st…",
                              text: $text, axis: .vertical)
                        .lineLimit(3...8)
                } footer: {
                    Text("A short conversation on a cheap model reads this, asks if something is unclear, and adds it. It starts within a minute and appears under Conversations.")
                }
                .skinnedRows()
                if started {
                    Label("Started. Answer its questions in the conversation.", systemImage: "checkmark.circle")
                }
                if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(DS.warning) }
            }
            .skinnedList()
            .formStyle(.grouped)
            .navigationTitle("Add with an agent")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(started ? "Close" : "Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") {
                        Task {
                            do {
                                try await store.startAssistant(text: text, kind: kind)
                                started = true
                            } catch { self.error = error.localizedDescription }
                        }
                    }
                    .disabled(started || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isOffline)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 280)
        #endif
    }
}

// MARK: - Phone

struct PhoneTodayRoot: View {
    let store: TodoHubStore
    let onOpenTodo: (String) -> Void
    let onOpenConversation: (Conversation) -> Void
    let onOpenDay: (String, String) -> Void

    var body: some View {
        TodaySummaryList(store: store, onOpenTodo: onOpenTodo, onOpenConversation: onOpenConversation,
                         onShow: { _ in }, showsWeeklyRow: true, onOpenDay: onOpenDay)
            .safeAreaInset(edge: .bottom) { EmptyView() }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        NavigationLink { PhoneReminders(store: store) } label: { Label("Reminders", systemImage: "bell") }
                        NavigationLink { PhonePeople(store: store) } label: { Label("People & Dates", systemImage: "person.2") }
                        NavigationLink { WeeklyView(store: store, onOpenTodo: onOpenTodo, onOpenDay: onOpenDay) } label: { Label("Weekly", systemImage: "calendar.badge.checkmark") }
                        NavigationLink { TodaySettingsPane(store: store) } label: { Label("Settings", systemImage: "gearshape") }
                    } label: { Label("More", systemImage: "list.bullet") }
                }
            }
            .task(id: store.revision) { await store.loadToday() }
    }
}

private struct PhoneReminders: View {
    let store: TodoHubStore
    @State private var assistant = false

    var body: some View {
        List {
            RemindersListContent(store: store) { r in
                NavigationLink { PhoneReminderForm(store: store, reminder: r) } label: { ReminderRow(reminder: r) }
            }
        }
        .skinnedList()
        .navigationTitle("Reminders")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { assistant = true } label: { Label("Add with an Agent", systemImage: "bubble.left.and.text.bubble.right") }
                NavigationLink { PhoneReminderForm(store: store, reminder: nil) } label: { Label("New Reminder", systemImage: "plus") }
            }
        }
        .sheet(isPresented: $assistant) { AssistantSheet(store: store, kind: "reminder") }
    }
}

private struct PhoneReminderForm: View {
    let store: TodoHubStore
    let reminder: Reminder?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ReminderFormPane(store: store, reminder: reminder) { _ in dismiss() }
    }
}

private struct PhonePeople: View {
    let store: TodoHubStore
    @State private var assistant = false

    var body: some View {
        List {
            PeopleListContent(store: store) { p in
                NavigationLink { PhonePersonForm(store: store, person: p) } label: { PersonRow(person: p) }
            }
        }
        .skinnedList()
        .navigationTitle("People & Dates")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { assistant = true } label: { Label("Add with an Agent", systemImage: "bubble.left.and.text.bubble.right") }
                NavigationLink { PhonePersonForm(store: store, person: nil) } label: { Label("New Date", systemImage: "plus") }
            }
        }
        .sheet(isPresented: $assistant) { AssistantSheet(store: store, kind: "person") }
    }
}

private struct PhonePersonForm: View {
    let store: TodoHubStore
    let person: Person?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        PersonFormPane(store: store, person: person) { _ in dismiss() }
    }
}
