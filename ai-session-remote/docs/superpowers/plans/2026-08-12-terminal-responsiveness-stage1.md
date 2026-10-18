# Terminal Responsiveness Stage 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every remote action fast at high latency by reusing one authenticated SSH connection per host and cutting the number of remote commands per user action.

**Architecture:** An actor-based `SSHConnectionPool` in the app layer holds one authenticated SwiftNIO SSH connection per host, shared by both remote commands and the terminal PTY, with in-flight coalescing, lease-based idle eviction, and a mandatory retry-once when a cached connection turns out to be dead. In parallel, `SessionService`'s multi-command sequences collapse into single remote scripts that preserve today's exit codes and stderr exactly.

**Tech Stack:** Swift 5.9, iOS 17, SwiftUI, swift-nio-ssh, SwiftTerm, XCTest, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-08-11-terminal-responsiveness-stage1-design.md`

## Global Constraints

- `AISessionCore` must stay **NIO-free**. All SwiftNIO code lives in `App/AISessionRemote/`.
- Swift version `5.9`; iOS deployment target `17.0`.
- No behaviour or user-facing error-message changes. `SSHRemoteError.userMessage` strings are asserted verbatim by `SessionServiceTests.testRemoteErrorMessagesAreActionableAndConsistent` and must not change.
- Stage 1 ships **no** Mosh code, no `mosh-server` detection, no transport preference, no transport UI.
- Stage 1 makes **no** attempt to change keystroke echo latency.
- Core tests run with `swift test`. App tests run on the **iPhone 17** simulator (iPhone 16 is not installed on this machine).
- New files under `App/AISessionRemote/` are picked up by directory glob in `project.yml`, but `xcodegen generate` must be re-run before app tests will see them.
- Every task ends with a commit.

### Command reference

```bash
# Core tests (fast, no simulator)
swift test
swift test --filter RemoteScriptOutputTests

# App tests (regenerate project first if files were added)
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodegen generate
xcodebuild -scheme AISessionRemote \
  -destination 'platform=iOS Simulator,name=iPhone 17' test
```

## File Structure

**Create — `AISessionCore` (no NIO):**

| file | responsibility |
| --- | --- |
| `Sources/AISessionCore/Tmux/RemoteScriptOutput.swift` | split merged-script stdout at a marker line |

**Create — app layer (NIO/UIKit):**

| file | responsibility |
| --- | --- |
| `App/AISessionRemote/Services/SSH/PooledConnecting.swift` | protocol for one live authenticated connection; the seam pool tests fake |
| `App/AISessionRemote/Services/SSH/SSHConnectionPool.swift` | actor: host → one connection; coalescing, leases, eviction, retry-once |
| `App/AISessionRemote/Services/SSH/PooledSSHConnection.swift` | real `PooledConnecting` over SwiftNIO |
| `App/AISessionRemote/Terminal/TerminalTransport.swift` | protocol the terminal depends on; Stage 2's seam |
| `App/AISessionRemote/Terminal/TerminalOutputCoalescer.swift` | batch inbound bytes into one `feed()` per frame |

**Modify:**

| file | change |
| --- | --- |
| `Sources/AISessionCore/Models/SessionMetadata.swift` | add `printfTemplate` |
| `Sources/AISessionCore/Tmux/TmuxCommandBuilder.swift` | add merged script builders |
| `Sources/AISessionCore/Services/SessionService.swift` | use merged builders |
| `Tests/AISessionCoreTests/FakeSSHExecutor.swift` | record issued commands |
| `App/AISessionRemote/Services/NIOSSHClient.swift` | `exec` delegates to the pool |
| `App/AISessionRemote/Terminal/SSHTerminalSession.swift` | take a PTY from the pool; conform to `TerminalTransport` |
| `App/AISessionRemote/Terminal/TerminalScreen.swift` | coalescer, debounced resize, overlay delay |
| `App/AISessionRemote/Views/SessionsListView.swift` | warm the pool on appear |
| `App/AISessionRemote/AISessionRemoteApp.swift` | close pool on background/foreground |
| `docs/superpowers/plans/manual-acceptance.md` | latency acceptance procedure |

**Task order:** Tasks 1–5 (Core command merging) and Tasks 6–10 (app-layer pooling) are independent of each other and may be done in either order. Task 11 depends on both.

---

### Task 1: Record commands in FakeSSHExecutor

Round-trip counts are the whole point of this work and are easy to silently regress. The existing fake matches commands by substring but keeps no log, so exec-count assertions are impossible today.

**Files:**
- Modify: `Tests/AISessionCoreTests/FakeSSHExecutor.swift`
- Test: `Tests/AISessionCoreTests/FakeSSHExecutorTests.swift`

**Interfaces:**
- Consumes: `SSHExecuting`, `SSHExecResult`, `HostConnectionConfig` (existing).
- Produces: `FakeSSHExecutor` becomes a `final class`, keeping its existing initialiser signature, and gains `var recordedCommands: [String]`.

- [ ] **Step 1: Write the failing test**

Append to `Tests/AISessionCoreTests/FakeSSHExecutorTests.swift`:

```swift
func testRecordsEveryCommandInOrder() async throws {
    let executor = FakeSSHExecutor(responsesByPrefix: [
        "alpha": SSHExecResult(exitCode: 0, stdout: "a", stderr: ""),
        "beta": SSHExecResult(exitCode: 0, stdout: "b", stderr: "")
    ])
    let config = HostConnectionConfig(
        host: "example.com", port: 22, username: "tester", privateKeyPEM: Data()
    )

    _ = try await executor.exec(config, command: "alpha one")
    _ = try await executor.exec(config, command: "beta two")

    XCTAssertEqual(executor.recordedCommands, ["alpha one", "beta two"])
}
```

Ensure the file imports `Foundation` (for `Data`) alongside its existing imports.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter FakeSSHExecutorTests/testRecordsEveryCommandInOrder`
Expected: FAIL — `value of type 'FakeSSHExecutor' has no member 'recordedCommands'`

- [ ] **Step 3: Convert the fake to a recording class**

Replace the whole of `Tests/AISessionCoreTests/FakeSSHExecutor.swift`:

```swift
import AISessionCore
import Foundation

/// Test double mapping command substrings to canned exec results or errors, recording
/// every command it is asked to run so tests can assert on round-trip counts.
///
/// A `final class` rather than a `struct` because recording is mutation, and `exec` is
/// `nonmutating` by protocol. `@unchecked Sendable` is justified by the lock.
final class FakeSSHExecutor: SSHExecuting, @unchecked Sendable {
    private let responsesByPrefix: [String: SSHExecResult]
    private let errorsByPrefix: [String: SSHRemoteError]
    private let defaultResult: SSHExecResult
    private let lock = NSLock()
    private var _recordedCommands: [String] = []

    var recordedCommands: [String] {
        lock.withLock { _recordedCommands }
    }

    init(
        responsesByPrefix: [String: SSHExecResult] = [:],
        errorsByPrefix: [String: SSHRemoteError] = [:],
        defaultResult: SSHExecResult = SSHExecResult(exitCode: 127, stdout: "", stderr: "command not found")
    ) {
        self.responsesByPrefix = responsesByPrefix
        self.errorsByPrefix = errorsByPrefix
        self.defaultResult = defaultResult
    }

    func exec(_ config: HostConnectionConfig, command: String) async throws -> SSHExecResult {
        lock.withLock { _recordedCommands.append(command) }

        for (needle, error) in errorsByPrefix.sorted(by: { $0.key.count > $1.key.count }) {
            if command.contains(needle) {
                throw error
            }
        }

        for (needle, result) in responsesByPrefix.sorted(by: { $0.key.count > $1.key.count }) {
            if command.contains(needle) {
                return result
            }
        }

        return defaultResult
    }
}
```

- [ ] **Step 4: Run the full core suite**

Run: `swift test`
Expected: PASS, 46 tests. The struct→class change is source-compatible with existing call sites, which all use the same initialiser.

- [ ] **Step 5: Commit**

```bash
git add Tests/AISessionCoreTests/FakeSSHExecutor.swift Tests/AISessionCoreTests/FakeSSHExecutorTests.swift
git commit -m "test: record issued commands in FakeSSHExecutor"
```

---

### Task 2: RemoteScriptOutput.split

`listSessions` will merge two commands whose *stdout* must be told apart. Only stdout needs a delimiter — stderr and the exit code travel on their own SSH channels and are left untouched.

**Files:**
- Create: `Sources/AISessionCore/Tmux/RemoteScriptOutput.swift`
- Test: `Tests/AISessionCoreTests/RemoteScriptOutputTests.swift`

**Interfaces:**
- Produces: `RemoteScriptOutput.statusMarker: String` and
  `RemoteScriptOutput.split(_ stdout: String, at marker: String) -> (head: String, tail: String?)`.

- [ ] **Step 1: Write the failing test**

Create `Tests/AISessionCoreTests/RemoteScriptOutputTests.swift`:

