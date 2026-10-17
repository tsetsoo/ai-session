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

    func testOtherErrorsKeepTheStoreMessage() {
        let error = SSHRemoteError.commandFailed(exitCode: 3, stderr: "conversation is in use")
        XCTAssertEqual(ConversationRowActions.message(for: error, computer: mac), "conversation is in use")
    }

    func testOtherHostsAreThoseMatchingNoHubComputer() {
        let studio = HostEntity(displayName: "studio", hostname: "MAC-STUDIO", username: "tsvetelin")
        let pi = HostEntity(displayName: "pi-garage", hostname: "pi", username: "pi")
        let otherPort = HostEntity(displayName: "box", hostname: "linux-box", port: 2222, username: "tsvetelin")
        let others = ComputerListView.otherHosts([studio, pi, otherPort], computers: DemoFixtures.computers)
        XCTAssertEqual(others.map(\.displayName), ["pi-garage", "box"])
    }
}
