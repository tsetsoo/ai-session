#if DEBUG
import AISessionCore
import Foundation

/// Mockup data for `-uiDemo` launches (screenshots, design review). Debug builds only.
enum DemoFixtures {
    /// `-uiDemo` on the command line.
    static var isEnabled: Bool { ProcessInfo.processInfo.arguments.contains("-uiDemo") }

    /// Value following `-uiDemoScreen`, if any.
    static var screen: String? { value(after: "-uiDemoScreen") }

    /// The launch argument following `flag`, if any.
    static func value(after flag: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    static let macStudio = Computer(id: "mac-studio", name: "mac-studio", hostname: "mac-studio", username: "tsvetelin")
    static let linuxBox = Computer(id: "linux-box", name: "linux-box", hostname: "linux-box", username: "tsvetelin")
    static let computers: [Computer] = [macStudio, linuxBox]

    /// `SectionComputer` has no public initializer, so build it through its Codable form.
    private struct SectionComputerSpec: Encodable {
        var section: TodoSection
        var computer: Computer
        var cwd: String
        var tool: String
    }

    static let sectionComputers: [SectionComputer] = {
        let specs = [
            SectionComputerSpec(section: .sp, computer: macStudio, cwd: "~/code/rms-backend", tool: "claude"),
            SectionComputerSpec(section: .i, computer: linuxBox, cwd: "~/notes", tool: "claude"),
            SectionComputerSpec(section: .si, computer: linuxBox, cwd: "~/scraper", tool: "claude"),
            SectionComputerSpec(section: .p, computer: macStudio, cwd: "~/code/website", tool: "claude"),
        ]
        do {
            return try JSONDecoder().decode([SectionComputer].self, from: JSONEncoder().encode(specs))
        } catch {
            fatalError("DemoFixtures: \(error)")
        }
    }()

    /// Sp's projects, for screenshots of the New Todo sheet (`-uiDemoAdd`) only: other `-uiDemo`
    /// screens keep showing no projects. (`-demoProjects` has its own, in `TodoHubDemo`.)
    static var addSheetProjects: [Project] {
        guard ProcessInfo.processInfo.arguments.contains("-uiDemoAdd") else { return [] }
        return [
            Project(id: "demo-rms", name: "rms-backend", computer: macStudio, folder: "~/code/rms-backend", section: .sp),
            Project(id: "demo-rates", name: "rate-importer", computer: macStudio, folder: "~/code/rate-importer", section: .sp),
        ]
    }

    /// A chat like mockup A: a question, tool steps, a markdown reply with code, a reply long
    /// enough to fold, and a 40-minute gap before the last turn.
    static var chatTranscript: [ConversationMessage] {
        let start = Date().addingTimeInterval(-50 * 60)
        func at(_ minutes: Double) -> Date { start.addingTimeInterval(minutes * 60) }
        func step(_ id: String, _ kind: ActivityKind, _ target: String, _ minutes: Double) -> ConversationMessage {
            ConversationMessage(id: id, role: .activity, text: "", time: at(minutes), kind: kind, target: target)
        }
        let long = (1...45).map { "\($0). Checked `route\($0)` — redirect keeps `next`." }.joined(separator: "\n")
        return [
            ConversationMessage(id: "0.0", role: .user, text: "why does login bounce back to /start after the OAuth callback?", time: at(0)),
            step("1.0", .read, "src/auth/callback.ts", 0.2),
            step("2.0", .search, "redirect_uri", 0.3),
            step("3.0", .run, "git log -5 -- src/auth", 0.4),
            ConversationMessage(id: "4.0", role: .assistant, text: """
            ## Cause
            The callback handler drops the `next` param, so it falls back to `/start`.

            - Fix is in `auth/callback.ts`
            - **One** test needs updating

            ```sh
            npm test -- auth/callback
            ```

            | File | Change |
            |---|---|
            | callback.ts | keep `next` |
            """, time: at(0.5)),
            ConversationMessage(id: "5.0", role: .user, text: "ok fix it and check every route", time: at(1)),
            step("6.0", .edit, "src/auth/callback.ts", 1.2),
            step("7.0", .edit, "src/auth/callback.test.ts", 1.3),
            ConversationMessage(id: "8.0", role: .assistant, text: "Done. Every route:\n\n" + long, time: at(2)),
            ConversationMessage(id: "9.0", role: .user, text: "great, now run the tests", time: at(42)),
            step("10.0", .run, "npm test -- auth/callback", 42.1),
            ConversationMessage(id: "11.0", role: .activity, text: "", time: at(42.5), kind: .other, target: "Agent", name: "Agent"),
            ConversationMessage(id: "11.1", role: .activity, text: "", time: at(42.5), kind: .other, target: "Agent", name: "Agent"),
        ]
    }

    /// Two workers started at the end of `chatTranscript`: one handed back, one still going.
    static var delegatedWorkers: [DelegatedWorker] {
        let started = Date().addingTimeInterval(-7.5 * 60)
        return [
            DelegatedWorker(
                id: "a1", callId: "11.0", title: "Review the callback fix", kind: "general-purpose", model: "claude-opus-5-5",
                background: true, state: .done, evidence: "handed back its report", startedAt: started,
                durationMs: 240_000, tokens: 18_400, toolCount: 12, task: "Review the change to src/auth/callback.ts for regressions.",
                result: "No regressions. One nit: `next` isn't validated against open redirects — check it starts with `/`."
            ),
            DelegatedWorker(
                id: "a2", callId: "11.1", title: "Check every route redirect", kind: "Explore", background: true,
                state: .working, evidence: "no finish recorded; last write 4 s ago", startedAt: started, toolCount: 31,
                task: "List every route that redirects after login and whether it keeps `next`."
            ),
        ]
    }

    private static let now = "2026-10-17T09:00:00Z"

    private static func cwd(for section: TodoSection) -> String {
        switch section {
        case .sp: "~/code/rms-backend"
        case .i: "~/notes"
        case .si: "~/scraper"
        case .p: "~/code/website"
        }
    }

    private static func todo(_ id: String, _ section: TodoSection, _ title: String,
                             status: ConversationStatus? = nil, completed: Bool = false) -> Todo {
        Todo(id: id, section: section, title: title, completed: completed,
             createdAt: now, updatedAt: now, conversationStatus: status)
    }

    private static func conversation(_ id: String, _ section: TodoSection, _ computer: Computer,
                                     tool: String, _ status: ConversationStatus, message: String? = nil) -> Conversation {
        Conversation(id: "c-\(id)", todoId: id, computer: computer, cwd: cwd(for: section), tool: tool,
                     tmuxName: "todo-\(id)", sessionId: "demo-\(id)", status: status, statusMessage: message,
                     createdAt: now)
    }

    static let todos: [Todo] = [
        todo("t1", .sp, "Fix the rate import", status: .waiting),
        todo("t2", .sp, "Import Booking.com reviews", status: .busy),
        todo("t3", .i, "Draft the HTIF follow-up", status: .waiting),
        todo("t4", .si, "Clean up scraper retries", status: .busy),
        todo("t5", .sp, "Santé party-size rates", status: .idle),
        todo("t6", .sp, "Renew the SSL certificate", completed: true),
        todo("t7", .i, "Call the Bansko hotel"),
        todo("t8", .p, "Rate shopper comparison page"),
        todo("t9", .p, "Book the HTIF booth crew"),
    ]

    static let conversations: [Conversation] = [
        conversation("t1", .sp, macStudio, tool: "claude", .waiting,
                     message: "Claude needs your permission to use Bash"),
        conversation("t2", .sp, macStudio, tool: "claude", .busy),
        conversation("t3", .i, linuxBox, tool: "claude", .waiting,
                     message: "Claude needs your permission to use Edit"),
        conversation("t4", .si, linuxBox, tool: "codex", .busy),
        conversation("t5", .sp, macStudio, tool: "claude", .idle),
    ]

    /// Never dialed: `DemoTransport` replaces SSH.
    static let config = HostConnectionConfig(
        host: "demo.invalid", port: 22, username: "demo", privateKeyPEM: Data(), hostID: "demo"
    )
}
#endif
