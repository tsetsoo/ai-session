# AI Session Remote Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a native SwiftUI iPhone app that SSHs over Tailscale to multiple hosts, manages tmux-backed Claude / Codex / Cursor CLI sessions, and attaches a real terminal — hosts-first, pull-only, with conventions ready for a future host agent.

**Architecture:** Pure-logic lives in a local SPM package `AISessionCore` (naming, metadata, tmux command builders, session discovery parsing, Keychain helpers). The iOS app owns SwiftUI, SwiftData host persistence, SwiftNIO SSH + SwiftTerm PTY wiring, and screens. v1 talks only SSH+tmux; optional `~/.ai-remote/` JSON is written on create for later agent use.

**Tech Stack:** Swift 5.9+, SwiftUI, SwiftData, Keychain, Swift Package Manager, `apple/swift-nio-ssh`, `migueldeicaza/SwiftTerm`, XcodeGen (`project.yml`) for the iOS app target, XCTest for core unit tests.

## Global Constraints

- iOS app only (iPhone); personal Team / TestFlight — not App Store in v1
- Session names MUST be `ai/<tool>/<slug>` with tools `claude` | `codex` | `cursor`
- Private keys ONLY in Keychain — never UserDefaults / SwiftData plaintext
- No push notifications, no host daemon in v1
- Default CLI binaries: `claude`, `codex`, `agent` (overridable per host)
- Metadata path: `~/.ai-remote/sessions/<tmux-name with / → __>.json`
- Network assumption: Tailscale already provides reachability
- YAGNI: no multi-pane tmux UI, no Cursor GUI control, no team sharing

---

## File structure

```text
ai-session-remote/
├── Package.swift                          # AISessionCore + tests
├── Sources/AISessionCore/
│   ├── Models/
│   │   ├── AITool.swift
│   │   ├── SessionIdentity.swift
│   │   ├── RemoteSession.swift
│   │   └── SessionMetadata.swift
│   ├── Naming/
│   │   └── SessionName.swift
│   ├── Tmux/
│   │   ├── TmuxListParser.swift
│   │   └── TmuxCommandBuilder.swift
│   ├── SSH/
│   │   ├── SSHExecuting.swift             # protocol for exec + shell
│   │   └── HostConnectionConfig.swift
│   └── Security/
│       └── KeychainPrivateKeyStore.swift
├── Tests/AISessionCoreTests/
│   ├── SessionNameTests.swift
│   ├── SessionMetadataTests.swift
│   ├── TmuxListParserTests.swift
│   ├── TmuxCommandBuilderTests.swift
│   └── KeychainPrivateKeyStoreTests.swift
├── project.yml                            # XcodeGen iOS app
├── App/
│   └── AISessionRemote/
│       ├── AISessionRemoteApp.swift
│       ├── Persistence/
│       │   └── HostEntity.swift           # SwiftData model
│       ├── Services/
│       │   ├── HostRepository.swift
│       │   ├── SessionService.swift
│       │   ├── ReachabilityProbe.swift
│       │   └── NIOSSHClient.swift
│       ├── Terminal/
│       │   ├── SSHTerminalSession.swift
│       │   └── TerminalScreen.swift
│       └── Views/
│           ├── HostsListView.swift
│           ├── HostEditorView.swift
│           ├── SessionsListView.swift
│           ├── NewSessionSheet.swift
│           └── SoftKeyBar.swift
├── docs/superpowers/specs/...
└── README.md
```

---

### Task 1: Scaffold AISessionCore package + SessionName

**Files:**
- Create: `Package.swift`
- Create: `Sources/AISessionCore/Models/AITool.swift`
- Create: `Sources/AISessionCore/Naming/SessionName.swift`
- Create: `Tests/AISessionCoreTests/SessionNameTests.swift`

**Interfaces:**
- Consumes: nothing
- Produces:
  - `public enum AITool: String, Codable, CaseIterable, Sendable` — cases `claude`, `codex`, `cursor`; `var defaultBinary: String` → `"claude"` / `"codex"` / `"agent"`
  - `public struct SessionName: Hashable, Sendable` — `tool: AITool`, `slug: String`; `var tmuxName: String`; `static func parse(_ tmuxName: String) -> SessionName?`; `static func makeUnique(tool:slug:existing:) -> SessionName`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import AISessionCore

