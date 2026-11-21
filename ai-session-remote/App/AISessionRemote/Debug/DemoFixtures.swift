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

    private enum DemoProject: String, CaseIterable {
        case rates, notes, scraper, website

        var folder: String {
            switch self {
            case .rates: "~/code/rms-backend"
            case .notes: "~/notes"
            case .scraper: "~/scraper"
            case .website: "~/code/website"
            }
        }

        var computer: Computer {
            switch self {
            case .rates, .website: DemoFixtures.macStudio
            case .notes, .scraper: DemoFixtures.linuxBox
            }
        }
    }

    static let demoProjects = DemoProject.allCases.map {
        Project(id: $0.rawValue, name: $0.rawValue, computer: $0.computer, folder: $0.folder)
    }

    /// Sp's projects, for screenshots of the New Todo sheet (`-uiDemoAdd`) only: other `-uiDemo`
    /// screens keep showing no projects. (`-demoProjects` has its own, in `TodoHubDemo`.)
    static var addSheetProjects: [Project] {
        guard ProcessInfo.processInfo.arguments.contains("-uiDemoAdd") else { return [] }
        return [
            Project(id: "demo-rms", name: "rms-backend", computer: macStudio, folder: "~/code/rms-backend"),
            Project(id: "demo-rates", name: "rate-importer", computer: macStudio, folder: "~/code/rate-importer"),
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

    /// What a demo worker did, for its sheet.
    static var workerTranscript: [ConversationMessage] {
        let start = Date().addingTimeInterval(-7 * 60)
        func step(_ id: String, _ kind: ActivityKind, _ target: String) -> ConversationMessage {
            ConversationMessage(id: id, role: .activity, text: "", time: start, kind: kind, target: target)
        }
        return [
            ConversationMessage(id: "0.0", role: .user, text: "Review the change to src/auth/callback.ts for regressions.", time: start),
            step("1.0", .run, "git diff HEAD~1 -- src/auth"),
            step("2.0", .read, "src/auth/callback.ts"),
            step("3.0", .search, "next="),
            ConversationMessage(id: "4.0", role: .assistant, text: "The change keeps `next`. Checking how it's validated.", time: start),
            step("5.0", .read, "src/auth/redirect.ts"),
        ]
    }

    /// Three workers started at the end of `chatTranscript`: one handed back, two still going.
    /// The hub's status for t1 (`demoHubWorkers`) has a2 waiting on an approval.
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
                state: .working, evidence: "no finish recorded; last write 4 s ago", startedAt: started,
                lastSeenAt: Date().addingTimeInterval(-4), toolCount: 31,
                task: "List every route that redirects after login and whether it keeps `next`."
            ),
            DelegatedWorker(
                id: "a3", title: "Run the auth test suite", kind: "general-purpose", background: true,
                state: .stale, evidence: "no finish recorded and no recent writes", startedAt: started.addingTimeInterval(30),
                lastSeenAt: Date().addingTimeInterval(-11 * 60), toolCount: 3,
                task: "Run the auth tests and report failures."
            ),
        ]
    }

    /// What the computer's status hooks report for t1's workers.
    static let demoHubWorkers: [WorkerStatus] = [
        WorkerStatus(id: "a1", state: "done"),
        WorkerStatus(id: "a2", state: "working", needsYou: true, message: "Claude needs your permission to use Bash"),
        WorkerStatus(id: "a3", state: "working"),
    ]

    private static let now = "2026-10-17T09:00:00Z"

    private static func todo(_ id: String, _ project: DemoProject, _ title: String,
                             status: ConversationStatus? = nil, completed: Bool = false) -> Todo {
        Todo(id: id, title: title, completed: completed,
             createdAt: now, updatedAt: now, conversationStatus: status, projectId: project.rawValue)
    }

    private static func conversation(_ id: String, _ project: DemoProject, _ computer: Computer,
                                     tool: String, _ status: ConversationStatus, message: String? = nil) -> Conversation {
        Conversation(id: "c-\(id)", todoId: id, computer: computer, cwd: project.folder, tool: tool,
                     tmuxName: "todo-\(id)", sessionId: "demo-\(id)", status: status, statusMessage: message,
                     createdAt: now, workers: id == "t1" ? demoHubWorkers : nil)
    }

    static let todos: [Todo] = [
        todo("t1", .rates, "Fix the rate import", status: .waiting),
        todo("t2", .rates, "Import Booking.com reviews", status: .busy),
        todo("t3", .notes, "Draft the HTIF follow-up", status: .waiting),
        todo("t4", .scraper, "Clean up scraper retries", status: .busy),
        todo("t5", .rates, "Santé party-size rates", status: .idle),
        todo("t6", .rates, "Renew the SSL certificate", completed: true),
        todo("t7", .notes, "Call the Bansko hotel"),
        todo("t8", .website, "Rate shopper comparison page"),
        todo("t9", .website, "Book the HTIF booth crew"),
    ]

    static let conversations: [Conversation] = [
        conversation("t1", .rates, macStudio, tool: "claude", .waiting,
                     message: "Claude needs your permission to use Bash"),
        conversation("t2", .rates, macStudio, tool: "claude", .busy),
        conversation("t3", .notes, linuxBox, tool: "claude", .waiting,
                     message: "Claude needs your permission to use Edit"),
        conversation("t4", .scraper, linuxBox, tool: "codex", .busy),
        conversation("t5", .rates, macStudio, tool: "claude", .idle),
    ]

    /// Never dialed: `DemoTransport` replaces SSH.
    static let config = HostConnectionConfig(
        host: "demo.invalid", port: 22, username: "demo", privateKeyPEM: Data(), hostID: "demo"
    )
}
#endif