```swift
import XCTest
@testable import AISessionCore

final class RemoteScriptOutputTests: XCTestCase {
    private let marker = RemoteScriptOutput.statusMarker

    func testSplitsAtMarkerLine() {
        let stdout = "ai/claude/demo\t123\t0\n\(marker)\n---x.json---\n{}\n"
        let (head, tail) = RemoteScriptOutput.split(stdout, at: marker)
        XCTAssertEqual(head, "ai/claude/demo\t123\t0")
        XCTAssertEqual(tail, "---x.json---\n{}")
    }

    func testMissingMarkerYieldsNilTail() {
        let (head, tail) = RemoteScriptOutput.split("only-sessions\n", at: marker)
        XCTAssertEqual(head, "only-sessions")
        XCTAssertNil(tail)
    }

    func testEmptyHeadAndEmptyTailAreDistinguishedFromMissing() {
        let (head, tail) = RemoteScriptOutput.split("\(marker)\n", at: marker)
        XCTAssertEqual(head, "")
        XCTAssertEqual(tail, "")
    }

    /// A tmux session whose name merely contains the marker text must not split the output.
    /// Only a line exactly equal to the marker counts.
    func testMarkerAsSubstringOfLongerLineDoesNotSplit() {
        let stdout = "prefix\(marker)suffix\t1\t0\n"
        let (head, tail) = RemoteScriptOutput.split(stdout, at: marker)
        XCTAssertEqual(head, "prefix\(marker)suffix\t1\t0")
        XCTAssertNil(tail)
    }

    func testSplitsAtFirstMarkerOnly() {
        let stdout = "a\n\(marker)\nb\n\(marker)\nc"
        let (head, tail) = RemoteScriptOutput.split(stdout, at: marker)
        XCTAssertEqual(head, "a")
        XCTAssertEqual(tail, "b\n\(marker)\nc")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter RemoteScriptOutputTests`
Expected: FAIL — cannot find `RemoteScriptOutput` in scope.

- [ ] **Step 3: Implement**

Create `Sources/AISessionCore/Tmux/RemoteScriptOutput.swift`:

