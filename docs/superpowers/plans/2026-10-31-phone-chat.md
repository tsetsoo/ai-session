# iPhone Chat Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the iPhone's chat read like the Claude app, copy exactly, show what the agent is doing, and answer every prompt without opening the terminal.

**Architecture:** The host script `ai-todo-transcript` gains an opt-in `--activity` JSON mode with tool steps, timestamps and stable ids. Pure logic (decoding, timeline grouping, markdown blocks, scroll following, terminal-prompt parsing) lives in `AISessionCore`, where `swift test` covers it. The app's `PhoneConversationView` is rebuilt from small SwiftUI views on top of that logic. Prompts are read from the live SwiftTerm buffer the phone already holds, and answered by sending arrow keys and Enter after checking the prompt hasn't changed.

**Tech Stack:** Swift 5.9, SwiftUI/UIKit (iOS 17 floor, iOS 18 scroll APIs behind `#available`), SwiftTerm, Python 3 (host script), XCTest, unittest.

**Spec:** `docs/superpowers/specs/2026-10-31-phone-chat-design.md`

**Workspace:** Other sessions use `programming/ai-session`. Do the work on branch `feat/phone-chat` in a separate worktree (memory: shared checkout). All paths below are relative to `ai-session-remote/` unless they start with `docs/`.

## Global Constraints

- iOS deployment target stays `17.0`. iOS 18 APIs go behind `if #available(iOS 18, *)`, with the current behavior as the iOS 17 fallback.
- No new package dependencies.
- iPhone only. Wrap new app views in `#if os(iOS)`, as `PhoneConversationView.swift` does. The Mac target must still build.
- Copy is byte-identical. "Copy" gives the message's `text` unchanged, and a code block's Copy gives the code between the fences unchanged (indentation, blank lines and trailing spaces kept).
- Never send a key to a prompt other than the one the card shows.
- Keep the old JSON working. Without `--activity`, `ai-todo-transcript --json` returns only user/assistant messages, as it does today. The app falls back to that mode when a computer's helper is too old (exit 64).
- Values: fold a reply longer than 30 lines or 2,000 characters, and show its first 20 lines. Show a timestamp before the first entry and after a gap of 30 minutes or more. Poll every 1 s while the status is `busy` or `waiting`, and every 3 s otherwise. Truncate an activity target to its first line and 120 characters. The quick replies are `continue`, `yes`, `run the tests`, `/compact`.
- Layout follows mockup A: `.superpowers/brainstorm/82933-1793456809/content/chat-layout.html` at the repo root (gitignored, local only).

## Review Focus

1. **A numbered list in the agent's reply ("1. …  2. …") is mistaken for a prompt.** No card should appear. The test is in Task 6.
2. **The prompt changes between showing the card and tapping a button.** Nothing is sent, and the card refreshes. The test is in Task 7.
3. **A computer still has the old helper.** The chat loads without activity rows instead of showing "Couldn't load chat". The test is in Task 2.
4. **The user is scrolled up reading when new text arrives.** The view doesn't move, and ↓ appears. The test is in Task 5.
5. **Odd transcript lines:** a truncated last line, `tool_use` with no input, a multi-line or 5 KB Bash command. The script still prints valid JSON with short targets. The test is in Task 1.

---

### Task 1: Transcript script emits activity, timestamps and stable ids

**Files:**
- Modify: `scripts/todo/ai-todo-transcript`
- Test: `scripts/todo/test-transcript.py`

