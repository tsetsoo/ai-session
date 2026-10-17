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

    private static let now = "2026-10-17T09:00:00Z"

    private static func cwd(for section: TodoSection) -> String {
        sectionComputers.first { $0.section == section }?.cwd ?? "~"
    }

    private static func todo(_ id: String, _ section: TodoSection, _ title: String,
                             status: ConversationStatus? = nil, completed: Bool = false) -> Todo {
        Todo(id: id, section: section, title: title, completed: completed,
             createdAt: now, updatedAt: now, conversationStatus: status)
    }

    private static func conversation(_ id: String, _ section: TodoSection, _ computer: Computer,
                                     tool: String, _ status: ConversationStatus) -> Conversation {
        Conversation(todoId: id, computer: computer, cwd: cwd(for: section), tool: tool,
                     tmuxName: "todo-\(id)", sessionId: "demo-\(id)", status: status, createdAt: now)
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
        conversation("t1", .sp, macStudio, tool: "claude", .waiting),
        conversation("t2", .sp, macStudio, tool: "claude", .busy),
        conversation("t3", .i, linuxBox, tool: "claude", .waiting),
        conversation("t4", .si, linuxBox, tool: "codex", .busy),
        conversation("t5", .sp, macStudio, tool: "claude", .idle),
    ]

    /// Never dialed: `DemoTransport` replaces SSH.
    static let config = HostConnectionConfig(
        host: "demo.invalid", port: 22, username: "demo", privateKeyPEM: Data(), hostID: "demo"
    )
}
#endif
