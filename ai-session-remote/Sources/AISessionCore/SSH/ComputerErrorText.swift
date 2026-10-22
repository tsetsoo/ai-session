import Foundation

/// Plain sentences, each with a next step, for what can go wrong reaching a computer. The one
/// table for these errors: `SSHRemoteError.userMessage` reads from it too. SSH and tmux detail
/// stays out (see "Vocabulary on screen" in the redesign spec), except where the fix is to
/// install something on the computer.
public enum ComputerErrorText {
    public static func message(for error: Error, computer: String) -> String {
        switch error {
        case let error as SSHRemoteError:
            switch error {
            case .unreachable:
                return "Couldn't reach \(computer). Check that it's on and connected to Tailscale, then try again."
            case .authenticationFailed:
                return "The key on this device wasn't accepted by \(computer). Check the user name and key in Access & keys."
            case .tmuxMissing:
                return "Sessions can't keep running on \(computer) yet. Install tmux there (brew install tmux), then try again."
            case let .binaryMissing(binary):
                return "\(binary) isn't installed on \(computer). Install it there, then try again."
            case let .commandFailed(exitCode, stderr):
                // The computer's own words name the cause, e.g. a session name already in use.
                let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                return detail.isEmpty
                    ? "Something went wrong on \(computer) (exit code \(exitCode)). Try again in a moment."
                    : "Something went wrong on \(computer): \(detail)"
            }
        case KeychainPrivateKeyStoreError.itemNotFound, KeychainPrivateKeyStoreError.invalidData,
             KeychainPrivateKeyStoreError.loadFailed(_):
            return missingKey(computer: computer)
        case let error as LocalizedError where error.errorDescription != nil:
            // Already worded for people, e.g. an invalid session name.
            return error.errorDescription ?? ""
        default:
            return "Something went wrong talking to \(computer): \(error.localizedDescription)"
        }
    }

    public static func missingKey(computer: String) -> String {
        "This device has no key for \(computer). Add it in Access & keys."
    }

    /// Whether fixing the computer's access is the way out: the key is missing or was refused.
    public static func isAccessProblem(_ error: Error) -> Bool {
        switch error {
        case SSHRemoteError.authenticationFailed,
             KeychainPrivateKeyStoreError.itemNotFound, KeychainPrivateKeyStoreError.invalidData,
             KeychainPrivateKeyStoreError.loadFailed(_):
            true
        default:
            false
        }
    }
}
