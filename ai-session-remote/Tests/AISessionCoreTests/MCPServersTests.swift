import XCTest
@testable import AISessionCore

final class MCPServersTests: XCTestCase {
    private let decoder = TodoHubClient.makeDecoder()
    private let computerJSON = #"{"id":"m1","name":"Spread","hostname":"h","port":22,"username":"me","created_at":"","updated_at":""}"#

    private func conversationJSON(_ extra: String) -> Data {
        Data("""
        {"todo_id":"t","computer":\(computerJSON),"cwd":"~/x","tool":"claude","tmux_name":"n","session_id":"s","status":"idle","created_at":""\(extra)}
        """.utf8)
    }

    private func conversation(_ servers: [String]?, tool: String = "claude") -> Conversation {
        Conversation(todoId: "t", computer: Computer(id: "m", name: "M", hostname: "h", username: "u"),
                     cwd: "~/code", tool: tool, tmuxName: "n", sessionId: "abc-123", status: .idle, mcpServers: servers)
    }

    // MARK: Decoding

    func testConversationDistinguishesMissingNullAndEmpty() throws {
        XCTAssertNil(try decoder.decode(Conversation.self, from: conversationJSON("")).mcpServers)
        XCTAssertNil(try decoder.decode(Conversation.self, from: conversationJSON(#","mcp_servers":null"#)).mcpServers)
        XCTAssertEqual(try decoder.decode(Conversation.self, from: conversationJSON(#","mcp_servers":[]"#)).mcpServers, [])
        XCTAssertEqual(try decoder.decode(Conversation.self, from: conversationJSON(#","mcp_servers":["grafana","slack"]"#)).mcpServers,
                       ["grafana", "slack"])
    }

    func testComputerAndProjectDefaultsDecodeAndOlderHubsMissThem() throws {
        let old = try decoder.decode(Computer.self, from: Data(computerJSON.utf8))
        XCTAssertNil(old.mcpDefault)
        let withDefault = try decoder.decode(
            Computer.self, from: Data(computerJSON.replacingOccurrences(of: "}", with: #","mcp_default":[]}"#).utf8))
        XCTAssertEqual(withDefault.mcpDefault, [])

        let project = """
        {"id":"p","name":"n","section":"Si","computer":\(computerJSON),"folder":"~/f","mcp_default":["a"]}
        """
        XCTAssertEqual(try decoder.decode(Project.self, from: Data(project.utf8)).mcpDefault, ["a"])
        let bare = """
        {"id":"p","name":"n","section":"Si","computer":\(computerJSON),"folder":"~/f"}
        """
        XCTAssertNil(try decoder.decode(Project.self, from: Data(bare.utf8)).mcpDefault)
    }

    func testServerListDecodesErrorEntriesWithNullKind() throws {
        let json = """
        [{"name":"grafana","kind":"http","summary":"https://g.example/mcp","error":null},
         {"name":"broken","kind":null,"summary":"","error":"invalid JSON"}]
        """
        let servers = try MCPServer.decodeList(Data(json.utf8))
        XCTAssertEqual(servers.map(\.name), ["grafana", "broken"])
        XCTAssertEqual(servers[0].kind, "http")
        XCTAssertNil(servers[0].error)
        XCTAssertNil(servers[1].kind)
        XCTAssertEqual(servers[1].error, "invalid JSON")
        XCTAssertEqual(servers[0].id, "grafana")
    }

    // MARK: Encoding

    private func json<T: Encodable>(_ value: T) throws -> String {
        let encoder = TodoHubClient.makeEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    func testUpdateRequestsEncodeSetClearAndUnchanged() throws {
        XCTAssertEqual(try json(UpdateProjectRequest(mcpDefault: .clear)), #"{"mcp_default":null}"#)
        XCTAssertEqual(try json(UpdateProjectRequest(mcpDefault: .set(["a", "b"]))), #"{"mcp_default":["a","b"]}"#)
        XCTAssertEqual(try json(UpdateProjectRequest(mcpDefault: .set([]))), #"{"mcp_default":[]}"#)
        XCTAssertEqual(try json(UpdateProjectRequest(name: "x")), #"{"name":"x"}"#)
        XCTAssertEqual(try json(UpdateComputerRequest(mcpDefault: .clear)), #"{"mcp_default":null}"#)
        XCTAssertEqual(try json(UpdateComputerRequest()), "{}")
    }

    func testOpenAndSetServersBodies() throws {
        XCTAssertEqual(try json(OpenConversationRequest(tool: "claude")), #"{"tool":"claude"}"#)
        XCTAssertEqual(try json(OpenConversationRequest(tool: "claude", mcpServers: [])), #"{"mcp_servers":[],"tool":"claude"}"#)
        XCTAssertEqual(try json(SetConversationServersRequest(mcpServers: nil)), #"{"mcp_servers":null}"#)
        XCTAssertEqual(try json(SetConversationServersRequest(mcpServers: ["a"])), #"{"mcp_servers":["a"]}"#)
    }

    // MARK: Selection

    func testInitialSelectionPrefersTheProject() {
        let computer = Computer(id: "m", name: "M", hostname: "h", username: "u", mcpDefault: ["c"])
        let project = Project(id: "p", name: "P", computer: computer, folder: "~/p", mcpDefault: ["p"])
        let bare = Project(id: "q", name: "Q", computer: computer, folder: "~/q")
        let none = Project(id: "r", name: "R", computer: computer, folder: "~/r", mcpDefault: [])
        XCTAssertEqual(MCPSelection.initial(project: project, computer: computer), ["p"])
        XCTAssertEqual(MCPSelection.initial(project: bare, computer: computer), ["c"])
        XCTAssertEqual(MCPSelection.initial(project: nil, computer: computer), ["c"])
        XCTAssertEqual(MCPSelection.initial(project: none, computer: computer), [])
        XCTAssertNil(MCPSelection.initial(project: nil, computer: Computer(id: "m", name: "M", hostname: "h", username: "u")))
    }

    // MARK: Commands

    func testOpenTodoConversationMcpFlag() {
        let base = TmuxCommandBuilder.openTodoConversation(tmuxName: "n", cwd: "~/x", sessionId: "s")
        XCTAssertEqual(TmuxCommandBuilder.openTodoConversation(tmuxName: "n", cwd: "~/x", sessionId: "s", mcpServers: nil), base)
        XCTAssertTrue(base.hasSuffix(#"exec "$HOME/.ai-remote/bin/ai-todo-open" 'n' '~/x' 's'"#))

        let none = TmuxCommandBuilder.openTodoConversation(tmuxName: "n", cwd: "~/x", sessionId: "s", mcpServers: [])
        XCTAssertTrue(none.hasSuffix(#"exec "$HOME/.ai-remote/bin/ai-todo-open" --mcp '' 'n' '~/x' 's'"#), none)

        let two = TmuxCommandBuilder.openTodoConversation(tmuxName: "n", cwd: "~/x", sessionId: "s", tool: "codex", mcpServers: ["grafana", "slack"])
        XCTAssertTrue(two.hasSuffix(#"exec "$HOME/.ai-remote/bin/ai-todo-open" --mcp 'grafana,slack' 'n' '~/x' 's' 'codex'"#), two)

        let cursor = TmuxCommandBuilder.openTodoConversation(tmuxName: "n", cwd: "~/x", sessionId: "s", tool: "cursor", mcpServers: ["a"])
        XCTAssertFalse(cursor.contains("--mcp"))
    }

    func testListMCPServersCommand() {
        XCTAssertTrue(TmuxCommandBuilder.listMCPServers().hasSuffix(#"exec "$HOME/.ai-remote/bin/ai-todo-mcp" list --json"#))
    }

    func testForkDetachedWithServersEvaluatesLaunchArgsAfterTheCommand() {
        let args = ["claude", "--resume", "src", "--fork-session"]
        let plain = TmuxCommandBuilder.forkDetached(tmuxName: "n", cwd: "~/x", arguments: args)
        XCTAssertEqual(TmuxCommandBuilder.forkDetached(tmuxName: "n", cwd: "~/x", arguments: args, mcpServers: nil), plain)
        XCTAssertTrue(plain.contains("'claude' '--resume' 'src' '--fork-session' || exit $?"))
        XCTAssertFalse(plain.contains("ai-todo-mcp"))

        let managed = TmuxCommandBuilder.forkDetached(tmuxName: "n", cwd: "~/x", arguments: args, mcpServers: ["a", "b"])
        XCTAssertTrue(managed.contains(#"mcp_args=$("$HOME/.ai-remote/bin/ai-todo-mcp" launch-args claude 'a,b') || exit $?"#), managed)
        XCTAssertTrue(managed.contains("set -- 'claude'"))
        XCTAssertTrue(managed.contains(#"eval "set -- \"\$@\" $mcp_args""#))
        XCTAssertTrue(managed.contains(#"set -- "$@" '--resume' 'src' '--fork-session'"#))
        XCTAssertTrue(managed.contains(#"LC_ALL="${LC_ALL:-en_US.UTF-8}" "$@" || exit $?"#))
    }

    func testResumeCommandWithAndWithoutServers() {
        XCTAssertEqual(ResumeCommand.string(for: conversation(nil)), "cd ~/'code' && claude --resume abc-123")
        XCTAssertEqual(ResumeCommand.string(for: conversation(["grafana", "slack"])),
                       #"cd ~/'code' && eval "claude $(~/.ai-remote/bin/ai-todo-mcp launch-args claude 'grafana,slack') --resume abc-123""#)
        XCTAssertEqual(ResumeCommand.string(for: conversation([], tool: "codex")),
                       #"cd ~/'code' && eval "codex $(~/.ai-remote/bin/ai-todo-mcp launch-args codex '') resume abc-123""#)
        XCTAssertEqual(ResumeCommand.string(for: conversation(["a"], tool: "cursor")), "cd ~/'code' && agent --resume abc-123")
    }
}
