import AISessionCore
import XCTest
@testable import AISessionRemote

final class ChatComposerTests: XCTestCase {
    private let prompt = TerminalPrompt.parse(screen: TerminalPromptFixtures.codexCommand.components(separatedBy: "\n"))!

    func testCanSendRules() {
        XCTAssertTrue(ChatComposer.canSend(mode: .normal, draft: "hi", connected: true, promptShowing: false))
        XCTAssertFalse(ChatComposer.canSend(mode: .normal, draft: "hi", connected: true, promptShowing: true))
        XCTAssertTrue(ChatComposer.canSend(mode: .answering(prompt: prompt, option: 2), draft: "use pnpm", connected: true, promptShowing: true))
        XCTAssertFalse(ChatComposer.canSend(mode: .normal, draft: " \n ", connected: true, promptShowing: false))
        XCTAssertFalse(ChatComposer.canSend(mode: .answering(prompt: prompt, option: 2), draft: "", connected: true, promptShowing: true))
        XCTAssertFalse(ChatComposer.canSend(mode: .normal, draft: "hi", connected: false, promptShowing: false))
    }

    func testQuickRepliesAreTheSpecList() {
        XCTAssertEqual(ChatComposer.quickReplies, ["continue", "yes", "run the tests", "/compact"])
    }
}
