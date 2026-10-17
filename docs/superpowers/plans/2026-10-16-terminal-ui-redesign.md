# Terminal UI Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Redesign everything around the SwiftTerm terminal: Mac three-column shell, iPhone tabs,
a conversation frame with live status, a key bar, ⌘K, notifications, and in-frame error states.

**Architecture:** Pure, testable logic (status mapping, the board of derived sets, transitions,
resume/install commands, exit-code classification, key bytes, approve gate, palette matching)
goes in `AISessionCore` and is tested with `swift test`. A single app-level `AppModel` owns the
`TodoHubStore` and selection. A `ConversationLoader` state machine drives a `ConversationFrame`
that hosts a `TerminalSurface`, which is extracted unchanged from `TerminalScreen`.
`RootView` picks `MacShell` (macOS, iPad regular width) or `PhoneShell`.

**Tech Stack:** Swift 5.9, SwiftUI (iOS 17 / macOS 14), SwiftTerm, SwiftNIO SSH, XCTest,
XcodeGen, Speech, UserNotifications.

**Spec:** `docs/superpowers/specs/2026-10-16-terminal-ui-redesign-design.md`. Approved mockups:
https://claude.ai/artifact/BsEBQbiHphYgLkKm2FHrc8

## Global Constraints

- Deployment targets are iOS 17.0 and macOS 14.0. Every task must build both the `AISessionRemote`
  (iOS) and `AISessionRemoteMac` schemes.
- `TerminalCoordinator`, `SSHTerminalSession`, `TerminalOutputCoalescer`, `TerminalResizeDebouncer`
  and `SSHConnectionPool` keep their behaviour. Code may be **moved** (with its comments) but not
  rewritten. The only transport change allowed is the additive exit status (Task 2.1).
- Section codes `Sp`, `I`, `Si`, `P` are opaque. Never expand, uppercase or rename them.
- No SSH words (host, key, SSH, tmux, port, `user@host`) on primary screens. They belong only
  under Settings → Access & keys and in the existing host/session views it opens.
- Accent: `#B4532E` light, `#E8916F` dark (the AA-contrast variants of `#D97757` used in the
  mockups). The only other colours are system greys and destructive red. Tool colours are not
  used on new screens.
- Status words are exactly `Working`, `Needs you`, `Idle`, `Closed`.
- Terminal font is SF Mono (`monospacedSystemFont`). Default 13pt on macOS, 11pt on iOS, range
  9–24, stored in `@AppStorage("terminal.fontSize")`. Theme defaults to System, stored in
  `@AppStorage("terminal.theme")` as `system|light|dark`.
- Fixtures, the demo transport and `-uiDemo` exist only under `#if DEBUG`.
- Reuse `MacCompatibility.swift` / `PlatformSupport`. Add shims there rather than scattering `#if`.
- New UI goes in new files. Existing files get only hand-off edits. `TodosView.swift` is deleted
  in Task 5.3, once everything it did is reachable elsewhere.
- Every PR ends with `verify.sh all` green (see Tooling), plus iPhone 17 Pro Simulator and Mac
  screenshots in light and dark, attached to the PR and compared with the mockups.

## Review Focus

1. **Arrowing through the Mac list.** Selection must never create or resume a conversation, and
   must not attach more than once per 150 ms of settling. Pinned by `ConversationLoaderTests.testSelectionDoesNotStartConversation` (Task 2.2) and the debounce test in Task 5.2.
2. **A conversation already waiting at launch, or in the first refresh after reconnect.** It must
   not notify. Pinned by `StatusTransitionsTests.testFirstSnapshotNeverNotifies` (Task 1.1).
3. **Folders with `~`, spaces or quotes in the resume command.** `~` must still expand, and the
   rest must be quoted. Pinned by `ResumeCommandTests` (Task 1.1).
4. **Approve after the user already answered from the keyboard.** It must stay disabled until a
   *new* `waiting` arrives. Pinned by `ApproveGateTests.testTypingDisarmsUntilNextWaiting` (Task 1.1).
5. **Offline hub while opening a cached, not-closed conversation.** It must still attach, as it
   does today. Pinned by `ConversationLoaderTests.testOfflineUsesCachedConversation` (Task 2.2).

## Tooling

- `~/.claude/jobs/10780aa8/tmp/verify.sh [ios|mac|spm|all]` runs `xcodegen generate`, then the
  iOS `test` on iPhone 17 Pro, the Mac `build`, and `swift test`. It prints each exit code. Exit
  0 means green.
