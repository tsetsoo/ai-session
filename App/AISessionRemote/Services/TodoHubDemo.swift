#if DEBUG
import AISessionCore
import Foundation

/// Canned hub data for screenshots of the Projects tab (`-demoProjects`). Nothing here talks
/// to a hub; the store serves these values and ignores mutations.
struct TodoHubDemo {
    var computers: [Computer]
    var projects: [Project]
    var suggestions: [ProjectSuggestion]
    var todos: [Todo]
    var conversations: [Conversation]
    var sessions: [HubSession]
    var memories: [Memory]

    func weekly(weekStart: String?) -> WeeklyStats {
        let start = weekStart ?? WeekMath.monday(of: .now)
        let end = WeekMath.addingDays(6, to: start) ?? start
        let isThisWeek = start == WeekMath.monday(of: .now)
        return WeeklyStats(
            weekStart: start,
            weekEnd: end,
            totals: StatsCounters(
                sessions: isThisWeek ? 9 : 6, prompts: isThisWeek ? 84 : 51, assistantTurns: isThisWeek ? 82 : 50,
                inputTokens: 41_200, outputTokens: isThisWeek ? 612_400 : 380_100, cacheReadTokens: 38_400_000,
                cacheCreationTokens: 1_920_000, activeSeconds: isThisWeek ? 31_800 : 19_200, filesTouched: 47
            )
        )
    }

    static let sample: TodoHubDemo = {
        func ago(_ minutes: Double) -> String {
            ISO8601DateFormatter().string(from: Date().addingTimeInterval(-minutes * 60))
        }
        let mac = Computer(id: "demo-mac", name: "tsvetelins-macbook-pro", hostname: "mac.tailnet", username: "me")
        let spread = Computer(id: "demo-spread", name: "spreads-macbook-pro", hostname: "spread.tailnet", username: "me")
        let todoApp = Project(id: "demo-p1", name: "todo-app", computer: mac, folder: "~/programming/todo-app",
                              repoUrl: "https://github.com/tsetsoo/todo-app", openTodos: 2, sessions: 14,
                              memories: 6, lastActivity: ago(4))
        let remote = Project(id: "demo-p2", name: "ai-session-remote", computer: mac,
                             folder: "~/programming/ai-session-remote", openTodos: 1, sessions: 22,
                             memories: 11, lastActivity: ago(60 * 5))
        let repository = Project(id: "demo-p3", name: "Repository", computer: spread, folder: "~/Spread/Repository",
                                 digestEnabled: false, openTodos: 0, sessions: 31, memories: 18,
                                 lastActivity: ago(60 * 26))
        let todos = [
            Todo(id: "demo-t1", section: .si, title: "Weekly rollup per project", createdAt: ago(300),
                 conversationStatus: .waiting, projectId: todoApp.id),
            Todo(id: "demo-t2", section: .si, title: "Memories migration backup check", createdAt: ago(200),
                 projectId: todoApp.id),
            Todo(id: "demo-t3", section: .p, title: "Projects tab on the Mac", createdAt: ago(100),
                 conversationStatus: .busy, projectId: remote.id),
            Todo(id: "demo-t4", section: .sp, title: "Review data-management PR", createdAt: ago(50)),
        ]
        let sessions = [
            HubSession(tool: "claude", sessionId: "demo-s1", computerId: mac.id, cwd: "~/programming/todo-app",
                       title: "Add the weekly stats endpoint", projectId: todoApp.id,
                       stats: SessionStats(prompts: 12, assistantTurns: 12, outputTokens: 51_234, activeSeconds: 5_400,
                                           lastActivity: ago(4)),
                       todoId: "demo-t1", status: .waiting),
            HubSession(tool: "codex", sessionId: "demo-s2", computerId: mac.id,
                       cwd: "~/programming/todo-app/.claude/worktrees/stats", title: "Fix the migration test fixture",
                       projectId: todoApp.id,
                       stats: SessionStats(prompts: 3, assistantTurns: 3, activeSeconds: 900, lastActivity: ago(90))),
            HubSession(tool: "claude", sessionId: "demo-s3", computerId: mac.id, cwd: "~/programming/todo-app",
                       title: "Why does the Pi updater skip builds?", projectId: todoApp.id, projectOverride: true,
                       stats: SessionStats(prompts: 5, assistantTurns: 5, activeSeconds: 1_800, lastActivity: ago(60 * 30))),
        ]
        let memories = [
            Memory(id: "demo-m1", projectId: todoApp.id, computerId: mac.id, tool: "claude", sessionId: "demo-s1",
                   kind: .openThread, text: "Decide whether Codex digests should go into tracked AGENTS.md files.",
                   pinned: true, createdAt: ago(60 * 20)),
            Memory(id: "demo-m2", projectId: todoApp.id, computerId: mac.id, tool: "claude", sessionId: "demo-s1",
                   kind: .decision, text: "Weekly rollups sum per-day rows, so a session spanning two weeks counts in both.",
                   files: ["crates/todo-server/src/sessions.rs"], confidence: 0.9, createdAt: ago(30)),
            Memory(id: "demo-m3", projectId: todoApp.id, computerId: mac.id, tool: "codex", sessionId: "demo-s2",
                   kind: .gotcha, text: "The v2 fixture needs PRAGMA foreign_keys off while seeding conversations.",
                   files: ["crates/todo-server/src/db.rs"], confidence: 0.8, createdAt: ago(95)),
            Memory(id: "demo-m4", projectId: todoApp.id, kind: .gotcha,
                   text: "The Pi updater pulls :latest, so wait for the main build before deploying.",
                   source: "manual", createdAt: ago(60 * 48)),
            Memory(id: "demo-m5", projectId: todoApp.id, computerId: mac.id, tool: "claude", sessionId: "demo-s1",
                   kind: .done, text: "Schema v3 migration with a pre-v3 backup is merged.", createdAt: ago(60 * 3)),
            Memory(id: "demo-m6", projectId: todoApp.id, computerId: mac.id, tool: "claude", sessionId: "demo-s3",
                   kind: .filesChanged, text: "Added project routes and handlers.",
                   files: ["crates/todo-server/src/projects.rs", "crates/todo-server/src/main.rs"], createdAt: ago(60 * 6)),
        ]
        return TodoHubDemo(
            computers: [mac, spread],
            projects: [remote, repository, todoApp],
            suggestions: [
                ProjectSuggestion(computer: mac, folder: "~/programming/sigma-revenue", name: "sigma-revenue",
                                  sessions: 19, lastActivity: ago(60 * 3),
                                  exampleCwds: ["~/programming/sigma-revenue/sigma-revenue-backend"]),
                ProjectSuggestion(computer: mac, folder: "~/programming/marketing", name: "marketing",
                                  sessions: 4, lastActivity: ago(60 * 24 * 2)),
            ],
            todos: todos,
            conversations: [],
            sessions: sessions,
            memories: memories
        )
    }()
}
#endif