final class SessionNameTests: XCTestCase {
    func testTmuxNameFormat() {
        let name = SessionName(tool: .claude, slug: "sigma-revenue")
        XCTAssertEqual(name.tmuxName, "ai/claude/sigma-revenue")
    }

    func testParseValid() {
        let parsed = SessionName.parse("ai/codex/overnight")
        XCTAssertEqual(parsed?.tool, .codex)
        XCTAssertEqual(parsed?.slug, "overnight")
    }

    func testParseRejectsNonAI() {
        XCTAssertNil(SessionName.parse("dev"))
        XCTAssertNil(SessionName.parse("ai/unknown/x"))
    }

    func testMakeUniqueSuffixes() {
        let existing = Set(["ai/claude/app", "ai/claude/app-2"])
        let name = SessionName.makeUnique(tool: .claude, slug: "app", existing: existing)
        XCTAssertEqual(name.tmuxName, "ai/claude/app-3")
    }

    func testDefaultBinaries() {
        XCTAssertEqual(AITool.claude.defaultBinary, "claude")
        XCTAssertEqual(AITool.codex.defaultBinary, "codex")
        XCTAssertEqual(AITool.cursor.defaultBinary, "agent")
    }
}
```

- [ ] **Step 2: Run tests — expect FAIL**

Run: `swift test --filter SessionNameTests`
Expected: FAIL (module / types missing)

- [ ] **Step 3: Implement Package.swift + types**

`Package.swift`:

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AISessionRemote",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "AISessionCore", targets: ["AISessionCore"])
    ],
    targets: [
        .target(name: "AISessionCore"),
        .testTarget(name: "AISessionCoreTests", dependencies: ["AISessionCore"])
    ]
)
```

Implement `AITool` and `SessionName` so tests pass. Slug rules: lowercase alphanumeric + hyphens only; reject empty; `parse` requires exactly `ai/<tool>/<slug>` with known tool.

`makeUnique`: if `ai/<tool>/<slug>` free, use it; else try `-2`, `-3`, … until free.

- [ ] **Step 4: Run tests — expect PASS**

Run: `swift test --filter SessionNameTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Package.swift Sources/AISessionCore Tests/AISessionCoreTests
git commit -m "feat(core): add AITool and SessionName tmux contract"
```

---

### Task 2: Session metadata encode/decode

**Files:**
- Create: `Sources/AISessionCore/Models/SessionMetadata.swift`
- Create: `Tests/AISessionCoreTests/SessionMetadataTests.swift`

**Interfaces:**
- Consumes: `AITool`, `SessionName`
- Produces:
  - `public struct SessionMetadata: Codable, Equatable, Sendable` — `tool`, `cwd`, `title`, `startedAt`, `cli: [String]`
  - `public enum SessionMetadataStore` — `static func filename(for tmuxName: String) -> String`; `static func remotePath(for tmuxName: String) -> String` → `"$HOME/.ai-remote/sessions/<file>"` as literal path template `"~/.ai-remote/sessions/\(filename)"`

- [ ] **Step 1: Write the failing tests**

```swift
func testFilenameReplacesSlashes() {
    XCTAssertEqual(
        SessionMetadataStore.filename(for: "ai/claude/sigma-revenue"),
        "ai__claude__sigma-revenue.json"
    )
}

func testRoundTripJSON() throws {
    let meta = SessionMetadata(
        tool: .cursor,
        cwd: "~/programming/portfolio-tracker",
        title: "portfolio",
        startedAt: Date(timeIntervalSince1970: 1_700_000_000),
        cli: ["agent"]
    )
    let data = try JSONEncoder().encode(meta)
    let decoded = try JSONDecoder().decode(SessionMetadata.self, from: data)
    XCTAssertEqual(decoded, meta)
}
```

Use `.iso8601` or encode `startedAt` as `TimeInterval` — pick **ISO-8601 with fractional seconds** via `JSONEncoder.dateEncodingStrategy = .iso8601` and document it in the type’s `encode` helpers:

```swift
public extension SessionMetadata {
    func jsonData() throws -> Data
    static func from(jsonData: Data) throws -> SessionMetadata
}
```

Tests should use `jsonData()` / `from(jsonData:)`.

- [ ] **Step 2: Run — expect FAIL**

Run: `swift test --filter SessionMetadataTests`

- [ ] **Step 3: Implement**

- [ ] **Step 4: Run — expect PASS**

- [ ] **Step 5: Commit**