- Screenshots:
  - iOS: `xcrun simctl launch booted com.aisessionremote.app -uiDemo [-uiDemoScreen <name>]`,
    then `xcrun simctl io booted screenshot <file>`. Switch appearance with
    `xcrun simctl ui booted appearance light|dark`.
  - Mac: launch the built app with `-uiDemo`, then `screencapture -o -l <windowID> <file>`. Get
    the window ID from a small `CGWindowListCopyWindowInfo` Swift script in the job tmp folder.
- New Swift files under `App/AISessionRemote` and `Sources/AISessionCore` are picked up by
  XcodeGen / SwiftPM automatically. Commit the regenerated `AISessionRemote.xcodeproj`.

## Branches and PRs

There is one stacked branch per PR, each based on the previous one:
`ui/01-foundations` (based on `docs/terminal-ui-redesign-design`), `ui/02-frame`,
`ui/03-phone-shell`, `ui/04-key-bar`, `ui/05-mac-shell`, `ui/06-status`, `ui/07-fast-paths`.
Push each one and open a GitHub PR against the previous branch, with the screenshots in the
body. Never push to `main`.

---

## PR 1: Foundations

### Task 1.1: Core logic for status, board, transitions, commands, keys

**Files:**
- Create: `Sources/AISessionCore/Board/ConversationDisplayStatus.swift`, `ConversationBoard.swift`, `StatusTransitions.swift`, `ResumeCommand.swift`, `OpenFailure.swift`, `TerminalKeys.swift`, `PaletteMatcher.swift`
- Test: `Tests/AISessionCoreTests/BoardTests.swift`, `CommandsTests.swift`, `TerminalKeysTests.swift`, `PaletteMatcherTests.swift`

**Interfaces (Produces):**
```swift
public enum ConversationDisplayStatus: Equatable, Sendable { case working, needsYou, idle, closed
  public init(_ status: ConversationStatus, tmuxAlive: Bool?)   // tmuxAlive == false → .closed
  public var label: String }                                     // "Working" "Needs you" "Idle" "Closed"
public struct ConversationBoard: Sendable {
  public init(todos: [Todo], conversations: [String: Conversation], liveTmux: [String: Set<String>]) // computerID → tmux names; computer absent = unknown
  public func status(forTodo id: String) -> ConversationDisplayStatus?
  public var needsYou: [Conversation]        // display == .needsYou, same order as runningNow
  public var runningNow: [Conversation]      // display != .closed; createdAt desc, then todoId asc
  public func conversation(atShortcut n: Int) -> Conversation?   // 1-based into runningNow, nil past 9
  public func openTodoCount(_ section: TodoSection) -> Int       // !completed
  public func sectionNeedsYou(_ section: TodoSection) -> Bool
  public func runningCount(computerID: String) -> Int }
public enum StatusTransitions {
  public static func newlyWaiting(previous: [String: ConversationStatus]?, current: [Conversation]) -> [Conversation] }
public enum ResumeCommand {
  public static func string(for c: Conversation) -> String
  public static func install(hubURL: String) -> String }
public enum OpenFailure: Equatable, Sendable { case helpersMissing, toolMissing, folderMissing, conversationNotFound
  public init?(exitStatus: Int?) }                               // 127, 90, 93, 94; else nil
public enum TerminalKey: CaseIterable, Sendable { case esc, tab, left, up, down, right, shiftEnter, approve
  public func bytes(tool: String) -> [UInt8] }
public struct ApproveGate: Sendable { public init()
  public mutating func statusChanged(to: ConversationStatus)
  public mutating func userTyped()
  public func isEnabled(tool: String) -> Bool }                  // codex: always true
public enum PaletteMatcher { public static func score(query: String, candidate: String) -> Int? }
```