```swift
/// Helpers for reading stdout produced by a single remote script that ran several commands.
///
/// Only stdout needs a delimiter: SSH carries stderr on a separate stream and `SSHExecResult`
/// keeps it distinct, so a merged script can let its dominant command's stderr and exit code
/// flow through untouched and existing error mapping keeps working unchanged.
public enum RemoteScriptOutput {
    /// Emitted on its own line between the session list and the agent-status dump.
    /// Deliberately implausible as a tmux session name.
    public static let statusMarker = "<<<AI-REMOTE-STATUS>>>"

    /// Splits `stdout` at the first line exactly equal to `marker`.
    ///
    /// Returns `tail == nil` when the marker never appears — meaning the second command never
    /// ran or its output was lost — so callers can treat that as "unavailable" rather than
    /// silently folding the second command's output into the first's.
    /// Both components have trailing newlines trimmed.
    public static func split(_ stdout: String, at marker: String) -> (head: String, tail: String?) {
        var head: [Substring] = []
        var tail: [Substring]?

        for line in stdout.split(separator: "\n", omittingEmptySubsequences: false) {
            if tail == nil, line == marker {
                tail = []
            } else if tail == nil {
                head.append(line)
            } else {
                tail?.append(line)
            }
        }

        func join(_ lines: [Substring]) -> String {
            var text = lines.joined(separator: "\n")
            while text.hasSuffix("\n") { text.removeLast() }
            return text
        }

        return (head: join(head), tail: tail.map(join))
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter RemoteScriptOutputTests`
Expected: PASS, 5 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/AISessionCore/Tmux/RemoteScriptOutput.swift Tests/AISessionCoreTests/RemoteScriptOutputTests.swift
git commit -m "feat: add RemoteScriptOutput.split for merged remote scripts"
```

---

### Task 3: SessionMetadata printf template

`SessionMetadata.cli` holds the resolved binary path, which is only known on the host. To write metadata and create the session in one command, the JSON must be emitted as a `printf` format string with a single `%s` slot — which means every other literal `%` has to be escaped, or a session titled `100% done` corrupts the file.

**Files:**
- Modify: `Sources/AISessionCore/Models/SessionMetadata.swift`
- Test: `Tests/AISessionCoreTests/SessionMetadataTests.swift`

**Interfaces:**
- Produces:
  `SessionMetadata.printfTemplate(tool:cwd:title:startedAt:) throws -> String`,
  `SessionMetadata.TemplateError.placeholderCollision`.

- [ ] **Step 1: Write the failing test**

Append to `Tests/AISessionCoreTests/SessionMetadataTests.swift`:

```swift
func testPrintfTemplateHasExactlyOneSubstitutionSlot() throws {
    let template = try SessionMetadata.printfTemplate(
        tool: .claude,
        cwd: "/tmp/demo",
        title: "Demo",
        startedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    XCTAssertEqual(template.components(separatedBy: "%s").count - 1, 1)
    XCTAssertTrue(template.contains("\"cli\":[\"%s\"]"))
}

/// A literal `%` in user text must survive printf. Without escaping, a title of
/// "100% done" makes printf consume "% d" as a conversion and corrupt the metadata file.
func testPrintfTemplateEscapesLiteralPercentInTitle() throws {
    let template = try SessionMetadata.printfTemplate(
        tool: .claude,
        cwd: "/tmp",
        title: "100% done",
        startedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    XCTAssertTrue(template.contains("100%% done"))
    XCTAssertEqual(template.components(separatedBy: "%s").count - 1, 1)
}

/// The template is only useful if feeding it through printf yields JSON that decodes back
/// into the same metadata. This is the end-to-end guard on escaping.
func testPrintfTemplateRoundTripsThroughPrintf() throws {
    let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let template = try SessionMetadata.printfTemplate(
        tool: .claude, cwd: "/tmp", title: "100% done", startedAt: startedAt
    )

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/printf")
    process.arguments = [template, "/usr/local/bin/claude"]
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    let decoded = try SessionMetadata.from(jsonData: data)
    XCTAssertEqual(decoded.title, "100% done")
    XCTAssertEqual(decoded.cli, ["/usr/local/bin/claude"])
    XCTAssertEqual(decoded.tool, .claude)
    XCTAssertEqual(decoded.cwd, "/tmp")
}
```

Ensure the file imports `Foundation`.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SessionMetadataTests`
Expected: FAIL — no member `printfTemplate`.

- [ ] **Step 3: Implement**

Append to `Sources/AISessionCore/Models/SessionMetadata.swift`:

```swift
public extension SessionMetadata {
    enum TemplateError: Error, Equatable {
        /// The encoded JSON did not contain exactly one placeholder — meaning user-supplied
        /// text collided with it, so substituting would corrupt the document.
        case placeholderCollision
    }

    /// Token standing in for the `cli` entry while the JSON is encoded, then swapped for `%s`.
    static let cliPlaceholder = "__AI_REMOTE_CLI_PATH__"

    /// JSON for this session's metadata as a `printf` **format string** taking exactly one
    /// argument: the binary path resolved on the host.
    ///
    /// The binary path is only known remotely, so metadata cannot be fully encoded on the
    /// client. Every literal `%` is escaped to `%%` so user text such as a "100% done" title
    /// survives `printf` intact.
    static func printfTemplate(
        tool: AITool,
        cwd: String,
        title: String,
        startedAt: Date
    ) throws -> String {
        let templated = SessionMetadata(
            tool: tool, cwd: cwd, title: title, startedAt: startedAt, cli: [cliPlaceholder]
        )
        let json = String(decoding: try templated.jsonData(), as: UTF8.self)

        guard json.components(separatedBy: cliPlaceholder).count - 1 == 1 else {
            throw TemplateError.placeholderCollision
        }

        return json
            .replacingOccurrences(of: "%", with: "%%")
            .replacingOccurrences(of: cliPlaceholder, with: "%s")
    }
}
```

Note the order: `%` is escaped **before** the placeholder becomes `%s`, and the placeholder itself contains no `%`, so the substitution slot is never double-escaped.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter SessionMetadataTests`
Expected: PASS.

If `testPrintfTemplateHasExactlyOneSubstitutionSlot` fails on the `"cli":[\"%s\"]` assertion, `JSONEncoder` ordered the keys differently than expected — check the actual output and assert on `"%s"` presence plus decodability only; do not add `outputFormatting: .sortedKeys`, which would change the on-host file format.

- [ ] **Step 5: Commit**

```bash
git add Sources/AISessionCore/Models/SessionMetadata.swift Tests/AISessionCoreTests/SessionMetadataTests.swift
git commit -m "feat: add printf-template encoding for session metadata"
```

---

### Task 4: Merged tmux script builders

**Files:**
- Modify: `Sources/AISessionCore/Tmux/TmuxCommandBuilder.swift`
- Test: `Tests/AISessionCoreTests/TmuxCommandBuilderTests.swift`

**Interfaces:**
- Consumes: `RemoteScriptOutput.statusMarker` (Task 2), `SessionMetadata.printfTemplate` output (Task 3).
- Produces:
  `TmuxCommandBuilder.listSessionsWithStatuses() -> String`,
  `TmuxCommandBuilder.createSession(name:cwd:binary:metadataTemplate:) -> String`,
  `TmuxCommandBuilder.promoteSession(fromTmuxName:toTmuxName:json:) -> String`.

- [ ] **Step 1: Write the failing test**

Append to `Tests/AISessionCoreTests/TmuxCommandBuilderTests.swift`:

```swift
func testListSessionsWithStatusesEmitsMarkerAndPreservesLsExitCode() {
    let command = TmuxCommandBuilder.listSessionsWithStatuses()
    XCTAssertTrue(command.contains("tmux ls -F"))
    XCTAssertTrue(command.contains("echo '\(RemoteScriptOutput.statusMarker)'"))
    // The script must exit with tmux ls's status so isNoServerError still fires.
    XCTAssertTrue(command.contains("exit $ls_exit"))
}

func testCreateSessionScriptUsesExitNinetyForMissingBinary() throws {
    // SessionName.init(tool:slug:) is failable, not throwing.
    let name = try XCTUnwrap(SessionName(tool: .claude, slug: "demo"))
    let command = TmuxCommandBuilder.createSession(
        name: name, cwd: "/tmp/demo", binary: "claude", metadataTemplate: "{\"cli\":[\"%s\"]}"
    )
    XCTAssertTrue(command.contains("command -v 'claude'"))
    XCTAssertTrue(command.contains("|| exit 90"))
    // exec so tmux's own exit code and stderr reach the client for duplicate detection.
    XCTAssertTrue(command.contains("exec tmux new-session -d -s 'ai/claude/demo'"))
    XCTAssertTrue(command.contains("-- \"$p\""))
}

func testCreateSessionScriptQuotesTemplateContainingSingleQuote() throws {
    let name = try XCTUnwrap(SessionName(tool: .claude, slug: "demo"))
    let command = TmuxCommandBuilder.createSession(
        name: name, cwd: "/tmp", binary: "claude", metadataTemplate: "{\"title\":\"it's\"}"
    )
    // shellQuote's '"'"' escape must appear so the quote cannot terminate the literal early.
    XCTAssertTrue(command.contains("'\"'\"'"))
}

func testPromoteSessionScriptMergesRenameAndMetadata() {
    let command = TmuxCommandBuilder.promoteSession(
        fromTmuxName: "old", toTmuxName: "ai/claude/demo", json: "{}"
    )
    XCTAssertTrue(command.contains("tmux rename-session -t 'old' 'ai/claude/demo'"))
    XCTAssertTrue(command.contains("printf '%s'"))
    XCTAssertTrue(command.contains("ai__claude__demo.json"))
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter TmuxCommandBuilderTests`
Expected: FAIL — no member `listSessionsWithStatuses`.

- [ ] **Step 3: Implement**

Add to `TmuxCommandBuilder`, keeping the existing methods in place (they remain used by `probeTmux`, `probeBinaries`, `attach`, `killSession`):

```swift
    /// `tmux ls` and the agent-status dump in one round trip.
    ///
    /// The script exits with `tmux ls`'s own status and leaves its stderr untouched — SSH
    /// carries stderr separately — so `SessionService`'s no-server detection is unchanged.
    /// The status dump only runs when `ls` succeeded, and its own failure is ignored because
    /// agent statuses are supplemental.
    public static func listSessionsWithStatuses() -> String {
        wrap(
            """
            tmux ls -F '#{session_name}\\t#{session_activity}\\t#{session_attached}'; ls_exit=$?
            echo '\(RemoteScriptOutput.statusMarker)'
            if [ $ls_exit -eq 0 ]; then mkdir -p ~/.ai-remote/status; for f in ~/.ai-remote/status/*.json; do [ -f "$f" ] && echo "---$(basename "$f")---" && cat "$f"; done; fi
            exit $ls_exit
            """
        )
    }

    /// Resolve the CLI, write metadata, and start the detached session in one round trip.
    ///
    /// `metadataTemplate` is a `printf` format string with a single `%s` slot for the resolved
    /// binary path (see `SessionMetadata.printfTemplate`), because that path is only known here
    /// on the host. The script ends in `exec` so the result's exit code and stderr are tmux's
    /// own, keeping duplicate-name detection working.
    ///
    /// Exit codes: 90 CLI missing, 91 metadata directory failed, 92 metadata write failed.
    public static func createSession(
        name: SessionName,
        cwd: String,
        binary: String,
        metadataTemplate: String
    ) -> String {
        let file = SessionMetadataStore.filename(for: name.tmuxName)
        return wrap(
            """
            p=$(command -v \(shellQuote(binary))) || exit 90
            mkdir -p ~/.ai-remote/sessions || exit 91
            printf \(shellQuote(metadataTemplate)) "$p" > ~/.ai-remote/sessions/\(shellQuote(file)) || exit 92
            exec tmux new-session -d -s \(shellQuote(name.tmuxName)) -c \(shellQuote(cwd)) -- "$p"
            """
        )
    }

    /// Rename a session and write its metadata in one round trip. The metadata JSON is passed
    /// as a `printf '%s'` argument rather than a format string, so no escaping is needed.
    public static func promoteSession(
        fromTmuxName: String,
        toTmuxName: String,
        json: String
    ) -> String {
        let file = SessionMetadataStore.filename(for: toTmuxName)
        return wrap(
            """
            tmux rename-session -t \(shellQuote(fromTmuxName)) \(shellQuote(toTmuxName)) || exit $?
            mkdir -p ~/.ai-remote/sessions || exit 91
            printf '%s' \(shellQuote(json)) > ~/.ai-remote/sessions/\(shellQuote(file)) || exit 92
            """
        )
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter TmuxCommandBuilderTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/AISessionCore/Tmux/TmuxCommandBuilder.swift Tests/AISessionCoreTests/TmuxCommandBuilderTests.swift
git commit -m "feat: add merged tmux script builders"
```

---

### Task 5: SessionService uses merged commands

This is the task that actually removes round trips. The exec-count assertions here are the regression guard for the whole feature.

**Files:**
- Modify: `Sources/AISessionCore/Services/SessionService.swift:51-81` (`listSessions`), `:83-160` (`createSession`), `:173-200` (`promoteSession`)
- Test: `Tests/AISessionCoreTests/SessionServiceTests.swift`

**Interfaces:**
- Consumes: Tasks 1–4.
- Produces: no signature changes. `listSessions`, `createSession`, `promoteSession` keep their current signatures and error behaviour.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/AISessionCoreTests/SessionServiceTests.swift`:

```swift
private func mergedListResult(sessions: String, statuses: String) -> SSHExecResult {
    SSHExecResult(
        exitCode: 0,
        stdout: "\(sessions)\n\(RemoteScriptOutput.statusMarker)\n\(statuses)",
        stderr: ""
    )
}

func testListSessionsIssuesExactlyOneExec() async throws {
    let executor = FakeSSHExecutor(responsesByPrefix: [
        "tmux ls": mergedListResult(sessions: "ai/claude/demo\t1700000000\t0", statuses: "")
    ])
    let service = SessionService(ssh: executor)

    let listed = try await service.listSessions(config: config)

    XCTAssertEqual(executor.recordedCommands.count, 1)
    XCTAssertEqual(listed.ai.map(\.tmuxName), ["ai/claude/demo"])
}

func testListSessionsAppliesAgentStatusesFromMergedOutput() async throws {
    let executor = FakeSSHExecutor(responsesByPrefix: [
        "tmux ls": mergedListResult(
            sessions: "ai/claude/demo\t1700000000\t0",
            statuses: "---ai__claude__demo.json---\n{\"status\":\"busy\"}"
        )
    ])
    let service = SessionService(ssh: executor)

    let listed = try await service.listSessions(config: config)

    XCTAssertEqual(listed.ai.first?.status, .busy)
}

func testCreateSessionIssuesTwoExecsOnHappyPath() async throws {
    let executor = FakeSSHExecutor(responsesByPrefix: [
        "tmux ls": mergedListResult(sessions: "", statuses: ""),
        "exec tmux new-session": SSHExecResult(exitCode: 0, stdout: "", stderr: "")
    ])
    let service = SessionService(ssh: executor)

    let name = try await service.createSession(
        config: config, tool: .claude, slug: "demo", cwd: "/tmp/demo", title: "Demo"
    )

    XCTAssertEqual(name.tmuxName, "ai/claude/demo")
    XCTAssertEqual(executor.recordedCommands.count, 2)
}

func testCreateSessionMapsExitNinetyToBinaryMissing() async throws {
    let executor = FakeSSHExecutor(responsesByPrefix: [
        "tmux ls": mergedListResult(sessions: "", statuses: ""),
        "exec tmux new-session": SSHExecResult(exitCode: 90, stdout: "", stderr: "")
    ])
    let service = SessionService(ssh: executor)

    do {
        _ = try await service.createSession(
            config: config, tool: .claude, slug: "demo", cwd: "/tmp", title: nil
        )
        XCTFail("expected binaryMissing")
    } catch let error as SSHRemoteError {
        XCTAssertEqual(error, .binaryMissing("claude"))
    }
}

func testPromoteSessionIssuesExactlyOneExec() async throws {
    let executor = FakeSSHExecutor(responsesByPrefix: [
        "tmux rename-session": SSHExecResult(exitCode: 0, stdout: "", stderr: "")
    ])
    let service = SessionService(ssh: executor)

    try await service.promoteSession(
        config: config,
        fromTmuxName: "old",
        to: try XCTUnwrap(SessionName(tool: .claude, slug: "demo"))
    )

    XCTAssertEqual(executor.recordedCommands.count, 1)
}
```

Then update the **existing** tests whose canned stubs reference now-merged commands. Keep every assertion identical; change only the stub keys and stdout so they describe the merged commands:

- `testCreateAndListSession` — replace the `"command -v 'claude'"`, `"mkdir -p"`, `"tmux new-session"` and bare `"tmux ls"` stubs with the two stubs used in `testCreateSessionIssuesTwoExecsOnHappyPath`.
- Any test asserting the no-server path keeps its `stderr` and non-zero `exitCode` stub unchanged — that path is deliberately untouched by this refactor.
- Any test asserting duplicate-name retry keeps its stderr stub, but keyed on `"exec tmux new-session"` instead of `"tmux new-session"`.

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SessionServiceTests`
Expected: FAIL — exec counts are 2/5/2 rather than 1/2/1.

- [ ] **Step 3: Rewrite listSessions**

Replace the body of `listSessions` (`Sources/AISessionCore/Services/SessionService.swift:51`):

```swift
    public func listSessions(
        config: HostConnectionConfig
    ) async throws -> (ai: [RemoteSession], other: [RemoteSession]) {
        do {
            let result = try await ssh.exec(config, command: TmuxCommandBuilder.listSessionsWithStatuses())
            if result.exitCode == 0 {
                let (listOutput, statusOutput) = RemoteScriptOutput.split(
                    result.stdout, at: RemoteScriptOutput.statusMarker
                )
                let sessions = TmuxListParser.parse(listSessionsOutput: listOutput)
                // Agent status files are supplemental and must not make listing fail; a nil
                // tail means the dump never ran, which is not an error.
                guard let statusOutput, !statusOutput.isEmpty else { return sessions }
                return TmuxListParser.applyAgentStatuses(
                    TmuxListParser.parseAgentStatuses(output: statusOutput),
                    to: sessions
                )
            }
            guard isNoServerError(result.stderr) else {
                throw SSHRemoteError.commandFailed(exitCode: result.exitCode, stderr: result.stderr)
            }
            return (ai: [], other: [])
        } catch let error as SSHRemoteError {
            if case let .commandFailed(_, stderr) = error, isNoServerError(stderr) {
                return (ai: [], other: [])
            }
            throw error
        }
    }
```

- [ ] **Step 4: Rewrite createSession's per-attempt body**

Inside the existing `for _ in 0..<3` loop, replace everything from the `which` exec through the `newDetachedSession` exec with:

```swift
            let template: String
            do {
                template = try SessionMetadata.printfTemplate(
                    tool: tool,
                    cwd: cwd,
                    title: title ?? slug,
                    startedAt: Date()
                )
            } catch {
                throw SessionServiceError.metadataEncodingFailed
            }

            do {
                let result = try await ssh.exec(
                    config,
                    command: TmuxCommandBuilder.createSession(
                        name: name, cwd: cwd, binary: binary, metadataTemplate: template
                    )
                )
                switch result.exitCode {
                case 0:
                    return name
                case 90:
                    throw SSHRemoteError.binaryMissing(binary)
                default:
                    let error = SSHRemoteError.commandFailed(
                        exitCode: result.exitCode, stderr: result.stderr
                    )
                    guard isDuplicateSessionError(result.stderr) else { throw error }
                    lastDuplicateError = error
                    continue
                }
            } catch let error as SSHRemoteError {
                guard isDuplicateSessionError(error) else { throw error }
                lastDuplicateError = error
            }
```

The surrounding retry loop, `SessionName.makeUnique` call, and `lastDuplicateError` handling are unchanged.

- [ ] **Step 5: Rewrite promoteSession**

Replace its two execs with one:

```swift
        let metadata = SessionMetadata(
            tool: name.tool,
            cwd: "/",
            title: name.slug,
            startedAt: Date(),
            cli: [name.tool.defaultBinary]
        )
        guard let json = String(data: try metadata.jsonData(), encoding: .utf8) else {
            throw SessionServiceError.metadataEncodingFailed
        }
        let result = try await ssh.exec(
            config,
            command: TmuxCommandBuilder.promoteSession(
                fromTmuxName: fromTmuxName, toTmuxName: name.tmuxName, json: json
            )
        )
        try requireSuccess(result)
```

- [ ] **Step 6: Run the full core suite**

Run: `swift test`
Expected: PASS. `testRemoteErrorMessagesAreActionableAndConsistent` must still pass untouched — it is the guard that no user-facing message changed.

- [ ] **Step 7: Commit**

```bash
git add Sources/AISessionCore/Services/SessionService.swift Tests/AISessionCoreTests/SessionServiceTests.swift
git commit -m "perf: collapse session list, create, and promote into single remote scripts"
```

---

### Task 6: TerminalOutputCoalescer

Each inbound SSH frame currently gets its own main-thread dispatch, `feed`, and redraw. At high latency output arrives as fewer, larger bursts split across many frames, so one logical repaint becomes dozens of hops.

**Files:**
- Create: `App/AISessionRemote/Terminal/TerminalOutputCoalescer.swift`
- Test: `App/AISessionRemoteTests/TerminalOutputCoalescerTests.swift`

**Interfaces:**
- Produces: `TerminalOutputCoalescer(scheduleDrain:)`, `.append(_ bytes: [UInt8])`, `.onFlush: (([UInt8]) -> Void)?`.

- [ ] **Step 1: Write the failing test**

Create `App/AISessionRemoteTests/TerminalOutputCoalescerTests.swift`:

```swift
import XCTest
@testable import AISessionRemote

final class TerminalOutputCoalescerTests: XCTestCase {
    func testManyAppendsProduceOneFlushInOrder() {
        var pendingDrain: (() -> Void)?
        let coalescer = TerminalOutputCoalescer { drain in pendingDrain = drain }
        var flushed: [[UInt8]] = []
        coalescer.onFlush = { flushed.append($0) }

        coalescer.append([1, 2])
        coalescer.append([3])
        coalescer.append([4, 5])

        XCTAssertTrue(flushed.isEmpty, "must not flush before the scheduled drain runs")
        pendingDrain?()

        XCTAssertEqual(flushed, [[1, 2, 3, 4, 5]])
    }

    func testSchedulesOnlyOncePerPendingDrain() {
        var scheduleCount = 0
        var pendingDrain: (() -> Void)?
        let coalescer = TerminalOutputCoalescer { drain in
            scheduleCount += 1
            pendingDrain = drain
        }
        coalescer.onFlush = { _ in }

        coalescer.append([1])
        coalescer.append([2])
        coalescer.append([3])

        XCTAssertEqual(scheduleCount, 1)
        pendingDrain?()

        coalescer.append([4])
        XCTAssertEqual(scheduleCount, 2, "a new drain is scheduled after the previous one ran")
    }

    func testDrainWithNoPendingBytesDoesNotFlush() {
        var pendingDrain: (() -> Void)?
        let coalescer = TerminalOutputCoalescer { drain in pendingDrain = drain }
        var flushCount = 0
        coalescer.onFlush = { _ in flushCount += 1 }

        coalescer.append([1])
        pendingDrain?()
        pendingDrain?()

        XCTAssertEqual(flushCount, 1)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodegen generate
xcodebuild -scheme AISessionRemote -destination 'platform=iOS Simulator,name=iPhone 17' \
  test -only-testing:AISessionRemoteTests/TerminalOutputCoalescerTests
```
Expected: FAIL — cannot find `TerminalOutputCoalescer` in scope.

- [ ] **Step 3: Implement**

Create `App/AISessionRemote/Terminal/TerminalOutputCoalescer.swift`:

```swift
import Foundation

/// Batches bytes arriving on the SSH event loop into a single `feed()` per display frame.
///
/// Without this, every inbound SSH frame becomes its own main-thread dispatch and SwiftTerm
/// redraw. At high latency output arrives as fewer, larger bursts split across many frames,
/// so a single logical repaint would otherwise cost dozens of hops and dozens of redraws.
///
/// `scheduleDrain` is injected so tests can drive draining synchronously; production passes a
/// main-thread hop.
final class TerminalOutputCoalescer: @unchecked Sendable {
    /// Called on whichever thread `scheduleDrain` dispatches to.
    var onFlush: (([UInt8]) -> Void)?

    private let scheduleDrain: (@escaping () -> Void) -> Void
    private let lock = NSLock()
    private var buffer: [UInt8] = []
    private var drainScheduled = false

    init(scheduleDrain: @escaping (@escaping () -> Void) -> Void) {
        self.scheduleDrain = scheduleDrain
    }

    /// Safe to call from any thread.
    func append(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }

        lock.lock()
        buffer.append(contentsOf: bytes)
        let needsSchedule = !drainScheduled
        drainScheduled = true
        lock.unlock()

        guard needsSchedule else { return }
        scheduleDrain { [weak self] in self?.drain() }
    }

    private func drain() {
        lock.lock()
        let pending = buffer
        buffer.removeAll(keepingCapacity: true)
        drainScheduled = false
        lock.unlock()

        guard !pending.isEmpty else { return }
        onFlush?(pending)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
xcodebuild -scheme AISessionRemote -destination 'platform=iOS Simulator,name=iPhone 17' \
  test -only-testing:AISessionRemoteTests/TerminalOutputCoalescerTests
```
Expected: PASS, 3 tests.

- [ ] **Step 5: Commit**

```bash
git add App/AISessionRemote/Terminal/TerminalOutputCoalescer.swift App/AISessionRemoteTests/TerminalOutputCoalescerTests.swift
git commit -m "feat: add TerminalOutputCoalescer for per-frame terminal feeds"
```

---

### Task 7: SSHConnectionPool

The heart of the feature. Everything here is tested against a fake dial and a test-controlled sleep, so none of it needs a network.

**Files:**
- Create: `App/AISessionRemote/Services/SSH/PooledConnecting.swift`
- Create: `App/AISessionRemote/Services/SSH/SSHConnectionPool.swift`
- Test: `App/AISessionRemoteTests/SSHConnectionPoolTests.swift`

**Interfaces:**
- Consumes: `HostConnectionConfig`, `SSHExecResult`, `SSHRemoteError` from `AISessionCore`.
- Produces:
  - `protocol PooledConnecting: AnyObject, Sendable { var isAlive: Bool { get }; func exec(_ command: String) async throws -> SSHExecResult; func close() async }`
  - `actor SSHConnectionPool` with `init(idleTimeout:sleep:dial:)`, `func exec(_:command:) async throws -> SSHExecResult`, `func warm(_:)`, `func closeAll() async`, and `nonisolated static func key(for:) -> String`.
- Note for Task 9: `PooledConnecting` gains a PTY method there; leave room for it.

- [ ] **Step 1: Write the failing tests**

Create `App/AISessionRemoteTests/SSHConnectionPoolTests.swift`:

```swift
import AISessionCore
import XCTest
@testable import AISessionRemote

private final class FakeConnection: PooledConnecting, @unchecked Sendable {
    var isAlive = true
    var closeCount = 0
    /// When set, the next `exec` throws this once and then clears it.
    var failNextExecWith: Error?

    func exec(_ command: String) async throws -> SSHExecResult {
        if let error = failNextExecWith {
            failNextExecWith = nil
            isAlive = false
            throw error
        }
        return SSHExecResult(exitCode: 0, stdout: "ok", stderr: "")
    }

    func close() async { closeCount += 1; isAlive = false }
}

final class SSHConnectionPoolTests: XCTestCase {
    private func config(
        host: String = "example.com",
        user: String = "tester",
        key: Data = Data([1, 2, 3])
    ) -> HostConnectionConfig {
        HostConnectionConfig(host: host, port: 22, username: user, privateKeyPEM: key)
    }

    /// The core promise: a burst of concurrent commands pays one handshake, not N.
    func testConcurrentCallsShareASingleDial() async throws {
        let dialCount = Counter()
        let pool = SSHConnectionPool(
            sleep: { _ in try await Task.sleep(nanoseconds: 1_000_000) },
            dial: { _ in
                await dialCount.increment()
                try await Task.sleep(nanoseconds: 10_000_000)
                return FakeConnection()
            }
        )
        let config = config()

        await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<5 {
                group.addTask { _ = try await pool.exec(config, command: "tmux ls") }
            }
        }

        let count = await dialCount.value
        XCTAssertEqual(count, 1)
    }

    func testDifferentPrivateKeyForcesANewDial() async throws {
        let dialCount = Counter()
        let pool = SSHConnectionPool(
            sleep: { _ in try await Task.sleep(nanoseconds: 1_000_000) },
            dial: { _ in await dialCount.increment(); return FakeConnection() }
        )

        _ = try await pool.exec(config(key: Data([1])), command: "a")
        _ = try await pool.exec(config(key: Data([2])), command: "b")

        let count = await dialCount.value
        XCTAssertEqual(count, 2, "rotating the key must not reuse a connection authed with the old one")
    }

    /// Without this, pooling trades slowness for spurious "Could not reach the host" errors.
    func testDeadCachedConnectionIsEvictedAndRetriedOnce() async throws {
        let dialCount = Counter()
        let connections = ConnectionBox()
        let pool = SSHConnectionPool(
            sleep: { _ in try await Task.sleep(nanoseconds: 1_000_000) },
            dial: { _ in
                await dialCount.increment()
                let connection = FakeConnection()
                await connections.add(connection)
                return connection
            }
        )
        let config = config()

        _ = try await pool.exec(config, command: "first")
        await connections.failNextExecOnLast(SSHRemoteError.unreachable)

        let result = try await pool.exec(config, command: "second")

        XCTAssertEqual(result.stdout, "ok")
        let count = await dialCount.value
        XCTAssertEqual(count, 2, "one original dial plus one re-dial after eviction")
    }

    func testSecondFailurePropagates() async throws {
        let pool = SSHConnectionPool(
            sleep: { _ in try await Task.sleep(nanoseconds: 1_000_000) },
            dial: { _ in
                let connection = FakeConnection()
                connection.failNextExecWith = SSHRemoteError.unreachable
                return connection
            }
        )

        do {
            _ = try await pool.exec(config(), command: "boom")
            XCTFail("expected the retry to surface the underlying error")
        } catch let error as SSHRemoteError {
            XCTAssertEqual(error, .unreachable)
        }
    }

    func testIdleConnectionIsClosedAfterTimeout() async throws {
        let connections = ConnectionBox()
        let pool = SSHConnectionPool(
            idleTimeout: .milliseconds(1),
            sleep: { _ in try await Task.sleep(nanoseconds: 1_000_000) },
            dial: { _ in
                let connection = FakeConnection()
                await connections.add(connection)
                return connection
            }
        )

        _ = try await pool.exec(config(), command: "a")
        try await Task.sleep(nanoseconds: 200_000_000)

        let closes = await connections.lastCloseCount()
        XCTAssertEqual(closes, 1)
    }

    func testCloseAllClosesEveryConnection() async throws {
        let connections = ConnectionBox()
        let pool = SSHConnectionPool(
            sleep: { _ in try await Task.sleep(nanoseconds: 50_000_000) },
            dial: { _ in
                let connection = FakeConnection()
                await connections.add(connection)
                return connection
            }
        )

        _ = try await pool.exec(config(host: "a"), command: "x")
        _ = try await pool.exec(config(host: "b"), command: "y")
        await pool.closeAll()

        let total = await connections.totalCloseCount()
        XCTAssertEqual(total, 2)
    }
}

private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}

private actor ConnectionBox {
    private var connections: [FakeConnection] = []
    func add(_ connection: FakeConnection) { connections.append(connection) }
    func failNextExecOnLast(_ error: Error) { connections.last?.failNextExecWith = error }
    func lastCloseCount() -> Int { connections.last?.closeCount ?? 0 }
    func totalCloseCount() -> Int { connections.reduce(0) { $0 + $1.closeCount } }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodegen generate
xcodebuild -scheme AISessionRemote -destination 'platform=iOS Simulator,name=iPhone 17' \
  test -only-testing:AISessionRemoteTests/SSHConnectionPoolTests
```
Expected: FAIL — cannot find `PooledConnecting` / `SSHConnectionPool` in scope.

- [ ] **Step 3: Define the connection protocol**

Create `App/AISessionRemote/Services/SSH/PooledConnecting.swift`:

```swift
import AISessionCore

/// One live, authenticated SSH connection that can vend child channels.
///
/// Exists as a protocol so `SSHConnectionPool` — which owns all the interesting logic around
/// coalescing, leases, eviction and retry — can be tested without a network.
protocol PooledConnecting: AnyObject, Sendable {
    /// `false` once the connection has been observed to fail or has been closed. The pool uses
    /// this to avoid handing out a connection it already knows is dead.
    var isAlive: Bool { get }

    /// Opens a session channel, runs `command`, and returns once it exits.
    func exec(_ command: String) async throws -> SSHExecResult

    func close() async
}
```

- [ ] **Step 4: Implement the pool**

Create `App/AISessionRemote/Services/SSH/SSHConnectionPool.swift`:

```swift
import AISessionCore
import Crypto
import Foundation

/// Holds one authenticated SSH connection per host and multiplexes every remote command over
/// it, so only the first action on a host pays the ~7 round trips of TCP handshake, key
/// exchange and user authentication.
///
/// This is the same idea as OpenSSH's `ControlMaster`/`ControlPersist`.
actor SSHConnectionPool {
    private struct Entry {
        var connection: any PooledConnecting
        var leases: Int
        var idleTask: Task<Void, Never>?
    }

    private let idleTimeout: Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    private let dial: @Sendable (HostConnectionConfig) async throws -> any PooledConnecting

    private var entries: [String: Entry] = [:]
    private var dialsInFlight: [String: Task<any PooledConnecting, Error>] = [:]

    init(
        idleTimeout: Duration = .seconds(60),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        dial: @escaping @Sendable (HostConnectionConfig) async throws -> any PooledConnecting
    ) {
        self.idleTimeout = idleTimeout
        self.sleep = sleep
        self.dial = dial
    }

    /// Identity of a poolable connection. Includes a digest of the private key so that editing
    /// a host or rotating its key cannot silently reuse a connection authenticated as the
    /// previous user.
    nonisolated static func key(for config: HostConnectionConfig) -> String {
        let digest = SHA256.hash(data: config.privateKeyPEM)
        let fingerprint = digest.map { String(format: "%02x", $0) }.joined()
        return "\(config.hostID)|\(config.host)|\(config.port)|\(config.username)|\(fingerprint)"
    }

    /// Runs `command` on the pooled connection for `config`, dialing one if needed.
    ///
    /// If the cached connection turns out to be dead — Wi-Fi/cellular handoff, Tailscale
    /// re-route, iOS suspension — it is evicted and the command retried **once** on a fresh
    /// connection. Only a second failure reaches the caller.
    func exec(_ config: HostConnectionConfig, command: String) async throws -> SSHExecResult {
        do {
            return try await run(config, command: command, allowRetry: true)
        } catch {
            throw error
        }
    }

    /// Dials ahead of time so the next real action is fast. Failures are deliberately silent:
    /// the user did not ask for this, and the action that follows will report any real problem.
    func warm(_ config: HostConnectionConfig) {
        Task { [weak self] in
            _ = try? await self?.connection(for: config)
        }
    }

    func closeAll() async {
        let current = entries
        entries.removeAll()
        dialsInFlight.removeAll()
        for (_, entry) in current {
            entry.idleTask?.cancel()
            await entry.connection.close()
        }
    }

    // MARK: - Internals

    private func run(
        _ config: HostConnectionConfig,
        command: String,
        allowRetry: Bool
    ) async throws -> SSHExecResult {
        let connection = try await connection(for: config)
        let key = Self.key(for: config)
        acquireLease(key)

        do {
            let result = try await connection.exec(command)
            releaseLease(key)
            return result
        } catch {
            releaseLease(key)
            guard allowRetry else { throw error }
            await evict(key)
            return try await run(config, command: command, allowRetry: false)
        }
    }

    private func connection(for config: HostConnectionConfig) async throws -> any PooledConnecting {
        let key = Self.key(for: config)

        if let entry = entries[key], entry.connection.isAlive {
            return entry.connection
        }
        if entries[key] != nil {
            await evict(key)
        }

        // Coalesce: everyone arriving during a dial awaits the same task, so a list refresh
        // racing an attach produces one handshake rather than two.
        if let inFlight = dialsInFlight[key] {
            return try await inFlight.value
        }

        let task = Task { [dial] in try await dial(config) }
        dialsInFlight[key] = task

        do {
            let connection = try await task.value
            dialsInFlight[key] = nil
            entries[key] = Entry(connection: connection, leases: 0, idleTask: nil)
            scheduleIdleEviction(key)
            return connection
        } catch {
            dialsInFlight[key] = nil
            throw error
        }
    }

    private func acquireLease(_ key: String) {
        guard var entry = entries[key] else { return }
        entry.leases += 1
        entry.idleTask?.cancel()
        entry.idleTask = nil
        entries[key] = entry
    }

    private func releaseLease(_ key: String) {
        guard var entry = entries[key] else { return }
        entry.leases = max(0, entry.leases - 1)
        entries[key] = entry
        if entry.leases == 0 {
            scheduleIdleEviction(key)
        }
    }

    private func scheduleIdleEviction(_ key: String) {
        guard var entry = entries[key], entry.leases == 0 else { return }
        entry.idleTask?.cancel()
        entry.idleTask = Task { [weak self, sleep, idleTimeout] in
            try? await sleep(idleTimeout)
            guard !Task.isCancelled else { return }
            await self?.evictIfIdle(key)
        }
        entries[key] = entry
    }

    private func evictIfIdle(_ key: String) async {
        guard let entry = entries[key], entry.leases == 0 else { return }
        await evict(key)
    }

    private func evict(_ key: String) async {
        guard let entry = entries.removeValue(forKey: key) else { return }
        entry.idleTask?.cancel()
        await entry.connection.close()
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
xcodebuild -scheme AISessionRemote -destination 'platform=iOS Simulator,name=iPhone 17' \
  test -only-testing:AISessionRemoteTests/SSHConnectionPoolTests
```
Expected: PASS, 6 tests.

- [ ] **Step 6: Commit**

```bash
git add App/AISessionRemote/Services/SSH App/AISessionRemoteTests/SSHConnectionPoolTests.swift
git commit -m "feat: add SSHConnectionPool with coalescing, leases, and stale retry"
```

---

### Task 8: PooledSSHConnection and NIOSSHClient adapter

Move the real SwiftNIO dial/auth/exec machinery behind `PooledConnecting`, then make `NIOSSHClient` a thin `SSHExecuting` adapter over the pool. After this task, every `SessionService` call goes through one reused connection.

**Files:**
- Create: `App/AISessionRemote/Services/SSH/PooledSSHConnection.swift`
- Modify: `App/AISessionRemote/Services/NIOSSHClient.swift:236-409`

**Interfaces:**
- Consumes: `PooledConnecting`, `SSHConnectionPool` (Task 7); existing `SSHPrivateKeyAuthDelegate`, `TOFUServerAuthenticationDelegate`, `SSHConnectionErrorHandler`, `ExecOutputHandler`, `OpenSSHPrivateKeyParser`.
- Produces: `final class PooledSSHConnection: PooledConnecting` with `static func dial(_:hostKeyStore:connectTimeoutSeconds:handshakeDeadlineSeconds:execTimeoutSeconds:) async throws -> PooledSSHConnection`, and `SSHConnectionPool.shared`.

- [ ] **Step 1: Implement PooledSSHConnection**

Create `App/AISessionRemote/Services/SSH/PooledSSHConnection.swift`. Move the connection setup currently inline in `NIOSSHClient.exec` here verbatim — same bootstrap, same channel options, same timeouts, same error mapping — and keep the parent channel open instead of closing it after one command:

```swift
import AISessionCore
import Foundation
import NIOCore
import NIOPosix
import NIOSSH

/// One authenticated SSH connection kept open across many commands.
///
/// The error-mapping heuristic is unchanged from the original `NIOSSHClient.exec`: failures
/// before TCP is established map to `.unreachable`, failures after (handshake, host key, user
/// auth, channel setup) map to `.authenticationFailed`.
final class PooledSSHConnection: PooledConnecting, @unchecked Sendable {
    private static let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)

    private let channel: Channel
    private let execTimeoutSeconds: Int64
    private let lock = NSLock()
    private var _isAlive = true

    var isAlive: Bool {
        lock.withLock { _isAlive && channel.isActive }
    }

    private init(channel: Channel, execTimeoutSeconds: Int64) {
        self.channel = channel
        self.execTimeoutSeconds = execTimeoutSeconds
        channel.closeFuture.whenComplete { [weak self] _ in
            self?.lock.withLock { self?._isAlive = false }
        }
    }

    static func dial(
        _ config: HostConnectionConfig,
        hostKeyStore: TOFUHostKeyStore,
        connectTimeoutSeconds: Int64,
        handshakeDeadlineSeconds: Int64,
        execTimeoutSeconds: Int64
    ) async throws -> PooledSSHConnection {
        let privateKey: NIOSSHPrivateKey
        do {
            privateKey = try OpenSSHPrivateKeyParser.parse(pem: config.privateKeyPEM)
        } catch {
            throw SSHRemoteError.authenticationFailed
        }

        let authDelegate = SSHPrivateKeyAuthDelegate(username: config.username, privateKey: privateKey)
        let hostKeyDelegate = TOFUServerAuthenticationDelegate(hostID: config.hostID, store: hostKeyStore)

        let channel: Channel
        do {
            channel = try await ClientBootstrap(group: Self.eventLoopGroup)
                .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)
                // Keeps NAT/Tailscale mappings alive and surfaces a dropped connection in
                // seconds. swift-nio-ssh exposes no global-request API, so `keepalive@openssh.com`
                // is unavailable and TCP keepalive is the substitute.
                .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_KEEPALIVE), value: 1)
                .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_KEEPALIVE), value: 20)
                .connectTimeout(.seconds(connectTimeoutSeconds))
                .channelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        let sync = channel.pipeline.syncOperations
                        try sync.addHandler(
                            NIOSSHHandler(
                                role: .client(.init(userAuthDelegate: authDelegate, serverAuthDelegate: hostKeyDelegate)),
                                allocator: channel.allocator,
                                inboundChildChannelInitializer: nil
                            )
                        )
                        try sync.addHandler(SSHConnectionErrorHandler())
                    }
                }
                .connect(host: config.host, port: config.port)
                .get()
        } catch {
            throw SSHRemoteError.unreachable
        }

        return PooledSSHConnection(channel: channel, execTimeoutSeconds: execTimeoutSeconds)
    }

    func exec(_ command: String) async throws -> SSHExecResult {
        let sshHandler: NIOSSHHandler
        do {
            sshHandler = try await channel.pipeline.handler(type: NIOSSHHandler.self).get()
        } catch {
            throw SSHRemoteError.authenticationFailed
        }

        let resultPromise = channel.eventLoop.makePromise(of: SSHExecResult.self)
        let handler = ExecOutputHandler(command: command, resultPromise: resultPromise)
        let channelPromise = channel.eventLoop.makePromise(of: Channel.self)

        sshHandler.createChannel(channelPromise, channelType: .session) { childChannel, channelType in
            guard channelType == .session else {
                return childChannel.eventLoop.makeFailedFuture(SSHRemoteError.authenticationFailed)
            }
            return childChannel.eventLoop.makeCompletedFuture {
                try childChannel.pipeline.syncOperations.addHandler(handler)
                try childChannel.pipeline.syncOperations.addHandler(SSHConnectionErrorHandler())
            }
        }

        do {
            let childChannel = try await channelPromise.futureResult.get()
            // Bound how long a remote command may run before it is forcibly killed.
            let timeout = childChannel.eventLoop.scheduleTask(in: .seconds(execTimeoutSeconds)) {
                handler.markTimedOut()
                childChannel.close(promise: nil)
            }
            let result = try await resultPromise.futureResult.get()
            timeout.cancel()
            return result
        } catch {
            handler.failIfPending(error)
            lock.withLock { _isAlive = false }
            throw error
        }
    }

    func close() async {
        lock.withLock { _isAlive = false }
        try? await channel.close().get()
    }
}
```

Preserve whatever exec-timeout mechanism the current `NIOSSHClient.exec` uses — read `App/AISessionRemote/Services/NIOSSHClient.swift:265-409` and carry it across rather than inventing a new one. If its handshake deadline logic differs from the sketch above, keep the original.

- [ ] **Step 2: Reduce NIOSSHClient to a pool adapter**

Replace `NIOSSHClient`'s `exec` body and add a shared pool:

```swift
public struct NIOSSHClient: SSHExecuting {
    static let shared = SSHConnectionPool { config in
        try await PooledSSHConnection.dial(
            config,
            hostKeyStore: TOFUHostKeyStore(),
            connectTimeoutSeconds: 10,
            handshakeDeadlineSeconds: 15,
            execTimeoutSeconds: 30
        )
    }

    public init() {}

    public func exec(_ config: HostConnectionConfig, command: String) async throws -> SSHExecResult {
        try await Self.shared.exec(config, command: command)
    }
}
```

Keep `TOFUHostKeyStore`, `TOFUServerAuthenticationDelegate`, `SSHConnectionErrorHandler`, `SSHPrivateKeyAuthDelegate`, and `ExecOutputHandler` exactly as they are — they move under the pool unchanged and `TOFUHostKeyStoreTests` must keep passing.

Check `App/AISessionRemote/Services/SessionServiceFactory.swift` for the initialiser it uses; if it passes timeout arguments, keep those parameters on `NIOSSHClient.init` and thread them into the shared pool's dial closure rather than dropping them.

- [ ] **Step 3: Build and run the whole app suite**

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodegen generate
xcodebuild -scheme AISessionRemote -destination 'platform=iOS Simulator,name=iPhone 17' test
```
Expected: PASS, including the existing `TOFUHostKeyStoreTests` and `OpenSSHPrivateKeyParserTests`.

- [ ] **Step 4: Commit**

```bash
git add App/AISessionRemote/Services
git commit -m "perf: reuse one authenticated SSH connection per host for remote commands"
```

---

### Task 9: Terminal PTY over the pool

**Files:**
- Create: `App/AISessionRemote/Terminal/TerminalTransport.swift`
- Modify: `App/AISessionRemote/Services/SSH/PooledConnecting.swift`, `App/AISessionRemote/Services/SSH/PooledSSHConnection.swift`, `App/AISessionRemote/Services/SSH/SSHConnectionPool.swift`
- Modify: `App/AISessionRemote/Terminal/SSHTerminalSession.swift:109-293`

**Interfaces:**
- Consumes: Tasks 7–8.
- Produces:
  - `protocol TerminalTransport: AnyObject` with `onOutput`, `onDisconnect`, `connect(cols:rows:)`, `send(_:)`, `resize(cols:rows:)`, `disconnect()`.
  - `PooledConnecting.openPTY(mode:cols:rows:onOutput:onClose:) async throws -> PTYHandle`
  - `PTYHandle` with `send(_:)`, `resize(cols:rows:)`, `close()`.
  - `SSHConnectionPool.openPTY(_:mode:cols:rows:onOutput:onClose:) async throws -> PTYHandle`, which holds a lease until the handle closes.
- `SSHTerminalSession` keeps its existing public surface and now conforms to `TerminalTransport`.

- [ ] **Step 1: Define the transport seam**

Create `App/AISessionRemote/Terminal/TerminalTransport.swift`:

```swift
/// What `TerminalCoordinator` needs from whatever moves bytes to and from the remote PTY.
///
/// Stage 2 adds a Mosh implementation beside `SSHTerminalSession` with no change to
/// `TerminalScreen`.
protocol TerminalTransport: AnyObject {
    /// Invoked off the main thread. Consumers must hop before touching UI.
    var onOutput: (([UInt8]) -> Void)? { get set }
    /// Invoked once when the connection goes away for any reason other than `disconnect()`.
    var onDisconnect: (() -> Void)? { get set }

    func connect(cols: Int, rows: Int) async throws
    func send(_ bytes: ArraySlice<UInt8>)
    func resize(cols: Int, rows: Int)
    func disconnect()
}
```

- [ ] **Step 2: Add PTY support to the connection protocol and pool**

Add to `PooledConnecting`:

```swift
    /// Opens a PTY channel and execs the attach command, keeping the channel open for the life
    /// of the terminal screen.
    func openPTY(
        mode: TerminalMode,
        cols: Int,
        rows: Int,
        onOutput: @escaping ([UInt8]) -> Void,
        onClose: @escaping () -> Void
    ) async throws -> PTYHandle
```

Add `PTYHandle` in the same file:

```swift
/// Handle on an open PTY channel. Releasing it (via `close()`) drops the pool lease that keeps
/// the underlying connection alive.
final class PTYHandle: @unchecked Sendable {
    private let sendBytes: (ArraySlice<UInt8>) -> Void
    private let resizeTo: (Int, Int) -> Void
    private let closeChannel: () -> Void

    init(
        send: @escaping (ArraySlice<UInt8>) -> Void,
        resize: @escaping (Int, Int) -> Void,
        close: @escaping () -> Void
    ) {
        self.sendBytes = send
        self.resizeTo = resize
        self.closeChannel = close
    }

    func send(_ bytes: ArraySlice<UInt8>) { sendBytes(bytes) }
    func resize(cols: Int, rows: Int) { resizeTo(cols, rows) }
    func close() { closeChannel() }
}
```

In `PooledSSHConnection`, implement `openPTY` by moving `SSHTerminalSession.openSessionChannel` across as-is — same `PTYChannelHandler`, same `SSHConnectionErrorHandler` — but creating the child channel on the pooled parent channel instead of dialing. Convert the handler's `ByteBuffer` output to `[UInt8]` at this boundary so `TerminalTransport` stays NIO-free.

In `SSHConnectionPool`, add:

```swift
    /// Opens a PTY on the pooled connection, holding a lease until the returned handle closes,
    /// so an attached terminal is never idle-evicted out from under the user.
    func openPTY(
        _ config: HostConnectionConfig,
        mode: TerminalMode,
        cols: Int,
        rows: Int,
        onOutput: @escaping ([UInt8]) -> Void,
        onClose: @escaping () -> Void
    ) async throws -> PTYHandle {
        let connection = try await connection(for: config)
        let key = Self.key(for: config)
        acquireLease(key)

        let releaseOnce = OnceFlag()
        func release() {
            Task { [weak self] in
                guard await releaseOnce.claim() else { return }
                await self?.releaseLeaseExternally(key)
            }
        }

        do {
            let handle = try await connection.openPTY(
                mode: mode, cols: cols, rows: rows,
                onOutput: onOutput,
                onClose: { onClose(); release() }
            )
            return PTYHandle(
                send: { handle.send($0) },
                resize: { handle.resize(cols: $0, rows: $1) },
                close: { handle.close(); release() }
            )
        } catch {
            release()
            throw error
        }
    }

    func releaseLeaseExternally(_ key: String) { releaseLease(key) }
```

Add alongside it:

```swift
/// Guards a lease release that can arrive from both `onClose` and an explicit `close()`.
actor OnceFlag {
    private var claimed = false
    func claim() -> Bool {
        guard !claimed else { return false }
        claimed = true
        return true
    }
}
```

- [ ] **Step 3: Rewire SSHTerminalSession onto the pool**

In `SSHTerminalSession`, delete the `MultiThreadedEventLoopGroup`, the `ClientBootstrap` dial in `connect(cols:rows:)`, the `parentChannel` state and its lock-guarded accessors, and `openSessionChannel`. Keep `PTYChannelHandler` exactly as-is — `PooledSSHConnection` now installs it.

The class becomes:

```swift
final class SSHTerminalSession: TerminalTransport {
    var onOutput: (([UInt8]) -> Void)?
    var onDisconnect: (() -> Void)?

    private let config: HostConnectionConfig
    private let mode: TerminalMode
    private let pool: SSHConnectionPool
    private let stateLock = NSLock()
    private var _handle: PTYHandle?
    private var _isDisconnecting = false

    init(
        config: HostConnectionConfig,
        mode: TerminalMode,
        pool: SSHConnectionPool = NIOSSHClient.shared
    ) {
        self.config = config
        self.mode = mode
        self.pool = pool
    }

    func connect(cols: Int, rows: Int) async throws {
        let handle = try await pool.openPTY(
            config, mode: mode, cols: cols, rows: rows,
            onOutput: { [weak self] bytes in self?.onOutput?(bytes) },
            onClose: { [weak self] in self?.notifyDisconnectedIfNeeded() }
        )
        stateLock.withLock { _handle = handle }
    }

    func send(_ bytes: ArraySlice<UInt8>) {
        stateLock.withLock { _handle }?.send(bytes)
    }

    func resize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        stateLock.withLock { _handle }?.resize(cols: cols, rows: rows)
    }

    /// Closes the PTY channel only. The pooled SSH connection stays for other commands, and
    /// tmux keeps the session running on the host.
    func disconnect() {
        let handle: PTYHandle? = stateLock.withLock {
            guard !_isDisconnecting else { return nil }
            _isDisconnecting = true
            let handle = _handle
            _handle = nil
            return handle
        }
        handle?.close()
    }

    private func notifyDisconnectedIfNeeded() {
        let shouldNotify: Bool = stateLock.withLock {
            guard !_isDisconnecting else { return false }
            _isDisconnecting = true
            return true
        }
        guard shouldNotify else { return }
        onDisconnect?()
    }
}
```

Map the thrown errors so `TerminalCoordinator.message(for:)` still produces its existing strings: `SSHRemoteError.unreachable` from a failed dial already maps via the `SSHRemoteError` branch, and a channel-setup failure should throw `SSHTerminalSessionError.channelSetupFailed`.

- [ ] **Step 4: Update TerminalCoordinator's output callback**

In `TerminalScreen.swift`, `session.onOutput` now receives `[UInt8]` rather than a `ByteBuffer`, so the `readBytes` dance disappears:

```swift
        session.onOutput = { [weak self] bytes in
            DispatchQueue.main.async {
                self?.terminalView?.feed(byteArray: bytes[...])
            }
        }
```

Task 11 replaces this with the coalescer; keep it simple here so the build stays green.

Change `TerminalCoordinator`'s stored property to the protocol: `private var session: (any TerminalTransport)?`.

- [ ] **Step 5: Build and run the app suite**

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodegen generate
xcodebuild -scheme AISessionRemote -destination 'platform=iOS Simulator,name=iPhone 17' test
```
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add App/AISessionRemote
git commit -m "perf: open terminal PTYs on the pooled SSH connection"
```

---

### Task 10: Pool lifecycle and warm-on-open

**Files:**
- Modify: `App/AISessionRemote/AISessionRemoteApp.swift`
- Modify: `App/AISessionRemote/Views/SessionsListView.swift:56-59`

**Interfaces:**
- Consumes: `NIOSSHClient.shared` (Task 8), `SSHConnectionPool.warm`, `.closeAll` (Task 7).

- [ ] **Step 1: Close the pool across app lifecycle transitions**

In `AISessionRemoteApp.swift`, attach to the root scene:

```swift
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.didEnterBackgroundNotification
        )) { _ in
            // iOS suspends sockets; a half-dead socket costs a full connect timeout on next
            // use, so closing eagerly is faster than discovering deadness later.
            Task { await NIOSSHClient.shared.closeAll() }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.didBecomeActiveNotification
        )) { _ in
            Task { await NIOSSHClient.shared.closeAll() }
        }