```bash
git add Sources/AISessionCore/Models/SessionMetadata.swift Tests/AISessionCoreTests/SessionMetadataTests.swift
git commit -m "feat(core): add session metadata JSON contract"
```

---

### Task 3: Tmux list parser + command builder

**Files:**
- Create: `Sources/AISessionCore/Models/RemoteSession.swift`
- Create: `Sources/AISessionCore/Tmux/TmuxListParser.swift`
- Create: `Sources/AISessionCore/Tmux/TmuxCommandBuilder.swift`
- Create: `Tests/AISessionCoreTests/TmuxListParserTests.swift`
- Create: `Tests/AISessionCoreTests/TmuxCommandBuilderTests.swift`

**Interfaces:**
- Consumes: `SessionName`, `AITool`, `SessionMetadata`
- Produces:
  - `public struct RemoteSession: Equatable, Sendable` — `tmuxName`, `tool: AITool?` (nil if “Other”), `slug`, `cwd: String?`, `isAIManaged: Bool`
  - `public enum TmuxListParser` — `static func parse(listSessionsOutput: String) -> (ai: [RemoteSession], other: [RemoteSession])`
  - `public enum TmuxCommandBuilder` — methods returning shell strings (single-line, safely quoted with single-quote escaping):
    - `ensureTmuxInstalledCheck() -> String` → `command -v tmux`
    - `listSessions() -> String` → `tmux ls -F '#{session_name}'`
    - `newDetachedSession(name:cwd:commandArgs:) -> String`
    - `writeMetadata(tmuxName:json:) -> String` (mkdir + cat heredoc or printf)
    - `attach(tmuxName:) -> String` → `tmux attach -t ...`
    - `killSession(tmuxName:) -> String`
    - `which(binary:) -> String` → `command -v ...`

Shell quoting helper: wrap in single quotes; replace `'` with `'"'"'`.

- [ ] **Step 1: Write failing tests**

```swift
func testParseSplitsAIAndOther() {
    let output = """
    ai/claude/sigma-revenue: 1 windows (created …)
    ai/codex/overnight: 1 windows (created …)
    random: 1 windows (created …)
    """
    // If using -F '#{session_name}', output is one name per line:
}

func testParseFormatNamesOnly() {
    let output = "ai/claude/sigma-revenue\nai/codex/overnight\nrandom\n"
    let result = TmuxListParser.parse(listSessionsOutput: output)
    XCTAssertEqual(result.ai.map(\.tmuxName), ["ai/claude/sigma-revenue", "ai/codex/overnight"])
    XCTAssertEqual(result.other.map(\.tmuxName), ["random"])
}

func testNewSessionCommandQuotesCwd() {
    let cmd = TmuxCommandBuilder.newDetachedSession(
        name: SessionName(tool: .claude, slug: "app"),
        cwd: "/Users/me/proj with spaces",
        commandArgs: ["claude"]
    )
    XCTAssertTrue(cmd.contains("tmux new-session -d"))
    XCTAssertTrue(cmd.contains("-s 'ai/claude/app'"))
    XCTAssertTrue(cmd.contains("-c '/Users/me/proj with spaces'"))
}
```

- [ ] **Step 2: Run — FAIL**

- [ ] **Step 3: Implement parser + builder**

`newDetachedSession` shape:

```text
tmux new-session -d -s '<name>' -c '<cwd>' -- <arg0> <arg1> ...
```

- [ ] **Step 4: Run — PASS**

- [ ] **Step 5: Commit**

```bash
git add Sources/AISessionCore/Models/RemoteSession.swift Sources/AISessionCore/Tmux Tests/AISessionCoreTests/Tmux*.swift
git commit -m "feat(core): add tmux list parser and command builder"
```

---

### Task 4: Keychain private key store

**Files:**
- Create: `Sources/AISessionCore/Security/KeychainPrivateKeyStore.swift`
- Create: `Tests/AISessionCoreTests/KeychainPrivateKeyStoreTests.swift`

**Interfaces:**
- Consumes: nothing
- Produces:
  - `public struct KeychainPrivateKeyStore: Sendable` with
    - `func save(account: String, pem: Data) throws`
    - `func load(account: String) throws -> Data`
    - `func delete(account: String) throws`
  - Account string = host id UUID string
  - Service = `"com.aisessionremote.keys"`
  - Accessibility: `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`

- [ ] **Step 1: Write failing tests**

Use unique account UUID per test; save → load → equal; delete → load throws. Skip on Linux if Keychain unavailable — tests run on macOS.

