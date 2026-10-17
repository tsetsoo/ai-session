import AISessionCore
import XCTest
@testable import AISessionRemote

@MainActor
final class ConversationRowActionsTests: XCTestCase {
    private let mac = DemoFixtures.macStudio

    func testMissingAccessPointsToSettingsWithoutSSHWords() {
        let setUp = "This device can't reach mac-studio yet. Set up access in Settings."
        XCTAssertEqual(ConversationRowActions.message(for: HostLookup.Failure.noHost(mac), computer: mac), setUp)
        XCTAssertEqual(ConversationRowActions.message(for: HostLookup.Failure.keyUnavailable("mac-studio"), computer: mac), setUp)
        XCTAssertEqual(ConversationRowActions.message(for: SSHRemoteError.authenticationFailed, computer: mac), setUp)
    }

    func testUnreachableUsesTheComputerName() {
        XCTAssertEqual(ConversationRowActions.message(for: SSHRemoteError.unreachable, computer: mac),
                       "Can't reach mac-studio. Check it's awake and on Tailscale.")
    }

    func testRemoteOutputIsNeverShownRaw() {
        let failed = SSHRemoteError.commandFailed(exitCode: 3, stderr: "tmux: session not found")
        XCTAssertEqual(ConversationRowActions.message(for: failed, computer: mac), "mac-studio couldn't finish that. Try again.")
        XCTAssertEqual(ConversationRowActions.message(for: RemoteConversations.UnreadableList(detail: "bad json"), computer: mac),
                       "Couldn't read the conversations on mac-studio.")
    }

    func testMissingProgramsNameTheToolOnly() {
        XCTAssertEqual(ConversationRowActions.message(for: SSHRemoteError.binaryMissing("claude"), computer: mac),
                       "Claude isn't installed on mac-studio.")
        XCTAssertEqual(ConversationRowActions.message(for: SSHRemoteError.binaryMissing("codex"), computer: mac),
                       "Codex isn't installed on mac-studio.")
        let generic = "Something mac-studio needs isn't installed there."
        XCTAssertEqual(ConversationRowActions.message(for: SSHRemoteError.tmuxMissing, computer: mac), generic)
        XCTAssertEqual(ConversationRowActions.message(for: SSHRemoteError.binaryMissing("python3"), computer: mac), generic)
        XCTAssertEqual(ConversationRowActions.message(for: RemoteConversations.ScriptMissing(computer: "mac-studio"), computer: mac),
                       "mac-studio needs the AI Session helpers.")
    }

    func testHubErrorsKeepTheStoreMessage() {
        let error = TodoHubError.invalidBaseURL
        XCTAssertEqual(ConversationRowActions.message(for: error, computer: mac), TodoHubStore.message(for: error))
    }

    func testNoMappedMessageUsesSSHWords() {
        let errors: [Error] = [
            HostLookup.Failure.noHost(mac), HostLookup.Failure.keyUnavailable("mac-studio"),
            SSHRemoteError.unreachable, SSHRemoteError.authenticationFailed, SSHRemoteError.tmuxMissing,
            SSHRemoteError.binaryMissing("agent"), SSHRemoteError.commandFailed(exitCode: 1, stderr: "ssh: tmux"),
            RemoteConversations.ScriptMissing(computer: "mac-studio"),
        ]
        for error in errors {
            let message = ConversationRowActions.message(for: error, computer: mac).lowercased()
            for word in ["ssh", "tmux", "host", "key", "port", "@"] {
                XCTAssertFalse(message.contains(word), "\"\(message)\" contains \(word)")
            }
        }
    }

    func testOtherHostsAreThoseMatchingNoHubComputer() {
        let studio = HostEntity(displayName: "studio", hostname: "MAC-STUDIO", username: "tsvetelin")
        let pi = HostEntity(displayName: "pi-garage", hostname: "pi", username: "pi")
        let otherPort = HostEntity(displayName: "box", hostname: "linux-box", port: 2222, username: "tsvetelin")
        let others = ComputerListView.otherHosts([studio, pi, otherPort], computers: DemoFixtures.computers)
        XCTAssertEqual(others.map(\.displayName), ["pi-garage", "box"])
    }
}