- [ ] **Step 1: Write the failing tests.** These are the exact cases:
  - `ConversationDisplayStatus`:
    - busy→working, waiting→needsYou, idle→idle, unknown→idle, closed→closed.
    - Any status with `tmuxAlive: false` gives closed. `tmuxAlive: nil` keeps the hub status.
  - `ConversationBoard`:
    - `runningNow` excludes closed conversations and conversations whose tmux is absent from a
      computer present in `liveTmux`.
    - Order is `createdAt` descending, with ties broken by `todoId` ascending.
    - `conversation(atShortcut: 1)` is the first entry and `(atShortcut: 10)` is nil.
    - `openTodoCount` ignores completed todos. `sectionNeedsYou` is true only with a `waiting`
      conversation in that section.
  - `StatusTransitionsTests.testFirstSnapshotNeverNotifies`: a `previous` of nil returns `[]`.
  - `StatusTransitions`: idle→waiting returns that conversation; waiting→waiting returns `[]`; a
    new conversation that is already waiting returns it (when `previous` is not nil).
  - `ResumeCommandTests`:
    - Claude `cwd "~/code/my app"` → `cd ~/'code/my app' && claude --resume <id>`.
    - Codex `cwd "/srv/x"` → `cd '/srv/x' && codex resume <id>`.
    - A single quote in a folder is escaped as `'\''`.
    - `install(hubURL: "http://h:8080")` → `scripts/todo/install.sh --hub-url 'http://h:8080' --token "$TODO_API_TOKEN"`.
  - `OpenFailure(exitStatus:)`: 127/90/93/94 map to the four cases; `nil`, `0` and `1` give nil.
  - `TerminalKey.bytes`:
    - esc `[0x1B]`, tab `[0x09]`.
    - Arrows `ESC [ D/A/B/C`.
    - shiftEnter: claude `[0x1B, 0x0D]`, codex `[0x0A]`.
    - approve: claude `[0x31]`, codex `[0x79]`.
  - `ApproveGateTests.testTypingDisarmsUntilNextWaiting`:
    - `statusChanged(.waiting)` → enabled.
    - `userTyped()` → disabled.
    - `statusChanged(.waiting)` again with no change in between stays disabled.
    - `statusChanged(.busy)` then `(.waiting)` → enabled.
    - Codex is always enabled.
  - `PaletteMatcher`:
    - `"sante"` matches `"Santé party-size rates"` (case- and diacritic-insensitive subsequence).
    - `"zzz"` → nil.
    - A prefix match scores higher than a scattered match.
- [ ] **Step 2:** `swift test --filter "BoardTests|CommandsTests|TerminalKeysTests|PaletteMatcherTests"`, expecting compile failures.
- [ ] **Step 3: Implement the files listed above.** Each is a pure value type with no Foundation
  networking. Parse `createdAt` as an ISO-8601 string compare (the hub sends sortable UTC).
- [ ] **Step 4:** Run the same filter. PASS expected. Then `verify.sh spm` → 0.
- [ ] **Step 5:** Commit `feat(core): board, status, transitions, commands, keys for the UI redesign`.

### Task 1.2: Design tokens, StatusBadge, terminal appearance

**Files:**
- Create: `App/AISessionRemote/Theme/DesignSystem.swift`, `App/AISessionRemote/Theme/TerminalAppearance.swift`, `App/AISessionRemote/Views/Components/StatusBadge.swift`
- Modify: `App/AISessionRemote/Platform/PlatformSupport.swift` (add `PlatformColor.dynamic(light:dark:) -> Color`)
- Modify: `App/AISessionRemote/Terminal/TerminalScreen.swift`: in the `make*View` functions only, call `TerminalAppearance.apply(to:)` instead of hard-coded black/white
- Test: `App/AISessionRemoteTests/TerminalAppearanceTests.swift`

**Interfaces (Produces):**
```swift
enum DS { static let accent: Color; static let spacing: (xs: CGFloat, s: CGFloat, m: CGFloat, l: CGFloat, xl: CGFloat) // 4 8 12 16 24
          static let rowMinHeight: CGFloat /* 52 */ }
enum TerminalTheme: String, CaseIterable { case system, light, dark }
struct TerminalPalette { let background, foreground, cursor, selection: PlatformNativeColor; let ansi: [PlatformNativeColor] /* 16 */
  static let light: TerminalPalette; static let dark: TerminalPalette }
enum TerminalAppearance {
  static let fontSizeRange: ClosedRange<Double> = 9...24
  static var defaultFontSize: Double                          // 13 macOS, 11 iOS
  static func clamped(_ size: Double) -> Double
  static func stepped(_ size: Double, by delta: Int) -> Double   // ±1pt, clamped
  static func palette(theme: TerminalTheme, colorScheme: ColorScheme) -> TerminalPalette
  static func apply(to view: TerminalView, palette: TerminalPalette, fontSize: Double) }
struct StatusBadge: View { init(_ status: ConversationDisplayStatus, style: Style = .pill); enum Style { case pill, dot } }
```

- [ ] **Step 1: Failing tests.**
  - `clamped(4) == 9` and `clamped(30) == 24`.
  - `stepped(24, by: 1) == 24`.
  - `palette(theme: .system, colorScheme: .dark)` is `.dark`. `palette(theme: .light, colorScheme: .dark)` is `.light`.
  - `TerminalPalette.dark.ansi.count == 16`.