```swift
func testSaveLoadDelete() throws {
    let store = KeychainPrivateKeyStore()
    let account = UUID().uuidString
    let pem = Data("-----BEGIN OPENSSH PRIVATE KEY-----\ntest\n-----END OPENSSH PRIVATE KEY-----\n".utf8)
    try store.save(account: account, pem: pem)
    XCTAssertEqual(try store.load(account: account), pem)
    try store.delete(account: account)
    XCTAssertThrowsError(try store.load(account: account))
}
```

- [ ] **Step 2: Run — FAIL**

- [ ] **Step 3: Implement with Security framework**

Link `Security` on Apple platforms (`#if canImport(Security)`).

- [ ] **Step 4: Run — PASS**

- [ ] **Step 5: Commit**

```bash
git add Sources/AISessionCore/Security Tests/AISessionCoreTests/KeychainPrivateKeyStoreTests.swift
git commit -m "feat(core): Keychain store for SSH private keys"
```

---

### Task 5: SSHExecuting protocol + HostConnectionConfig

**Files:**
- Create: `Sources/AISessionCore/SSH/SSHExecuting.swift`
- Create: `Sources/AISessionCore/SSH/HostConnectionConfig.swift`
- Create: `Sources/AISessionCore/SSH/FakeSSHExecutor.swift` (test double, `#if DEBUG` or in test target)
- Create: `Tests/AISessionCoreTests/FakeSSHExecutorTests.swift`

**Interfaces:**
- Consumes: nothing
- Produces:

```swift
public struct HostConnectionConfig: Equatable, Sendable {
    public var host: String
    public var port: Int
    public var username: String
    public var privateKeyPEM: Data
}

public struct SSHExecResult: Equatable, Sendable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String
}

public protocol SSHExecuting: Sendable {
    func exec(_ config: HostConnectionConfig, command: String) async throws -> SSHExecResult
    // Interactive shell/PTY is app-layer (SwiftNIO + SwiftTerm); core only needs exec for list/create/kill/probes.
}

public enum SSHRemoteError: Error, Equatable, Sendable {
    case unreachable
    case authenticationFailed
    case tmuxMissing
    case binaryMissing(String)
    case commandFailed(exitCode: Int32, stderr: String)
}
```

Put `FakeSSHExecutor` in **test target** (not production): map command prefix → canned `SSHExecResult`.

- [ ] **Step 1: Write test that Fake returns canned `tmux ls` output**

- [ ] **Step 2–4: Implement + pass**

- [ ] **Step 5: Commit**

```bash
git add Sources/AISessionCore/SSH Tests/AISessionCoreTests/FakeSSHExecutorTests.swift
git commit -m "feat(core): SSHExecuting protocol and test fake"
```

---

### Task 6: SessionService (list / create / kill) against SSHExecuting

**Files:**
- Create: `Sources/AISessionCore/Services/SessionService.swift`
- Create: `Tests/AISessionCoreTests/SessionServiceTests.swift`

**Interfaces:**
- Consumes: `SSHExecuting`, `TmuxCommandBuilder`, `TmuxListParser`, `SessionName`, `SessionMetadata`, `AITool`
- Produces:

```swift
public struct SessionService: Sendable {
    public init(ssh: SSHExecuting, binaryOverrides: [AITool: String] = [:])

    public func probeTmux(config: HostConnectionConfig) async throws
    public func listSessions(config: HostConnectionConfig) async throws -> (ai: [RemoteSession], other: [RemoteSession])
    public func createSession(
        config: HostConnectionConfig,
        tool: AITool,
        slug: String,
        cwd: String,
        title: String?
    ) async throws -> SessionName
    public func killSession(config: HostConnectionConfig, tmuxName: String) async throws
}
```

Behavior:
- `probeTmux`: run `command -v tmux`; non-zero → throw `.tmuxMissing`
- `listSessions`: `tmux ls -F '#{session_name}'`; empty/error “no server” → empty lists (not a hard failure)
- `createSession`: list existing → `makeUnique` → `which` binary (override or default) → if missing throw `.binaryMissing` → `writeMetadata` → `newDetachedSession` with argv `[binary]`
- `killSession`: `tmux kill-session -t …`

- [ ] **Step 1: Write failing tests with FakeSSHExecutor** covering happy path create+list, tmux missing, binary missing, unique suffix

- [ ] **Step 2: Run — FAIL**