**Interfaces:**
- Produces: `ai-todo-transcript <tool> <id> --json --activity` prints a JSON array of entries in file order:
  `{"id": str, "role": "user"|"assistant"|"activity", "text": str, "time"?: ISO-8601 str, "kind"?: "read"|"edit"|"run"|"search"|"other", "target"?: str, "name"?: str}`.
  Activity entries have `text: ""`, plus `kind`, `target` and `name` (the tool's name).
  `id` is `"<line>.<part>"`, where line is the 0-based jsonl line and part is the content block index. For Cursor it is `"<file>.<line>.<part>"`. Ids stay the same as the file grows.
- `--json` alone keeps today's output (messages only, ids `"0"`, `"1"`, …). Plain mode is unchanged. Any other argument count still exits 64.

- [ ] **Step 1: Write the failing tests** in `test-transcript.py`. Add a `read_activity(reader, entries)` helper that calls the reader with `activity=True`.
  - `test_claude_activity_kinds_targets_and_order`: one assistant line with blocks `text`, `tool_use Read {file_path:"/r/a.swift"}`, `tool_use Bash {command:"npm test\nsecond line"}`, `tool_use Grep {pattern:"redirect_uri"}`, `tool_use Edit {file_path:"/r/b.swift"}`, `tool_use TodoWrite {}`. Each line has `"timestamp":"2026-10-31T10:00:00.000Z"`. Expect roles `[assistant, activity×5]`, kinds `[read, run, search, edit, other]`, targets `["/r/a.swift", "npm test", "redirect_uri", "/r/b.swift", "TodoWrite"]`, ids `["0.0", "0.1", "0.2", "0.3", "0.4", "0.5"]`, and every `time` equal to the timestamp.
  - `test_long_command_target_is_truncated`: a Bash command of `"x" * 5000`. Expect a target length of 120.
  - `test_tool_use_without_input_is_other_with_name`: `{"type":"tool_use","name":"Mystery"}`. Expect kind `other` and target `"Mystery"`.
  - `test_codex_function_calls_become_activity`: `response_item` payloads `function_call name "shell" arguments '{"command":["bash","-lc","rg foo"]}'`, `function_call name "exec_command" arguments '{"cmd":"npm test"}'`, and `custom_tool_call name "apply_patch" input "*** Begin Patch\n*** Update File: src/a.ts\n..."`. Expect kinds `[run, run, edit]` and targets `["rg foo", "npm test", "src/a.ts"]`.
  - `test_json_without_activity_is_unchanged`: the existing three tests still pass, and `main([... "--json"])` output has no `activity` roles and ids `"0"`, `"1"`.
  - `test_ids_are_stable_when_lines_are_appended`: read once, append a line, read again. The first result is a prefix of the second.
- [ ] **Step 2: Run them and confirm they fail.** Run `python3 scripts/todo/test-transcript.py`. Expected: the new tests fail.
- [ ] **Step 3: Implement.**
  - Add `activity=False` to `claude_lines`, `codex_lines` and `cursor_lines`.
  - Add `step(name, tool_input) -> (kind, target)`.
  - Claude kinds: `Read`/`NotebookRead`/`WebFetch` → read, `Edit`/`Write`/`MultiEdit`/`NotebookEdit` → edit, `Bash` → run, `Grep`/`Glob`/`WebSearch` → search, anything else → other.
  - Claude targets: `file_path`, `notebook_path`, `command`, `pattern`, `url` or `query`, whichever exists first. Otherwise use the tool name.
  - Codex: `shell` and `exec_command` → run, with the target taken from `cmd` or from the last element of `command`. `apply_patch` → edit, with the target being the first `*** (Update|Add|Delete) File: ` path.
  - Cursor: `tool_use` parts in a message's content list use the Claude mapping, so Cursor gets activity rows wherever its files record tool steps.
  - Every target: first line, then `[:120]`.
  - `main` accepts exactly `--json` or `--json --activity`.
- [ ] **Step 4: Run them and confirm they pass.** Run `python3 scripts/todo/test-transcript.py && scripts/todo/test-todo-scripts.sh`. Expected: all OK.
- [ ] **Step 5: Commit** with `git commit -m "feat(scripts): transcript --activity with tool steps, times and stable ids"`.

### Task 2: Decode entries in the app and fall back for old helpers

**Files:**
- Modify: `Sources/AISessionCore/Models/ConversationMessage.swift`, `Sources/AISessionCore/Tmux/TmuxCommandBuilder.swift`, `App/AISessionRemote/Services/RemoteConversations.swift`, `App/AISessionRemote/Services/TodoHubStore.swift:597-611`
- Test: `Tests/AISessionCoreTests/ConversationMessageTests.swift`, `Tests/AISessionCoreTests/TmuxCommandBuilderTests.swift`

**Interfaces:**
- Produces:
  - `ConversationMessage.Role` gains `case activity`.
  - `ConversationMessage` gains `time: Date?`, `kind: ActivityKind?` and `target: String?`.
  - `public enum ActivityKind: String, Decodable, Sendable { case read, edit, run, search, other }`. An unknown kind decodes as `.other`.
  - `ConversationMessage.decodeList(_ data: Data) throws -> [ConversationMessage]` parses ISO-8601 with and without fractional seconds.
  - `TmuxCommandBuilder.conversationTranscript(tool:sessionId:json:activity: Bool = false)` appends ` --activity`.
  - `RemoteConversations.OldHelper: Error` is thrown by `check` for exit 64.
  - `TodoHubStore.conversationMessages` tries `activity: true` first. On `OldHelper` it retries without, and remembers that computer name for the rest of the app run.

- [ ] **Step 1: Write the failing tests.**
  - `testActivityEntriesDecodeWithKindTargetAndTime`: JSON with an activity entry `{"id":"0.1","role":"activity","text":"","kind":"run","target":"npm test","time":"2026-10-31T10:00:00.123Z"}`. Assert `.activity`, `.run`, `"npm test"`, and a non-nil time.
  - `testMissingTimeAndUnknownKindStillDecode`: `"kind":"teleport"` with no time. Expect `.other` and a nil time.
  - `testTranscriptCommandAddsActivityFlag`: `conversationTranscript(tool:"claude", sessionId:"s", json:true, activity:true)` contains `"--json --activity"`.
- [ ] **Step 2: Confirm they fail.** Run `swift test --filter "ConversationMessageTests|TmuxCommandBuilderTests"`. Expected: compile errors or failures.
- [ ] **Step 3: Implement** the interfaces above. Use a `Set<String>` of computer names on `TodoHubStore` for the fallback.
- [ ] **Step 4: Confirm they pass.** Run the same command. Expected: PASS.
- [ ] **Step 5: Commit** with `git commit -m "feat: decode transcript activity entries; fall back for old helpers"`.

### Task 3: Chat timeline (grouping, timestamps, sent and answered items)

**Files:**
- Create: `Sources/AISessionCore/Chat/ChatTimeline.swift`
- Test: `Tests/AISessionCoreTests/ChatTimelineTests.swift`

**Interfaces:**
- Consumes: `ConversationMessage` and `ActivityKind` (Task 2).
- Produces:
  - `public struct PendingSend: Equatable, Sendable { id: UUID; text: String; afterCount: Int }`. `afterCount` is the number of transcript entries when the message was sent.
  - `public struct AnsweredNote: Equatable, Sendable { id: UUID; text: String; afterCount: Int }`.
  - `public enum ChatItem: Identifiable, Equatable { case time(id: String, Date); case message(ConversationMessage); case activity(id: String, steps: [ConversationMessage], summary: String); case pending(PendingSend); case note(AnsweredNote) }`. The id of an activity item is its first step's id.
  - `public enum ChatTimeline { static func items(entries: [ConversationMessage], pending: [PendingSend], notes: [AnsweredNote]) -> [ChatItem]; static func unconfirmed(_ pending: [PendingSend], in entries: [ConversationMessage]) -> [PendingSend]; static func summary(_ steps: [ConversationMessage]) -> String }`.

- [ ] **Step 1: Write the failing tests.**
  - `testConsecutiveActivityCollapsesIntoOneItem`: entries user, act(read a), act(read b), act(edit a), act(run x), assistant. Expect items `[time, message, activity, message]` and the summary `"Read 2 files · edited 1 file · ran 1 command"`. Read and edit count distinct targets; run, search and other count steps. The order is read, edit, run, search, other. Use singular and plural forms, and capitalize only the first phrase.
  - `testTimestampsAtStartAndAfterThirtyMinuteGap`: times 10:00, 10:10 and 10:41 produce two `.time` items, one before the first entry and one before the 10:41 entry. Entries without times add no timestamps.
  - `testPendingShowsUntilTranscriptHasMatchingUserText`: pending `"fix it"` with `afterCount: 2` and entries of count 2 → `unconfirmed` keeps it. Then add a user entry `"fix it\n"` at index 2 → it's dropped. A matching user entry before `afterCount` doesn't count. Compare after trimming whitespace and newlines.
  - `testPendingAndNotesAreOrderedByAfterCount`: a note with `afterCount: 1` sits right after the first entry's item. A pending send with `afterCount: 3` comes last.
- [ ] **Step 2: Confirm they fail.** Run `swift test --filter ChatTimelineTests`. Expected: they fail to compile.
- [ ] **Step 3: Implement** `ChatTimeline` as specified.
- [ ] **Step 4: Confirm they pass.** Run `swift test --filter ChatTimelineTests`. Expected: PASS.
- [ ] **Step 5: Commit** with `git commit -m "feat: chat timeline groups activity, timestamps and local sends"`.

### Task 4: Markdown blocks, plain text and folding

**Files:**
- Create: `Sources/AISessionCore/Chat/ChatMarkdown.swift`
- Test: `Tests/AISessionCoreTests/ChatMarkdownTests.swift`

**Interfaces:**
- Produces:
  - `public enum ChatBlock: Equatable { case text(String); case code(language: String?, code: String); case table(rows: [[String]]) }`
  - `public enum ChatMarkdown { static func blocks(_ text: String) -> [ChatBlock]; static func plainText(_ text: String) -> String; static func isLong(_ text: String) -> Bool; static func preview(_ text: String) -> String }`
  - `.text` holds the raw markdown lines. The app styles them in Task 8.

- [ ] **Step 1: Write the failing tests.**
  - `testFencedCodeKeepsExactContent`: `"before\n```swift\n  let a = 1  \n\n    b\n```\nafter"` gives `[.text("before"), .code(language: "swift", code: "  let a = 1  \n\n    b"), .text("after")]`.
  - `testUnclosedFenceRunsToEnd`: an unclosed fence gives `.code` holding the rest of the text.
  - `testPipeTableBecomesRows`: `"| a | b |\n|---|---|\n| 1 | 2 |"` gives `.table(rows: [["a", "b"], ["1", "2"]])`.
  - `testPlainTextStripsMarkersButKeepsCode`: `"# Title\n**bold** and `x`\n- item\n```\ncode  \n```"` gives `"Title\nbold and x\n• item\ncode  "`.
  - `testFoldingThresholds`: 31 lines → `isLong` is true; 30 short lines → false; 2,001 characters on one line → true. `preview` of 40 lines has 20 lines.
- [ ] **Step 2: Confirm they fail.** Run `swift test --filter ChatMarkdownTests`. Expected: they fail to compile.
- [ ] **Step 3: Implement** a line scanner for fences (```` ``` ```` or `~~~`, with an optional language after the opening fence) and for pipe tables (a header row followed by a `---` separator row). For inline markers in `plainText`, use `AttributedString(markdown:options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))` and take `String(attributed.characters)`. Headings drop their `#`s, and list markers `-`, `*` and `+` become `• `.
- [ ] **Step 4: Confirm they pass.** Run `swift test --filter ChatMarkdownTests`. Expected: PASS.
- [ ] **Step 5: Commit** with `git commit -m "feat: chat markdown blocks, plain-text copy and folding"`.

### Task 5: Scroll following

**Files:**
- Create: `Sources/AISessionCore/Chat/ChatFollow.swift`
- Test: `Tests/AISessionCoreTests/ChatFollowTests.swift`

**Interfaces:**
- Produces: `public struct ChatFollow: Equatable, Sendable { public private(set) var pinned = true; public static let tolerance: Double = 40; public mutating func userScrolled(distanceFromBottom: Double); public mutating func jumpToLatest(); public var showsJumpButton: Bool; public var followsNewContent: Bool }`. Only scrolls the user makes call `userScrolled`. Content growth and programmatic scrolls never unpin.

- [ ] **Step 1: Write the failing tests.**
  - `testStartsPinned`: `showsJumpButton` is false and `followsNewContent` is true.
  - `testUserScrollingUpUnpinsAndContentGrowthDoesNotRepin`: `userScrolled(distanceFromBottom: 300)` → `pinned` is false and `showsJumpButton` is true. Then, with no further calls, `followsNewContent` is still false.
  - `testReachingBottomByHandRepins`: `userScrolled(300)` then `userScrolled(39)` → `pinned`.
  - `testJumpToLatestRepins`: unpin, then `jumpToLatest()` → `pinned`.
- [ ] **Step 2: Confirm they fail.** Run `swift test --filter ChatFollowTests`. Expected: they fail to compile.
- [ ] **Step 3: Implement** `ChatFollow`.
- [ ] **Step 4: Confirm they pass.** Run `swift test --filter ChatFollowTests`. Expected: PASS.
- [ ] **Step 5: Commit** with `git commit -m "feat: chat scroll-follow state"`.

### Task 6: Terminal prompt parser (from real screens)

**Files:**
- Create: `Sources/AISessionCore/Chat/TerminalPrompt.swift`
- Test: `Tests/AISessionCoreTests/TerminalPromptTests.swift`, `Tests/AISessionCoreTests/TerminalPromptFixtures.swift`

**Interfaces:**
- Produces:
  - `public struct TerminalPrompt: Equatable, Sendable { question: String; detail: String?; options: [Option]; selected: Int; signature: String }`
  - `public struct Option: Equatable, Sendable { label: String; needsText: Bool }`
  - `public static func parse(screen lines: [String]) -> TerminalPrompt?`
  - `public func keys(toChoose index: Int, tool: String) -> [UInt8]`. It sends `|index - selected|` presses of `TerminalKey.down` or `.up`, then `.enter`, using `TerminalKey.bytes(tool:)`.
  - `signature` is the question plus the option labels, joined with `\n`.

- [ ] **Step 1: Capture fixtures from live sessions on this Mac.**
  1. In a scratch git repo, start each tool in tmux.
  2. Trigger each prompt below.
  3. Run `tmux capture-pane -p -t <pane>` and paste the output verbatim as a `static let` raw string in `TerminalPromptFixtures.swift`.

  Capture these:
  - `claudeBash`: Claude asks to run a command.
  - `claudeEdit`: Claude asks to edit a file.
  - `claudeQuestion`: a Claude `AskUserQuestion` with options and its "Type something" choice.
  - `codexCommand`: Codex asks to run a command.
  - `codexPatch`: Codex asks to apply a patch.
  - `claudeIdle`: Claude's normal input box.
  - `claudeNumberedReply`: a Claude reply that contains a "1. … 2. … 3. …" list, with the input box below it.

  Record each tool's version in a comment.
- [ ] **Step 2: Write the failing tests.**
  - `testClaudeBashPrompt`: a question ending in `?`, a detail containing the command, three options. The selected option is the one marked `❯`. Only the "tell Claude what to do differently" option has `needsText`. Labels have no trailing shortcut hints such as `(esc)`.
  - `testClaudeEditPrompt`, `testCodexCommandPrompt`, `testCodexPatchPrompt`: the same checks. Codex marks the cursor with `›`.
  - `testClaudeQuestionMarksTypeSomethingAsText`.
  - `testIdleAndNumberedReplyAreNotPrompts`: `parse` returns nil for `claudeIdle` and for `claudeNumberedReply`. This is Review Focus 1.
  - `testKeysMoveFromSelectedThenEnter`: selected 0, choose 2 → `down down enter` bytes.
- [ ] **Step 3: Confirm they fail.** Run `swift test --filter TerminalPromptTests`. Expected: they fail to compile.
- [ ] **Step 4: Implement `parse`.**
  1. Strip box-drawing characters (`│╭╮╰╯─┌┐└┘`) and trailing spaces.
  2. Find the bottom-most run of consecutive lines matching `^\s*([❯›>])?\s*(\d+)\.\s+(.+)$`, numbered 1…n, with n ≥ 2 and exactly one line carrying a cursor glyph. A run without a cursor glyph is not a prompt.
  3. The question is the nearest non-empty line above the run that ends in `?`. If there isn't one, there is no prompt.
  4. The detail is the non-empty lines between the box's top and the question, joined with `\n`, or nil if there are none.
  5. `needsText` is true when the label contains `what to do differently`, `Type something` or `Other`.
- [ ] **Step 5: Confirm they pass.** Run `swift test --filter TerminalPromptTests`. Expected: PASS.
- [ ] **Step 6: Commit** with `git commit -m "feat: parse Claude and Codex prompts from the terminal screen"`.

### Task 7: Watch the screen and answer safely

**Files:**
- Modify: `App/AISessionRemote/Terminal/TerminalScreen.swift` (`TerminalCoordinator`), `App/AISessionRemote/Views/Frame/TerminalSurface.swift` (`TerminalHandle`)
- Test: `App/AISessionRemoteTests/TerminalPromptWatchTests.swift`

**Interfaces:**
- Consumes: `TerminalPrompt` (Task 6) and `TerminalKey`.
- Produces on `TerminalHandle`:
  - `private(set) var prompt: TerminalPrompt?` and `private(set) var screenTail: [String]`, the last 12 non-empty screen lines. Both are observable.
  - `func answer(_ prompt: TerminalPrompt, option: Int, tool: String) -> Bool`
  - `func answer(_ prompt: TerminalPrompt, option: Int, text: String, tool: String) async -> Bool`
- Produces on `TerminalCoordinator`: `func screenLines() -> [String]`, which reads the visible rows from `terminalView.getTerminal()`. Prefer reading buffer lines over `selectAll`. After output is fed, it re-parses at most every 250 ms and calls `onScreenChange?(lines)`.

- [ ] **Step 1: Write the failing tests.** Reuse the `ChatRecordingTransport` pattern from `ChatTextTests.swift`, and feed fixture text into a `TerminalView` with `view.feed(text:)`.
  - `testPromptAppearsAfterScreenShowsIt`: feed `claudeBash`, wait 300 ms → `handle.prompt?.options.count == 3`.
  - `testAnswerSendsArrowsAndEnter`: answer option 1 → `transport.sent.last` equals `down + enter`, and the method returns true.
  - `testAnswerRefusesWhenPromptChanged`: take the prompt, feed `codexCommand` (a different screen), then `answer(oldPrompt, …)` → returns false and nothing is sent. This is Review Focus 2.
  - `testTextAnswerChoosesOptionThenSubmits`: pick the `needsText` option with text `"use pnpm"` → the selection keys are sent, followed by a bracketed paste of `use pnpm` and `\r`, once bracketed paste is on. Feed `ESC[?2004h` in the test.
- [ ] **Step 2: Confirm they fail.** Run `xcodebuild test -project AISessionRemote.xcodeproj -scheme AISessionRemote -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:AISessionRemoteTests/TerminalPromptWatchTests` (run `xcodegen generate` first). Expected: they fail to compile.
- [ ] **Step 3: Implement.** `answer` re-parses `screenLines()` right before sending. If the result is nil, or its `signature` differs from the prompt's, it returns false. The text variant sends the selection keys and then calls `submitWhenPasteReady(text)` with a 3 s timeout.
- [ ] **Step 4: Confirm they pass.** Run the same command. Expected: PASS.
- [ ] **Step 5: Commit** with `git commit -m "feat: watch the terminal for prompts and answer only the one shown"`.

### Task 8: Messages in layout A with copy and folding

**Files:**
- Create: `App/AISessionRemote/Views/Frame/Chat/ChatMessageView.swift`, `App/AISessionRemote/Views/Frame/Chat/ChatCodeBlock.swift`, `App/AISessionRemote/Views/Frame/Chat/ChatStyledText.swift`, `App/AISessionRemote/Views/Frame/Chat/SelectTextSheet.swift`
- Modify: `App/AISessionRemote/Views/Frame/ChatTextViews.swift` (keep `ChatMessageText` and use it inside `SelectTextSheet`; keep `ChatDraftEditor`)
- Test: `App/AISessionRemoteTests/ChatTextTests.swift`

**Interfaces:**
- Consumes: `ChatMarkdown` (Task 4) and `ConversationMessage`.
- Produces:
  - `struct ChatMessageView: View { let message: ConversationMessage; let toolName: String }`
  - `enum ChatStyledText { static func make(_ markdownLines: String) -> AttributedString }`

Layout and behavior:
- User messages are right-aligned blue bubbles, at most 78% of the width, with plain text.
- Assistant messages are full width with no background, rendered block by block.
- `.code` blocks show a dark rounded box with a header bar holding the language and a Copy button (it shows "Copied" for 1.5 s). The content is monospaced and scrolls horizontally.
- `.table` blocks scroll horizontally in a grid.
- Long-pressing any message opens `.contextMenu` with Copy (raw `text`), Copy as plain text (`ChatMarkdown.plainText`), Select text (opens `SelectTextSheet` with the raw text in a selectable `ChatMessageText`) and Share (`ShareLink`).
- Messages where `ChatMarkdown.isLong` is true show `preview` with a "Show more" / "Show less" button. The expanded state is keyed by message id.

- [ ] **Step 1: Write the failing tests.**
  - `testStyledTextHasNoMarkdownMarkers`: `String(ChatStyledText.make("# Title\n**bold** `x`\n- item").characters) == "Title\nbold x\n• item"`. The `x` run has a monospaced font.
  - `testCodeBlockCopyIsExact`: `ChatCodeBlock.copyText(for: .code(language: nil, code: "  a  \n\n b"))` returns `"  a  \n\n b"`.
- [ ] **Step 2: Confirm they fail.** Run the xcodebuild command with `-only-testing:AISessionRemoteTests/ChatTextTests`. Expected: they fail to compile.
- [ ] **Step 3: Implement** the views.
- [ ] **Step 4: Confirm they pass.** Run the same command. Expected: PASS.
- [ ] **Step 5: Commit** with `git commit -m "feat: chat messages render markdown with per-block copy"`.

### Task 9: Timeline, activity rows, scrolling and polling in the chat

**Files:**
- Create: `App/AISessionRemote/Views/Frame/Chat/ChatActivityRow.swift`
- Modify: `App/AISessionRemote/Views/Frame/PhoneConversationView.swift`, `App/AISessionRemote/Views/Frame/ConversationFrame.swift:366-370` (pass `liveStatus`)

**Interfaces:**
- Consumes: `ChatTimeline`, `ChatItem`, `PendingSend`, `AnsweredNote` (Task 3), `ChatFollow` (Task 5), `ChatMessageView` (Task 8).
- `PhoneConversationView` takes `status: ConversationStatus` in place of `needsApproval: Bool`.

Behavior:
- **Rendering.** `ForEach(ChatTimeline.items(...))` draws each item:
  - `.time` as a centered caption: "Today 14:02", or a date for other days.
  - `.activity` as `ChatActivityRow`, a collapsed `▸ summary`. Tapping it shows one line per step: "Read `target`", "Edited `target`", "Ran `target`", "Searched for `target`", or the tool name for `other`.
  - The last activity item stays expanded while the status is `.busy`, under a pulsing "Working…" line.
  - `.pending` as a user bubble at 60% opacity.
  - `.note` as a secondary one-line row.
- **Sending.** `send()` appends a `PendingSend` before calling `terminal.sendMessage`. A failed send removes it and keeps the draft, as today. Each refresh replaces `pending` with `ChatTimeline.unconfirmed(pending, in: messages)`.
- **Scrolling on iOS 18.**
  - Use `ScrollPosition` with `.scrollPosition($position)`.
  - `onScrollPhaseChange` tracks whether the user is interacting.
  - `onScrollGeometryChange` computes `distanceFromBottom = contentSize.height - (contentOffset.y + containerSize.height)`, and calls `follow.userScrolled` only while the phase is interacting or decelerating.
  - When the content height changes and `follow.followsNewContent` is true, call `position.scrollTo(edge: .bottom)`.
  - The ↓ button calls `follow.jumpToLatest()` and `position.scrollTo(edge: .bottom)`. It's a small circular button at the bottom right.
- **Scrolling on iOS 17.** Keep today's `ScrollViewReader` marker behavior.
- **Polling.** The interval is 1 s for `.busy` or `.waiting` and 3 s otherwise. Add `status` to `pollID`.

- [ ] **Step 1: Build and run the existing app tests.** Run the xcodebuild command with `-only-testing:AISessionRemoteTests`. Expected: PASS before the change.
- [ ] **Step 2: Implement** the behavior above.
- [ ] **Step 3: Run the tests again** with the same command. Expected: PASS. Then run `xcodebuild build -scheme AISessionRemoteMac -destination 'platform=macOS'`. Expected: BUILD SUCCEEDED.
- [ ] **Step 4: Check by hand in the simulator** with `DemoFixtures` (Task 11 extends them).
  - Scroll up while the transcript grows: nothing moves, and ↓ shows.
  - Tap ↓ from the top of a long transcript: it lands at the very end, and ↓ hides.
- [ ] **Step 5: Commit** with `git commit -m "feat: chat timeline with activity rows, reliable follow-bottom and faster polling"`.

### Task 10: Approval card, fallback and composer

**Files:**
- Create: `App/AISessionRemote/Views/Frame/Chat/ChatPromptCard.swift`, `App/AISessionRemote/Views/Frame/Chat/ChatComposer.swift`
- Modify: `App/AISessionRemote/Views/Frame/PhoneConversationView.swift`, `App/AISessionRemote/Services/Notifications/NotificationCenterCoordinator.swift:53` (open on Chat)
- Test: `App/AISessionRemoteTests/ChatComposerTests.swift`

**Interfaces:**
- Consumes: `TerminalHandle.prompt`, `.screenTail` and `.answer(...)` (Task 7), `AnsweredNote` (Task 3), and `ChatDraftEditor`.
- Produces:
  - `enum ChatComposerMode: Equatable { case normal; case answering(prompt: TerminalPrompt, option: Int) }`
  - `static func ChatComposer.canSend(mode:, draft:, connected:, promptShowing:) -> Bool`
  - `static let quickReplies = ["continue", "yes", "run the tests", "/compact"]`

Behavior:
- **The card.** Show `ChatPromptCard` above the composer when `terminal.prompt != nil`. It lists the question, the detail in a monospaced box, and one full-width button per option, with the selected option tinted.
  - Tapping an option without `needsText` calls `answer`. On success, add `AnsweredNote(text: "✓ \(label): \(detail first line)")`. On failure, show "That question changed. Here's the new one." and let the card refresh from the new prompt.
  - Tapping a `needsText` option switches the composer to `.answering`. The label above the field reads "Answering: \(label)", with a Cancel button.
- **Fallback.** When `terminal.prompt == nil && status == .waiting`, show `screenTail` in monospace with ↑ ↓ Enter Esc buttons. They send `TerminalKey.bytes(tool:)`.
- **Composer.** A rounded growing `ChatDraftEditor` with an inline send arrow and the dictation button. Drop `PasteButton`; the text view's own menu has Paste. Above it, a row of quick-reply chips that send immediately.
- **Disabled states.** Send and the chips are disabled while a card or the fallback is showing, except Send in `.answering` mode.
- **Notifications.** `NotificationCenterCoordinator.open` sets `UserDefaults.standard.set(true, forKey: "conversation.phoneChat")` under `#if os(iOS)` before routing.

- [ ] **Step 1: Write the failing tests.**
  - `testCanSendRules`:
    - normal mode, with a draft, connected, no prompt → true
    - normal mode with a prompt showing → false
    - `.answering` with a prompt showing and a draft → true
    - an empty or whitespace-only draft → false
    - disconnected → false
  - `testQuickRepliesAreTheSpecList`.
- [ ] **Step 2: Confirm they fail.** Run xcodebuild with `-only-testing:AISessionRemoteTests/ChatComposerTests`. Expected: they fail to compile.
- [ ] **Step 3: Implement** the behavior above.
- [ ] **Step 4: Confirm they pass.** Run the same command, then the full `-only-testing:AISessionRemoteTests` and the Mac build. Expected: PASS and BUILD SUCCEEDED.
- [ ] **Step 5: Commit** with `git commit -m "feat: answer prompts from the chat; new composer with quick replies"`.

### Task 11: Demo fixtures, full verification, live check

**Files:**
- Modify: `App/AISessionRemote/Debug/DemoFixtures.swift`, `App/AISessionRemote/Services/TodoHubStore.swift:598-605` (the demo transcript)

- [ ] **Step 1: Replace the demo transcript** with one that matches mockup A. It should have a user question, three activity steps, a markdown reply with a heading, a list, inline code, a `sh` code block, a 45-line reply that folds, and timestamps 40 minutes apart.
- [ ] **Step 2: Run the full suites.**
  - Run `swift test`, `python3 scripts/todo/test-transcript.py`, `scripts/todo/test-todo-scripts.sh`, and xcodebuild with `-only-testing:AISessionRemoteTests`.
  - Run the Mac build (`xcodebuild build -scheme AISessionRemoteMac -destination 'platform=macOS'`).
  - Expected: all pass, and BUILD SUCCEEDED.
- [ ] **Step 3: Check against a live session** in the simulator.
  - Connect to this Mac and run a Claude conversation.
  - Confirm that the activity rows fill in while it works, that a Bash permission prompt shows the card, that Yes runs the command, and that "No, and tell Claude…" with text reaches Claude.
  - Repeat the prompt check with Codex.
  - Note any differences from the fixtures, and fix the parser with a new fixture and test if needed.
- [ ] **Step 4: Commit** with `git commit -m "chore: demo transcript for the new chat"`.
- [ ] **Step 5: Hand back to the user.** Installing the helper on other computers, merging, and building to the phone are their calls. Don't push or install on remote hosts without asking.