- [ ] **Step 2:** `verify.sh ios`, expecting the tests to fail.
- [ ] **Step 3: Implement.**
  - Background/foreground: light `#FBFAF7`/`#1F1E1C`, dark `#1A1A19`/`#E9E7E2`. Pick the ANSI
    colours so Claude's diff red and green stay legible on both.
  - `apply` sets `nativeBackgroundColor`, `nativeForegroundColor`, `installColors`, the font via
    `monospacedSystemFont(ofSize:weight:.regular)`, and the layer background on iOS.
  - The iOS layer-background comment in `makeUIView` moves with the code.
  - `StatusBadge` follows the spec's status table:
    - Working is three dots animated with `.repeatForever`, static when
      `accessibilityReduceMotion` is on.
    - Needs you is a `DS.accent` capsule with white text (light) or `#1C1C1E` text (dark).
    - Idle is a hollow dot.
    - Closed is text only.
- [ ] **Step 4:** `verify.sh all` → 0.
- [ ] **Step 5:** Commit `feat(ui): design tokens, status badge, terminal theme and SF Mono`.

### Task 1.3: Text size shortcuts and debug demo mode

**Files:**
- Create: `App/AISessionRemote/Debug/DemoFixtures.swift`, `App/AISessionRemote/Debug/DemoTransport.swift` (both entirely inside `#if DEBUG`)
- Modify: `App/AISessionRemote/Terminal/TerminalScreen.swift`: `TerminalCoordinator.init` gains `makeTransport: @escaping (HostConnectionConfig, TerminalMode) -> any TerminalTransport = { SSHTerminalSession(config: $0, mode: $1) }`, and `connect()` uses it. This is the only change in `connect()`.
- Modify: `App/AISessionRemote/AISessionRemoteApp.swift`: a `CommandMenu("Conversation")` with Bigger ⌘+, Smaller ⌘−, Default ⌘0 bound to `@AppStorage("terminal.fontSize")`

**Interfaces (Produces):**
```swift
#if DEBUG
enum DemoFixtures { static var isEnabled: Bool /* -uiDemo */; static let todos: [Todo]; static let conversations: [Conversation]
                    static let computers: [Computer]; static let sectionComputers: [SectionComputer]; static let config: HostConnectionConfig }
final class DemoTransport: TerminalTransport   // on connect, feeds a canned ANSI Claude permission prompt (mockup text)
#endif
```

- [ ] **Step 1:** Implement both files. Use the mockup content: the 5 Running-now conversations
  and the `Sp`/`I`/`Si`/`P` todos.
- [ ] **Step 2:** `verify.sh all` → 0. Grep the release-config build for `DemoFixtures`. Run
  `xcodebuild -scheme AISessionRemoteMac -configuration Release build` and confirm with
  `nm` on the binary that there is no `DemoFixtures` symbol.
- [ ] **Step 3:** Take the PR 1 screenshots: the existing Todos and the terminal in demo mode,
  light and dark. The terminal should follow the system and use SF Mono, and ⌘+ should
  enlarge it.
- [ ] **Step 4:** Commit. Push `ui/01-foundations` and open PR 1.

## PR 2: Conversation frame

### Task 2.1: Exit status reaches the terminal

**Files:**
- Modify: `App/AISessionRemote/Services/SSH/PooledConnecting.swift`, `SSHConnectionPool.swift`, `PooledSSHConnection.swift`: `onClose: @escaping (Int?) -> Void`, with `onExit: { onClose($0) }`
- Modify: `TerminalTransport.swift`: `var onDisconnect: ((Int?) -> Void)?`. `SSHTerminalSession.swift` forwards it.
- Modify: `TerminalScreen.swift`: `TerminalCoordinator.onDisconnected: ((Int?) -> Void)?`
- Test: `App/AISessionRemoteTests/SSHConnectionPoolTests.swift`: update the fake to `(Int?) -> Void`, and add `testPTYCloseForwardsExitStatus`, where the fake closes with 127 and the caller's `onClose` receives 127

- [ ] **Step 1:** Write the failing test, then run `verify.sh ios` to confirm it fails.
- [ ] **Step 2:** Change the signatures. Touch nothing else in the pool.
- [ ] **Step 3:** `verify.sh all` → 0. Commit `feat(ssh): pass the PTY's exit status to onDisconnect`.

### Task 2.2: ConversationLoader

**Files:**
- Create: `App/AISessionRemote/Views/Frame/ConversationLoader.swift`
- Test: `App/AISessionRemoteTests/ConversationLoaderTests.swift`