- [ ] **Step 3: Implement SessionService**

- [ ] **Step 4: Run — PASS** (`swift test`)

- [ ] **Step 5: Commit**

```bash
git add Sources/AISessionCore/Services Tests/AISessionCoreTests/SessionServiceTests.swift
git commit -m "feat(core): SessionService list/create/kill over SSH exec"
```

---

### Task 7: XcodeGen iOS app shell + SwiftData HostEntity

**Files:**
- Create: `project.yml`
- Create: `App/AISessionRemote/AISessionRemoteApp.swift`
- Create: `App/AISessionRemote/Persistence/HostEntity.swift`
- Create: `App/AISessionRemote/Views/HostsListView.swift` (placeholder list)
- Create: `README.md` (build/run instructions)
- Modify: `.gitignore` (add `*.xcodeproj` is wrong if generated — **commit** generated project OR document `xcodegen generate`; prefer **commit** `AISessionRemote.xcodeproj` after generate for clone-and-open)

**Interfaces:**
- Consumes: `AISessionCore` as local package
- Produces SwiftData model:

```swift
@Model
final class HostEntity {
    @Attribute(.unique) var id: UUID
    var displayName: String
    var hostname: String
    var port: Int
    var username: String
    var privateKeyKeychainRef: String  // same as id.uuidString
    var defaultPathsJSON: String       // JSON array of strings
    var cliBinariesJSON: String        // JSON object tool→binary
    var lastReachableAt: Date?
}
```

Helpers on entity or `HostRepository` to get/set `[String]` paths and `[AITool: String]` binaries.

- [ ] **Step 1: Write `project.yml` targeting iOS 17, bundle id `com.aisessionremote.app`, local package dependency path `.`**

- [ ] **Step 2: Install/run XcodeGen**

Run: `brew list xcodegen >/dev/null || brew install xcodegen; xcodegen generate`
Expected: `AISessionRemote.xcodeproj` created

- [ ] **Step 3: Minimal app that shows empty Hosts list and compiles**

```swift
@main
struct AISessionRemoteApp: App {
    var body: some Scene {
        WindowGroup {
            HostsListView()
        }
        .modelContainer(for: HostEntity.self)
    }
}
```

- [ ] **Step 4: Build**

Run: `xcodebuild -scheme AISessionRemote -destination 'platform=iOS Simulator,name=iPhone 16' build`
Expected: BUILD SUCCEEDED  
(Adjust simulator name to whatever `xcrun simctl list devices available` shows.)

- [ ] **Step 5: Commit**

```bash
git add project.yml App AISessionRemote.xcodeproj README.md Package.swift
git commit -m "feat(app): XcodeGen iOS shell with SwiftData HostEntity"
```

---

### Task 8: Host editor + Keychain wiring + HostRepository

**Files:**
- Create: `App/AISessionRemote/Services/HostRepository.swift`
- Create: `App/AISessionRemote/Views/HostEditorView.swift`
- Modify: `App/AISessionRemote/Views/HostsListView.swift`

**Interfaces:**
- Consumes: `KeychainPrivateKeyStore`, `HostEntity`
- Produces: CRUD for hosts; on save, write PEM to Keychain under `id.uuidString`; on delete, delete Keychain item

Host editor fields: display name, hostname, port, username, PEM paste/import (TextEditor), default paths (newline-separated), optional binary overrides.

- [ ] **Step 1: Implement HostRepository + HostEditorView**

Validation: hostname non-empty, username non-empty, port 1…65535, PEM non-empty on create.

- [ ] **Step 2: Wire HostsListView** — NavigationStack, add button → sheet, swipe to delete, tap → Sessions (placeholder)

- [ ] **Step 3: Manual Simulator check** — add a host, kill app, relaunch, host still listed; Keychain load succeeds for that id

- [ ] **Step 4: Commit**

```bash
git add App/AISessionRemote
git commit -m "feat(app): host editor with Keychain-backed SSH keys"
```

---

### Task 9: NIOSSHClient exec implementation

**Files:**
- Create: `App/AISessionRemote/Services/NIOSSHClient.swift`
- Create: `App/AISessionRemote/Services/ReachabilityProbe.swift`

**Interfaces:**
- Consumes: `SSHExecuting`, `HostConnectionConfig`, `apple/swift-nio-ssh`
- Produces: `struct NIOSSHClient: SSHExecuting` implementing `exec`