```

Add `import UIKit` if the file lacks it.

- [ ] **Step 2: Warm on host open**

In `SessionsListView`'s existing `.onAppear`, add the warm call beside the load:

```swift
        .onAppear {
            // Fire-and-forget: warm failures stay silent, and loadSessions reports any real
            // problem, so a speculative dial never surfaces an error the user did not provoke.
            if let config = try? host.connectionConfig() {
                Task { await NIOSSHClient.shared.warm(config) }
            }
            Task { await loadSessions() }
        }
```

Read `SessionsListView` and `HostRepository` for the actual way a `HostConnectionConfig` is obtained for a host (the helper may be named differently, and may be async or throwing) and use that call rather than the sketch above.

- [ ] **Step 3: Build and run the app suite**

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodegen generate
xcodebuild -scheme AISessionRemote -destination 'platform=iOS Simulator,name=iPhone 17' test
```
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add App/AISessionRemote
git commit -m "feat: warm the SSH pool on host open and close it across lifecycle changes"
```

---

### Task 11: Terminal repaint and render fixes

**Files:**
- Modify: `App/AISessionRemote/Terminal/TerminalScreen.swift:47-86` (`connect`), `:139-141` (`sizeChanged`), `:234-236` (overlay)

**Interfaces:**
- Consumes: `TerminalOutputCoalescer` (Task 6), `TerminalTransport` (Task 9).

- [ ] **Step 1: Feed through the coalescer**

In `TerminalCoordinator`, add a stored coalescer and route output through it:

```swift
    private lazy var coalescer: TerminalOutputCoalescer = {
        let coalescer = TerminalOutputCoalescer { drain in
            DispatchQueue.main.async(execute: drain)
        }
        coalescer.onFlush = { [weak self] bytes in
            self?.terminalView?.feed(byteArray: bytes[...])
        }
        return coalescer
    }()