**Interfaces:**
- Consumes: `OpenFailure`, `HostLookup`, `TodoHubStore.openConversation(for:)`, `TodoHubError.conflict`.
- Produces:
```swift
@MainActor @Observable final class ConversationLoader {
  enum Phase: Equatable { case idle /* not started: show Start/Resume */, preparing, ready(OpenTodoConversation), problem(FrameProblem) }
  struct Dependencies { var openConversation: (Todo) async throws -> Conversation
                        var cachedConversation: (String) -> Conversation?; var isOffline: () -> Bool
                        var resolveConfig: (Computer) throws -> (hostID: UUID, config: HostConnectionConfig) } // throws HostLookup.Failure
  init(todo: Todo, dependencies: Dependencies)
  private(set) var phase: Phase
  func start() async            // explicit: hub get-or-create (or cache when offline), then resolve
  func attachIfRunning(_ c: Conversation?) async   // selection path: only if c.status != .closed, never calls openConversation
  func ended(exitStatus: Int?)  // OpenFailure → .problem, else stays .ready (the terminal shows Disconnected)
}
enum FrameProblem: Equatable { case noComputer(TodoSection), needsAccess(Computer), keyMissing(String),
  unreachable(String), helpersMissing(String), toolMissing(String), folderMissing(String, String),
  conversationNotFound(String), hub(String) }
```
`OpenTodoConversation` moves out of `TodosView.swift` into this file, unchanged.

- [ ] **Step 1: Failing tests.**
  - `testStartSuccessIsReady`.
  - `testNoComputerConflictMapsToNoComputer`: `conflict("no computer for section Sp")` gives `.noComputer(.sp)`.
  - `testMissingHostIsNeedsAccess`.
  - `testKeyUnavailableIsKeyMissing`.
  - `testOfflineUsesCachedConversation`: offline with a cached not-closed conversation means
    `openConversation` is never called and the phase is `.ready`.
  - `testSelectionDoesNotStartConversation`: `attachIfRunning(nil)` and `attachIfRunning(closed)`
    leave `.idle` and make no calls.
  - `testExit127IsHelpersMissing`.
  - `testExitNilStaysReady`.
- [ ] **Step 2:** `verify.sh ios`, expecting the tests to fail.
- [ ] **Step 3: Implement.** The logic is today's `TodosView.open(_:)`. The section for
  `noComputer` comes from `todo.section`.
- [ ] **Step 4:** `verify.sh all` → 0. Commit.

### Task 2.3: TerminalSurface, ConversationFrame and FrameStateView

**Files:**
- Create: `App/AISessionRemote/Views/Frame/TerminalSurface.swift`. It holds `TerminalContainerView`, the coordinator wiring, the 250 ms connecting gate and the disconnected state, all moved verbatim from `TerminalScreen`. The overlays are restyled to sit on the terminal background with no black scrim.
- Create: `Views/Frame/ConversationFrame.swift`, `Views/Frame/FrameStateView.swift`, `Views/Frame/ConversationActions.swift`
- Modify: `TerminalScreen.swift` becomes `TerminalSurface` plus its existing toolbar and alerts, so behaviour is unchanged for the host/session screens.

**Interfaces (Produces):**
```swift
struct TerminalSurface: View { init(config: HostConnectionConfig, mode: TerminalMode, focusOnConnect: Bool = true,
                                    onEnded: @escaping (Int?) -> Void = { _ in }, onUserInput: @escaping () -> Void = {}) }
struct ConversationFrame: View { init(todo: Todo, loader: ConversationLoader, store: TodoHubStore, onDeleted: @escaping () -> Void) }
struct FrameStateView: View { init(problem: FrameProblem, actions: FrameActions) }  // one primary button per spec §6
struct FrameActions { var openSettings: (SettingsDestination) -> Void; var setUpAccess: (Computer) -> Void
                      var retry: () -> Void; var copy: (String) -> Void; var unlink: () -> Void }
enum SettingsDestination: Hashable { case server, sections(TodoSection?), access, terminal, notifications }
```

- [ ] **Step 1: Implement the frame.**
  - On macOS the header uses `.navigationTitle(todo.title)`, `.navigationSubtitle(meta)` and
    toolbar items. On iOS it uses a `principal` two-line title and the trailing pill plus ⋯.
  - `meta` is `"\(section) · \(computer) · \(folder) · \(tool)"`. On iOS the folder is omitted.
  - ⋯ contains: Close Conversation (`store.closeConversation`), Delete Conversation… (today's
    dialog text), Reconnect, Copy Screen, Paste, and Text Size ▸.
  - ⎘ copies `ResumeCommand.string` and shows a "Copied" toast for 1.5 s.
  - The phases are drawn in the terminal area:
    - `.idle`: "No conversation yet" or "Resume", with a primary **Start Conversation ⏎** button
      bound to `.keyboardShortcut(.defaultAction)`.
    - `.preparing`: "Starting conversation on <computer>…".
    - `.ready`: `TerminalSurface`.
    - `.problem`: `FrameStateView`.
  - The copy for each state is the spec's §6 table, verbatim.
