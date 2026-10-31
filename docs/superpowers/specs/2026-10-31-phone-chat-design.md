# iPhone chat: read, copy and answer like a chat app

Date: 2026-10-31
Status: draft for review

## Why

The iPhone app already has a Chat/Terminal switch (`PhoneConversationView.swift`, shipped in 5432b12). The chat still feels like a log, though:

- Messages are raw text, so markdown symbols (`**`, `#`, backticks, ``` fences) show as typed.
- Every card has a Copy link, but there's no quick way to grab one command or code block.
- During a long turn nothing appears until the reply lands, because the transcript only keeps user and assistant text.
- When the agent asks for permission, the chat only says "Needs your input — open Terminal".
- The "Latest" button sometimes doesn't take you to the bottom.

The goal is a chat that reads like the Claude iOS app. The user should be able to copy exactly what they need and answer everything the agent asks without switching to the terminal.

## Goals

1. Laid out like the Claude app (mockup A). The user's messages are right-aligned blue bubbles. Assistant replies are full-width text with no bubble.
2. Assistant markdown is rendered: headings, lists, bold/italic, links, inline code, code blocks and tables.
3. Copying gives the exact original text:
   - Each code block has its own Copy button.
   - Long-pressing a message offers Copy (markdown source), Copy as plain text, Select text, and Share.
   - The per-header Copy link is removed.
4. Long replies fold behind "Show more".
5. Timestamps appear at the start of the chat and after long gaps.
6. Scrolling is reliable:
   - "Following the bottom" is worked out from the actual scroll position.
   - The ↓ button always reaches the true end.
   - New content scrolls into view only while the user is at the bottom.
7. A sent message appears immediately, before the transcript catches up.
8. Activity rows: between messages, one collapsed row summarizes the agent's steps ("▸ Read 4 files · edited 2 · ran 3 commands"). Tapping it expands to one line per step ("Edited `auth/callback.ts`", "Ran `npm test -- auth`"). While the agent is busy, the newest row stays expanded under a "Working…" line and fills in as steps happen.
9. Every question the agent asks can be answered in the chat (see "Approvals").
10. The composer is a growing rounded field with the send arrow inside, dictation beside it, and Paste in the field's menu. Above it sits a row of quick replies: "continue", "yes", "run the tests", "/compact". Tapping a quick reply sends it at once.
11. The chat refreshes about every 1 s while the agent is busy and every 3 s otherwise.

## Non-goals

- The Mac app. This work is iPhone only; the Mac keeps its terminal-first layout.
- Live streaming from the hub or computer. Faster polling is enough for now.
- Showing full diffs or command output in the chat. The Terminal tab has them.
- Editing the quick replies in Settings. That can come later.

## Anti-goals (a failure even if it "works")

- Copy changes the text. Copied commands must be byte-identical to the source: no smart quotes and no lost indentation or blank lines.
- An approval is sent to the wrong prompt. A tap must never answer a prompt other than the one shown, for example a newer prompt that replaced it.
- The user gets stuck. If the app can't understand a prompt, the user can still answer from the chat.
- The chat jumps while the user is reading further up.
- Switching between Chat and Terminal loses the draft, the scroll position, or the terminal connection. This works today and must keep working.

## Constraints

- iOS 17 minimum (`project.yml`). Prefer built-in SwiftUI/UIKit. Add a markdown dependency only if `AttributedString(markdown:)` plus a custom block renderer can't handle code blocks and tables well.
- Each poll fetches the transcript with `ai-todo-transcript <tool> <id> --json` over SSH (`TodoHubStore.conversationMessages`), not through the hub.
- Computers will run older helper scripts for a while. The app must keep working with the current JSON (messages only) and simply show no activity rows.
- Message ids are currently list indexes. Once activity entries are added, ids must stay stable across polls so scroll position and expanded rows don't reset.
- Claude and Codex are required. Cursor gets activity rows only where its transcripts include tool steps.
- Selection must stay native, with system handles and the Copy menu (as `ChatMessageText` provides today).

## What was decided

### Layout
Mockup A, kept at `.superpowers/brainstorm/82933-1793456809/content/chat-layout.html`. The Chat/Terminal segmented control stays at the top, and the live terminal stays mounted behind the chat.

### Approvals
- **Reading the question.** The app reads the question from the live terminal screen the phone already holds. The hooks only report *that* a conversation is waiting (`liveStatus == .waiting`), not what it is asking.
- **The card.** It shows the question, the command or file it concerns in a monospace box, and one button per option the prompt offers. Tapping a button sends the same key or keys a person would press in the terminal.
- **Options that need text.** "No, and tell Claude what to do differently" and free-text answers open the composer with a label naming what it answers. Sending fills the answer in.
- **Fallback.** If the screen doesn't match a known prompt, the card shows the last lines of the terminal as plain text, with ↑ ↓ Enter Esc buttons.
- **After answering.** The card collapses to a one-line record ("✓ Allowed: npm test").
- **Notifications.** Opening a "needs approval" notification lands on the chat with the card visible.
- **What shows the card** *(designer's call).*
  - Either signal is enough: the terminal screen showing a prompt the app recognizes, or the hub status being `.waiting`.
  - The status alone can't be the trigger. Cursor never reports `waiting`, Codex may not, and the status can lag behind the screen.
  - While Chat is visible, the app checks the screen each time the terminal updates, at most a few times a second.
  - The raw-terminal fallback card appears only when the status is `.waiting` and no known prompt is recognized. Otherwise it would be on screen all the time.
  - For Cursor, approvals work only as far as its prompts can be recognized on screen.
- **Composer while a prompt is up** *(designer's call).*
  - Send and the quick replies are disabled, as Send is today, so typed text can't land in the agent's option menu. This is the same reason `ApproveGate` exists.
  - The one exception is the free-text answer mode. It replaces the normal composer: a label names the option being answered, and Cancel brings the normal composer back.
  - Every key sent to answer a prompt, including filling in a free-text answer, first checks that the screen still shows the same prompt the card displays. If it doesn't, nothing is sent and the card refreshes.

### Activity rows
- The host script `ai-todo-transcript` stops discarding tool calls. In `--json` mode it emits a short entry for each step, with a kind (read, edit, run, search, other) and a target (path, command or query).
- Command text is truncated. Diffs and output are left out.
- The script's plain-text mode (used by the duplicate summary) stays unchanged.

### Updates
Keep polling. Poll faster while busy. Show the user's message optimistically and merge it once the transcript contains it.

## Left to the builder

- The JSON shape for activity entries and timestamps, and how ids are made stable (for example, from the transcript line's uuid or byte offset).
- Markdown rendering. Text must stay selectable, so it is probably `UITextView` with attributed text for prose plus separate SwiftUI views for code blocks and tables.
- The "Show more" threshold. Start around one screen height.
- The gap that triggers a timestamp. Start around 30 minutes.
- Prompt parsing for Claude and Codex permission prompts and Claude's multiple-choice questions, how to detect that a prompt changed before sending a key, and test fixtures captured from real screens.
- Whether 1 s polling over SSH is acceptable, or whether the script should accept an "after id" so it returns only new entries.
- How scroll position is tracked on iOS 17 (for example, `onScrollGeometryChange` needs iOS 18, so iOS 17 may need a UIKit-backed approach or `scrollPosition(id:)`).
- Updating `DemoFixtures` and the screenshot flow to show the new chat.
- Tests: copy fidelity, prompt parsing, the transcript script's activity output (`test-transcript.py`), and following the bottom.