Implementation notes:
- Add SPM deps to **app** target via `project.yml`: `https://github.com/apple/swift-nio-ssh.git` (and transitive NIO)
- Open connection, authenticate with private key (parse OpenSSH PEM via SwiftNIO SSH / Swift Crypto helpers — follow swift-nio-ssh client examples)
- Open session channel, send `exec` request with command, collect stdout/stderr until exit
- Map connection failures → `SSHRemoteError.unreachable`; auth failures → `.authenticationFailed`
- Host key verification v1: **accept first use / trust on first use stored in Keychain or UserDefaults hashed host keys** — implement TOFU with `UserDefaults` host→fingerprint map (not ideal long-term; document in README). Do **not** disable verification silently without TOFU.

`ReachabilityProbe`: short `exec` of `true` or TCP connect timeout wrapper; updates `HostEntity.lastReachableAt` on success.

- [ ] **Step 1: Add package deps + stub NIOSSHClient that compiles**

- [ ] **Step 2: Implement exec path against a real Tailscale host (manual)** — run a one-off debug action or unit-style harness printing `whoami`

- [ ] **Step 3: Wire HostsListView pull-to-refresh to probe reachability (green/red dot)

- [ ] **Step 4: Commit**

```bash
git add project.yml App/AISessionRemote/Services
git commit -m "feat(app): SwiftNIO SSH exec client with TOFU host keys"
```

---

### Task 10: Sessions list + New session sheet

**Files:**
- Create: `App/AISessionRemote/Services/SessionServiceFactory.swift` (builds `SessionService` + loads PEM from Keychain into `HostConnectionConfig`)
- Create: `App/AISessionRemote/Views/SessionsListView.swift`
- Create: `App/AISessionRemote/Views/NewSessionSheet.swift`
- Modify: navigation from HostsListView

**Interfaces:**
- Consumes: `SessionService`, `HostEntity`, `RemoteSession`
- UI:
  - Tool-colored rows (claude / codex / cursor)
  - Show slug + cwd if known
  - Collapsed “Other” disclosure for non-`ai/` sessions
  - Errors: alert for `.tmuxMissing` with install hint (`brew install tmux` / `apt install tmux`); `.binaryMissing` names binary; `.authenticationFailed` → link to edit host; `.unreachable` banner

- [ ] **Step 1: Implement SessionsListView with pull-to-refresh calling `listSessions`**

- [ ] **Step 2: Implement NewSessionSheet** — picker for `AITool`, path TextField with bookmark chips from `defaultPaths`, slug field (default last path component), Start button → `createSession` then navigate to Terminal (Task 11 placeholder OK)

- [ ] **Step 3: Manual test on device/simulator+Tailscale** — list existing tmux AI sessions; create one; see it in list

- [ ] **Step 4: Commit**

```bash
git add App/AISessionRemote
git commit -m "feat(app): sessions list and new-session sheet"
```

---

### Task 11: Interactive terminal (SwiftTerm + SSH PTY) + soft keys

**Files:**
- Create: `App/AISessionRemote/Terminal/SSHTerminalSession.swift`
- Create: `App/AISessionRemote/Terminal/TerminalScreen.swift`
- Create: `App/AISessionRemote/Views/SoftKeyBar.swift`
- Modify: `project.yml` — add `https://github.com/migueldeicaza/SwiftTerm.git`

**Interfaces:**
- Consumes: SwiftTerm `TerminalView`, NIO SSH session channel with PTY + shell or exec `tmux attach -t …`
- Produces: `TerminalScreen(hostConfig:attachCommand:title:onKill:)`

Behavior:
- On appear: connect SSH, request PTY (rows/cols from view size), run `tmux attach -t '<name>'` **or** interactive shell then write attach command — prefer **exec** of attach for AI sessions
- On disappear / Back: close SSH channel (tmux session keeps running)
- Menu: Detach (dismiss), Kill session (`SessionService.killSession` then dismiss), Copy (copy SwiftTerm selection / last buffer best-effort)
- `SoftKeyBar`: buttons send bytes `0x03` (Ctrl-C), `\t`, `0x1b` (Esc)

Reference: SwiftTerm iOS sample `UIKitSshTerminalView` + swift-nio-ssh wiring — adapt into UIViewRepresentable.

- [ ] **Step 1: Add SwiftTerm dependency + UIViewRepresentable wrapper compiling with local echo stub**

- [ ] **Step 2: Wire real SSH PTY + attach**