- [ ] **Step 2:** Wire it into the current `TodosView.conversationDestination`, so it is
  reachable before the new shells exist.
- [ ] **Step 3:** `verify.sh all` → 0. Screenshot the frame with `-uiDemo` in every phase. Use
  the debug argument `-uiDemoProblem <case>` to force each problem, and compare with the
  MacStates board. Commit, push `ui/02-frame` and open PR 2.

## PR 3: iPhone shell

### Task 3.1: AppModel and the move to app level

**Files:**
- Create: `App/AISessionRemote/Services/AppModel.swift`
- Modify: `AISessionRemoteApp.swift` creates `@State var model = AppModel()` and passes it via `.environment(model)`. `TodosView` reads the store from the model instead of `@State`.
- Test: `App/AISessionRemoteTests/AppModelTests.swift`

**Interfaces (Produces):**
```swift
@MainActor @Observable final class AppModel {
  let store: TodoHubStore
  private(set) var liveTmux: [String: Set<String>]           // computerID → tmux names
  var board: ConversationBoard { get }                        // from store.todos / store.conversations / liveTmux
  enum SidebarItem: Hashable { case needsYou, runningNow, section(TodoSection), computer(String) }
  var sidebarSelection: SidebarItem? ; var selectedTodoID: String?
  var poppedOut: Set<String>
  var pendingOpenTodoID: String?                              // set by notification taps / palette
  func refreshLiveness(hosts: [HostEntity]) async             // one SessionService.listSessions per reachable computer; failures leave the computer absent
  init(store: TodoHubStore = TodoHubStore(), demo: Bool = DemoFixtures.isEnabled /* DEBUG only */) }
```

- [ ] **Step 1: Failing tests.**
  - `board` reflects store changes.
  - `refreshLiveness` with a computer whose listing throws leaves it absent, so its hub status
    is kept.
  - Inject the listing with a closure `listTmux: (Computer) async throws -> Set<String>`.
- [ ] **Step 2:** Implement, then run `verify.sh all` → 0 and commit.

### Task 3.2: Lists and rows

**Files:**
- Create in `App/AISessionRemote/Views/Lists/`: `TodoRow.swift`, `ConversationRow.swift`, `TodoListView.swift`, `ConversationListView.swift`, `ComputerListView.swift`, `ComputerDetailView.swift`, `AddTodoSheet.swift` (moved from TodosView, now `internal`)

**Interfaces (Produces):**
```swift
struct TodoListView: View { init(sections: [TodoSection], onOpen: (Todo) -> Void) }         // inset-grouped, swipe/context actions
struct ConversationListView: View { enum Filter { case needsYou, running, all }; init(filter: Binding<Filter>, onOpen: (Todo) -> Void) }
struct ComputerListView: View { init(onOpen: (Computer) -> Void) }
struct ComputerDetailView: View { init(computer: Computer) } // running conversations, Other sessions (SessionsListView content), On this computer (RemoteConversationPicker), Open Shell
```

- [ ] **Step 1: Implement the lists to the mockups.**
  - Row swipe actions:
    - Todo leading: Done/Undo, full swipe.
    - Todo trailing: Delete; Close when a conversation is running; Link… when there is none.
    - Conversation trailing: Close, Delete….
    - Conversation leading: Copy resume command.
  - Section headers show the code plus the computer name.
  - Empty states use the spec's §6 copy.
  - Computers that need access show **Set Up**, which opens `HostEditorView(prefill:)`.
  - "Other computers" lists `HostEntity`s that match no hub computer.
- [ ] **Step 2:** `verify.sh all` → 0. Commit.

### Task 3.3: PhoneShell, Settings and quick-add with dictation

**Files:**
- Create: `Views/Shell/PhoneShell.swift`, `Views/Shell/SettingsView.swift`, `Views/Lists/QuickAddBar.swift`, `Services/Dictation.swift`
- Modify: `RootView.swift` (iOS compact → `PhoneShell`; others → `TodosView` until PR 5), `project.yml` (iOS Info.plist: `NSMicrophoneUsageDescription` "Dictate new todos.", `NSSpeechRecognitionUsageDescription` "Turns your dictation into todo text."; `UIApplicationShortcutItems` "New Todo" type `com.aisessionremote.newTodo`)

**Interfaces (Produces):**
```swift
@MainActor @Observable final class Dictation { var transcript: String; var isRunning: Bool
  func start() async throws; func stop() }        // SFSpeechRecognizer, requiresOnDeviceRecognition when supportsOnDeviceRecognition
struct SettingsView: View { init(initial: SettingsDestination? = nil) }
```