```

and in `connect()`:

```swift
        session.onOutput = { [weak self] bytes in
            self?.coalescer.append(bytes)
        }
```

- [ ] **Step 2: Drop the redundant attach resize**

Replace the post-connect block in `connect()` (currently `TerminalScreen.swift:73-76`):

```swift
            try await session.connect(cols: cols, rows: rows)
            let liveTerminal = terminalView.getTerminal()
            // The PTY was already requested at cols x rows; only tell the host if the view
            // actually changed size while connecting. An unnecessary window-change makes tmux
            // repaint the whole screen.
            if liveTerminal.cols > 0, liveTerminal.rows > 0,
               liveTerminal.cols != cols || liveTerminal.rows != rows {
                session.resize(cols: liveTerminal.cols, rows: liveTerminal.rows)
                lastSentSize = (liveTerminal.cols, liveTerminal.rows)
            } else {
                lastSentSize = (cols, rows)
            }
            state = .connected
```

- [ ] **Step 3: Debounce resizes**

Add to `TerminalCoordinator`:

```swift
    private var lastSentSize: (cols: Int, rows: Int)?
    private var pendingResize: DispatchWorkItem?

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        guard newCols > 0, newRows > 0 else { return }
        guard lastSentSize == nil || lastSentSize! != (newCols, newRows) else { return }

        // Keyboard show/hide and rotation fire several times across layout passes, and each
        // window-change makes tmux repaint the entire screen. Send only the settled size.
        pendingResize?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lastSentSize = (newCols, newRows)
            self.session?.resize(cols: newCols, rows: newRows)
        }
        pendingResize = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }
```

Cancel `pendingResize` in `disconnect()`.

- [ ] **Step 4: Delay the connecting overlay**

In `TerminalScreen`, add `@State private var showConnectingOverlay = false`, gate the overlay on it, and drive it from the `.task`:

```swift
            if showConnectingOverlay && (connectionState == .connecting || connectionState == .idle) {
                connectingOverlay
            }
```

```swift
        .task {
            // With a warm pool, attach is fast enough that the overlay would only flash.
            let overlayTask = Task {
                try? await Task.sleep(nanoseconds: 250_000_000)
                if !Task.isCancelled { showConnectingOverlay = true }
            }
            await coordinator.connect()
            overlayTask.cancel()
            showConnectingOverlay = false
            try? await Task.sleep(nanoseconds: 150_000_000)
            coordinator.focusTerminal()
        }
```

- [ ] **Step 5: Build and run the app suite**

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodegen generate
xcodebuild -scheme AISessionRemote -destination 'platform=iOS Simulator,name=iPhone 17' test
```
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add App/AISessionRemote/Terminal/TerminalScreen.swift
git commit -m "perf: coalesce terminal output and stop redundant tmux repaints"
```

---

### Task 12: Latency acceptance measurement

Numbers in a spec that were never measured are wishes. This task verifies the feature actually delivered.

**Files:**
- Modify: `docs/superpowers/plans/manual-acceptance.md`

- [ ] **Step 1: Add the procedure**

Append to `docs/superpowers/plans/manual-acceptance.md`:

```markdown
## Stage 1 latency acceptance