- [ ] **Step 3: Soft keys + disconnect-leaves-tmux manual verification**

- [ ] **Step 4: Commit**

```bash
git add project.yml App/AISessionRemote/Terminal App/AISessionRemote/Views/SoftKeyBar.swift
git commit -m "feat(app): SwiftTerm SSH PTY attach with soft keys"
```

---

### Task 12: Plain SSH escape hatch

**Files:**
- Modify: `App/AISessionRemote/Views/HostsListView.swift` (context menu / toolbar)
- Modify: `App/AISessionRemote/Terminal/TerminalScreen.swift` to accept `mode: attach(SessionName) | plainShell`

**Interfaces:**
- Plain shell: PTY + `ssh` shell request (no command) or `exec` of `$SHELL -l`
- Does not create `ai/…` tmux session

- [ ] **Step 1: Add “Plain SSH” action on host → TerminalScreen plain mode**

- [ ] **Step 2: Manual verify** — shell works even if tmux missing

- [ ] **Step 3: Commit**

```bash
git add App/AISessionRemote
git commit -m "feat(app): plain SSH escape hatch from host menu"
```

---

### Task 13: Error surfaces polish + README host prerequisites

**Files:**
- Modify: relevant Views for consistent alerts/banners
- Modify: `README.md`

**README must include:**
- Host prerequisites (Tailscale, sshd, tmux, `claude` / `codex` / `agent` on PATH)
- How to import an Ed25519/ECDSA OpenSSH private key (SwiftNIO SSH crypto limits — document supported key types; if RSA unsupported, say so explicitly)
- Build: `xcodegen generate && open AISessionRemote.xcodeproj`
- TestFlight / personal team signing notes
- Session naming contract + `~/.ai-remote/` metadata
- Explicit non-goals (push, daemon, App Store)

- [ ] **Step 1: Sweep error UX for all `SSHRemoteError` cases**

- [ ] **Step 2: Write README**

- [ ] **Step 3: Run full `swift test` + `xcodebuild` build**

- [ ] **Step 4: Commit**

```bash
git add App README.md
git commit -m "docs: README and polish remote error surfaces"
```

---

### Task 14: End-to-end manual acceptance checklist

**Files:**
- Create: `docs/superpowers/plans/manual-acceptance.md`

- [ ] **Step 1: Write checklist** matching spec success criteria:

1. Add Tailscale host + key
2. Create Claude session in chosen cwd
3. Create Codex session
4. Create Cursor (`agent`) session
5. Disconnect app; sessions still listed after re-open + refresh
6. Reattach and continue
7. Unrelated tmux session appears only under Other (or hidden)
8. Kill session from menu
9. Plain SSH works
10. Confirm no PEM in SwiftData store / app container plist dumps

- [ ] **Step 2: Run checklist on a physical iPhone over Tailscale**

- [ ] **Step 3: Commit checklist results notes (pass/fail date)**

```bash
git add docs/superpowers/plans/manual-acceptance.md
git commit -m "test: add manual acceptance checklist for v1"
```

---

## Spec coverage (self-review)

| Spec requirement | Task(s) |
|------------------|---------|
| SwiftUI iPhone app | 7–13 |
| Multi-host Tailscale SSH + Keychain | 4, 8, 9 |
| Hosts → Sessions → Terminal | 8, 10, 11 |
| tmux `ai/<tool>/<slug>` | 1, 3, 6 |
| Claude / Codex / Cursor (`agent`) | 1, 6, 10 |
| Pull-only refresh | 9, 10 |
| Metadata `~/.ai-remote/…` | 2, 6 |
| Future agent extension point | 1–3, 6 (contract only) |
| Host entity fields incl. cli overrides | 7, 8 |
| Soft keys Ctrl-C/Tab/Esc | 11 |
| Plain SSH escape | 12 |
| Error table (unreachable, auth, tmux, binary, disconnect) | 6, 9, 10, 13 |
| Duplicate slug suffix | 1, 6 |
| Unit tests naming/metadata | 1–3 |
| No push / no daemon / no App Store | Global constraints + README |
| Success criteria | 14 |

## Placeholder / consistency check

- Tool enum values and default binaries aligned across Tasks 1, 6, 10
- Keychain account = `HostEntity.id.uuidString` = `privateKeyKeychainRef`
- `SSHExecuting` used by `SessionService`; interactive PTY stays in app layer (Tasks 9/11)
- No TBD steps remain