- [ ] **Step 1: Implement.**
  - `PhoneShell` is a `TabView` with Todos, Conversations (`.badge(board.needsYou.count)`) and
    Computers.
  - Each tab is a `NavigationStack` with a large title and a ⚙ button that opens
    `SettingsView`.
  - Opening a todo pushes `ConversationFrame` with `.toolbar(.hidden, for: .tabBar)`.
  - Settings rows: Todo server (`TodoHubSettingsView`), Sections & computers (`ComputersView`),
    Access & keys (`HostsListView`), Terminal (text size stepper, theme picker, and the note
    "Set Claude's theme with /theme to match."), Notifications (a toggle stored in
    `@AppStorage("notify.needsYou")`).
  - The quick-add section chip defaults to `@AppStorage("quickAdd.section")`.
  - The `com.aisessionremote.newTodo` Home-screen action (handled through a `UIApplicationDelegateAdaptor` scene
    delegate) selects the Todos tab and focuses the quick-add field.
- [ ] **Step 2:** `verify.sh all` → 0. Take Simulator screenshots of the three tabs in light
  and dark, and compare them with the PhoneTodos/Conversations/Computers boards. Commit, push
  `ui/03-phone-shell` and open PR 3.

## PR 4: iPhone key bar and haptics

### Task 4.1: KeyBar

**Files:**
- Create: `App/AISessionRemote/Views/Frame/KeyBar.swift` (iOS only; add it to the Mac target `excludes` in `project.yml`, like `SoftKeyBar.swift`)
- Modify: `TerminalSurface.swift` (iOS): set `view.inputAccessoryView` to an empty `UIView` and add the bar with `.safeAreaInset(edge: .bottom)`. Remove `SoftKeyBar` usage, and delete `SoftKeyBar.swift` along with its `excludes` entry.
- Modify: `PlatformSupport.swift`: add `keyTapFeedback()` (light), `approveFeedback()` (rigid), `needsYouFeedback()` (warning)

**Interfaces:**
- Consumes: `TerminalKey.bytes(tool:)` and `ApproveGate`.
- Produces: `struct KeyBar: View { init(tool: String, approveEnabled: Bool, ctrlArmed: Binding<Bool>, keyboardVisible: Bool, send: ([UInt8]) -> Void, toggleKeyboard: () -> Void, paste: () -> Void) }`

- [ ] **Step 1: Implement.**
  - Keys: esc, tab, ctrl, ←, ↑, ↓, →, ⇧⏎, ⌨. ⌨ toggles the keyboard, and a long press pastes.
  - Approve is pinned on the right.
  - Ctrl sets SwiftTerm's `terminalView.controlModifier = true` and highlights until the next
    key.
  - Arrows auto-repeat at 0.4 s, then every 0.08 s.
  - Every key calls `keyTapFeedback`.
  - Approve is accent-filled when enabled; the gate's `userTyped()` hooks into
    `TerminalSurface.onUserInput`.
- [ ] **Step 2:** `verify.sh all` → 0. Take Simulator screenshots with the keyboard up and
  down, light and dark, and compare with the PhoneTerminal boards. Commit, push
  `ui/04-key-bar` and open PR 4.

## PR 5: Mac shell

### Task 5.1: Sidebar and three columns

**Files:**
- Create: `Views/Shell/MacShell.swift`, `Views/Shell/SidebarView.swift`
- Modify: `RootView.swift` (macOS, and iOS with regular `horizontalSizeClass` → `MacShell`)

- [ ] **Step 1: Implement to the Main board.**
  - `NavigationSplitView` with sidebar, content and detail. The sidebar uses `.listStyle(.sidebar)`.
  - Rows: Needs you and Running now with counts, Todos `Sp/I/Si/P` with
    `openTodoCount` and an accent dot from `sectionNeedsYou`, then Computers with `runningCount`.
  - Footer: "Synced · just now", "Offline · showing todos from <ago>", or "The server didn't
    accept the API token", plus Settings (⌘, opens a `Settings` scene with `SettingsView` on
    macOS).
  - The content column switches on `sidebarSelection` and uses the lists from PR 3, with
    `.searchable`.
  - The detail column is a `ConversationFrame` or "Select a conversation" with the
    "⌘K to jump · ⌘N new todo" hint.
- [ ] **Step 2:** `verify.sh all` → 0. Commit.

### Task 5.2: Selection rules and pop-out

**Files:**
- Modify: `MacShell.swift`, `AISessionRemoteApp.swift` (add `WindowGroup(id: "conversation", for: String.self)`)
- Test: `App/AISessionRemoteTests/SelectionDebounceTests.swift`