Run on a physical device against a real host, with Network Link Conditioner enabled
(Settings → Developer → Network Link Conditioner → custom profile, 150 ms delay in both
directions, 0% loss).

Measure with a stopwatch, three runs each, recording the median. "Warm" means a prior action
on the same host completed within the last 60 seconds.

| action | before | target | measured |
| --- | --- | --- | --- |
| session list refresh (warm) | ~2.1 s | ~0.3 s | |
| new session (warm) | ~5.2 s | ~0.6 s | |
| attach to session (warm) | ~1.0 s | ~0.3 s | |
| kill session (warm) | ~1.0 s | ~0.3 s | |
| first action on a host (cold) | ~2.1 s | ~1.1 s | |

Also confirm by observation:

- [ ] Rotating the device and showing/hiding the keyboard causes at most one tmux repaint each.
- [ ] Attaching to a session does not produce a second full-screen repaint.
- [ ] Backgrounding the app for two minutes, then returning and refreshing, succeeds without
      an error alert (this exercises retry-once-on-stale).
- [ ] Switching Wi-Fi off mid-session, then back on, and refreshing the list succeeds without
      a spurious "Could not reach the host".
- [ ] Creating a session titled `100% done` writes valid metadata (verify on the host with
      `cat ~/.ai-remote/sessions/*.json`).
```

- [ ] **Step 2: Run the measurements and fill in the table**

Record real numbers in the `measured` column. If a warm action misses its target by more than
2×, stop and investigate before declaring Stage 1 done — the most likely causes are the pool
not being shared (check that `NIOSSHClient.shared` is the only pool instance) or a call site
still constructing its own connection.

- [ ] **Step 3: Commit**

```bash
git add docs/superpowers/plans/manual-acceptance.md
git commit -m "docs: record Stage 1 latency acceptance results"
```

---

## Self-Review Notes

Checked against the spec:

- **Spec coverage.** Pool coalescing/key/leases/eviction/retry → Task 7. Real NIO connection and `exec` adapter → Task 8. PTY on the pool → Task 9. Warm policy and lifecycle → Task 10. `RemoteScriptOutput.split` → Task 2. `printfTemplate` and `%` escaping → Task 3. Merged builders → Task 4. Merged service methods and exec-count guards → Task 5. Coalescer → Task 6. Redundant resize, debounce, overlay delay → Task 11. Success-criteria measurement → Task 12. `TerminalTransport` seam → Task 9. `FakeSSHExecutor` recording, called out in the spec as a prerequisite → Task 1.
- **Type consistency.** `RemoteScriptOutput.split` returns `(head:tail:)` in Tasks 2, 4 and 5. `printfTemplate(tool:cwd:title:startedAt:)` matches between Tasks 3 and 5. `PooledConnecting` gains `openPTY` in Task 9 having been introduced in Task 7, with Task 7's interface block flagging it. `SSHConnectionPool.key(for:)` is `nonisolated` and used only internally. `TerminalTransport.onOutput` is `[UInt8]`-based in Tasks 9 and 11, matching the coalescer's `append([UInt8])` from Task 6.
- **Deliberate flexibility.** Tasks 8, 9 and 10 tell the implementer to read the existing code and preserve its timeout, error-mapping and config-loading details rather than trusting the sketch, because those specifics were not fully read while planning. These are the only places where a sketch may need adjusting, and each says so explicitly.