- [ ] **Step 1: Failing test.** `SelectionAttacher` (in `MacShell.swift`, injectable
  scheduler like `TerminalResizeDebouncer`): three selections within 150 ms attach once, to
  the last one.
- [ ] **Step 2: Implement.**
  - Selecting a running conversation goes through `attachIfRunning` after 150 ms.
  - ⏎ or a double-click calls `start()`.
  - ⇧⌘O and the header button open a window keyed by todo ID and add it to `poppedOut`. The
    main detail then shows "Open in its own window" with **Show Window** / **Bring Back**,
    and closing the window removes it from `poppedOut`.
  - "New Session" moves to ⌥⌘N in `SessionsListView`.
- [ ] **Step 3:** `verify.sh all` → 0. Commit.

### Task 5.3: Remove TodosView

- [ ] **Step 1:** Delete `Views/Todos/TodosView.swift`. Everything it did is now in the shells,
  `ConversationLoader`, `AddTodoSheet` and the lists. Before deleting, check every
  `.sheet`/`.alert` it had against the new code: settings, computers, add, host prefill, link,
  new-from-conversation, delete dialog, missing host, and the error alert.
- [ ] **Step 2:** `verify.sh all` → 0. Take Mac screenshots in light and dark (Running now
  selected, plus the frame) and compare with the Main/MacDark boards. Take an iPad
  regular-width screenshot too. Commit, push `ui/05-mac-shell` and open PR 5.

## PR 6: Status everywhere

### Task 6.1: Notifications, haptics and focus on waiting

**Files:**
- Create: `App/AISessionRemote/Services/NotificationRouter.swift` (`UNUserNotificationCenterDelegate`: `willPresent` → banner; `didReceive` → `model.pendingOpenTodoID = userInfo["todoId"]`)
- Modify: `AttentionNotifier.swift`: add `static func notifyNeedsYou(_ c: Conversation, todoTitle: String)`, with identifier `needs-you-<todoId>`, title = todo title, and body = `statusMessage ?? "Needs you on <computer>"`
- Modify: `AppModel.swift`: on each store refresh, run `StatusTransitions.newlyWaiting(previous:current:)`.
  - Skip the conversation when it is frontmost and the app is active (`scenePhase == .active`
    and `selectedTodoID` matches). Then only call `needsYouFeedback()`.
  - Respect `notify.needsYou`.
  - `previous` is nil after launch and after every reconnect.
- Modify: `ConversationFrame.swift`: when the phase becomes `.ready` and the status is
  `waiting`, call `focusTerminal()`. On macOS this also runs after selection moves focus to
  the terminal.
- Test: `App/AISessionRemoteTests/AppModelTests.swift`: `testNotifiesOnlyOnTransition` and `testSuppressedWhenFrontmost`, with an injected `notify` closure

- [ ] **Step 1:** Write the failing tests, then run `verify.sh ios` to confirm they fail.
- [ ] **Step 2:** Implement. Install the router in `AISessionRemoteApp.init`. Handle
  `pendingOpenTodoID` in both shells: the iPhone switches to Conversations and pushes; the Mac
  selects the conversation.
- [ ] **Step 3:** `verify.sh all` → 0. Commit, push `ui/06-status` and open PR 6, with a
  screenshot of a demo-triggered notification.

## PR 7: Fast paths

### Task 7.1: ⌘K palette, ⌘1–9 and ⌘N

**Files:**
- Create: `App/AISessionRemote/Views/Palette/CommandPalette.swift`
- Modify: `AISessionRemoteApp.swift` `CommandMenu("Conversation")`: ⌘K palette, ⌘1–⌘9 → `board.conversation(atShortcut:)` then `start()`, ⌘N → `AddTodoSheet` prefilled with the selected section, and ⇧⌘O pop-out. `CommandGroup(replacing: .newItem) {}` stays.

**Interfaces:**
- Consumes: `PaletteMatcher.score` and `ConversationBoard`.
- Produces: `struct CommandPalette: View { init(isPresented: Binding<Bool>) }` (an overlay on `MacShell`).

- [ ] **Step 1: Implement to the MacPalette board.**
  - Groups: Conversations (Needs you first, with ⌘n hints), Todos, Actions (New todo, Link a
    conversation to "<selected>"…, New todo from a conversation…, Open Settings).
  - ↑/↓, ⏎, ⌘⏎ (new window) and esc are handled through `.onKeyPress` on the focused field.
    There is no global key monitor.
  - Results are ranked by `PaletteMatcher.score` and capped at 5 per group.
- [ ] **Step 2:** `verify.sh all` → 0. Take a Mac screenshot with the palette open and query
  "rate", and compare with the board. Commit, push `ui/07-fast-paths` and open PR 7.
