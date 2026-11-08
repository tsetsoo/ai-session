# Handover: Competing agents, stage 3 (start any todo with several agents)

## Goal
Wherever a todo's conversation is started (Mac and iPhone), the user can pick several agents (1–10 rows of tool + model) with the same picker as Research Now. The first message is typed once, in a text box, and sent to every agent as its first message. Each agent runs in its own worktree. All worktrees start from one base: the latest `main` on origin, resolved once for the group. The start sheet shows that base, for example "from origin/main @ 8f5a29c". With one agent, starting stays exactly as today. The agents then use the stage 1 switcher and Continue with This.

Spec: docs/superpowers/specs/2026-11-06-competing-agents-design.md, section "Stage 3". Read the whole spec first: it records the user's decisions, including the anti-goals.
- Never let several agents share one folder.
- Never start them from different commits.

## Already shipped (main, installed everywhere 2026-11-08)
- **Stage 0, worktree per conversation.**
  - Each conversation gets `~/.ai-remote/worktrees/<project>/<conversation>` on branch `ai/<title>-<id8>`.
  - The host makes worktrees with `ai-todo-workspace ensure <path> <folder> <branch> [--base <sha>]`.
  - Cleanup keeps the worktrees of todos that aren't done.
- **Stage 1 (hub v31).**
  - Conversation model and worktree base, and a todo's main conversation.
  - `POST /api/todos/{id}/conversations {source_id, tool, label, own_worktree?, model?, base_sha?}` (cap 10), `/continue`, `/reopen`.
  - `ai-todo-open --worktree/--worktree-base/--model/--prompt-file`.
  - AddAgentSheet (Summary/Full/Fresh), the switcher, Mac Side by Side, Continue with This.
  - Core rules: `AISessionCore/Board/AddAgent.swift` and `ConversationSwitcherModel.swift`.
- **Stage 2 (hub v34; plan docs/superpowers/plans/2026-11-08-competing-agents-stage2-research-with-agents.md).**
  - Research Now opens `ResearchAgentsSheet` (computer + agent rows). Its rules are in `AISessionCore/Board/ResearchAgents.swift`: offered tools, defaults, 1–10 limits, model check, count text.
  - The hub keeps a research group: `run_groups` (todo, computer, base sha, chosen run) plus job runs with `group_id/attempt_tool/attempt_model`. Each attempt's findings live in `idea_findings`.
  - Runners report installed tools (`computers.tools`). The tools report finds Codex via `ai-todo-status codex-path`.
  - The runner proposes a base on the group's first claim (`ai_todo_workspace.resolve_base`: best-effort fetch, then `origin/HEAD`, else `HEAD`). Every attempt's worktree starts at that base.
  - A group with several agents in a folder outside git is refused.
  - Failed or missed attempts show "didn't start" with Retry (`POST /api/runs/{id}/retry`).
  - Cursor takes the first message through `ai-todo-open --prompt-file`, checked by hand.
  - Model names may contain `[` and `]`.
- **Stage 2 was tried by hand on 2026-11-08** and worked end to end.
  - Claude + Codex attempts started on the same base commit.
  - Each saved its findings to its own attempt.
  - Continue with This marked the chosen findings, and the other attempt closed with its worktree kept.
- **Follow-up fixes (commit 0f46395):**
  - A research attempt whose `ai-todo-open` timed out counts as started.
  - Opening a Research Now todo before its agents start answers 409.

## What stage 3 needs
- **Sheet.**
  - Where: the "Start Conversation" step of a todo with no conversation. On the Mac that's `App/AISessionRemote/Views/Frame/ConversationFrame.swift` (`startConversation`, tool choice via `ConversationStart`); the iPhone has its equivalent.
  - What it offers: agent rows (reuse `ResearchAgents` rules and the row UI from `ResearchAgentsSheet`; consider renaming them to a general agent picker), a first-message text box, and the base line "from origin/main @ <short sha>".
  - With one agent and no text, it looks and behaves exactly as today.
- **Base.** Resolve once per start: fetch, then `origin/HEAD`, on the todo's computer.
  - The app needs it before Start, to show it. Add a host helper over SSH; for example, `ai-todo-workspace base <folder>` printing `resolve_base`.
  - Pass the sha to every agent's worktree (`ensure --base`, `ai-todo-open --worktree-base`).
- **Refusal.** In a project with worktrees off (`projects.worktrees`), or a folder that isn't a git repo, a start with several agents is refused with a clear message. The hub already knows both (`plan_worktree` in conversations.rs).
- **Starting the agents.** This is the builder's call; ask the user if unsure.
  - (a) **App-driven:** open the todo's first conversation with `--worktree-base`. Add the others with stage 1's `POST /api/todos/{id}/conversations` (`own_worktree: true`, `base_sha`, `model`), each started with the typed text through `--prompt-file`. The plumbing exists from stage 1's Fresh hand-off. Attended starts are interactive, so this fits better.
  - (b) **Hub group like stage 2:** the runner starts them. But the runner uses `--auto-approve` and detached sessions, which is right for unattended jobs, not for a todo the user is driving.
  - I'd go with (a).
- **Hub:** add agents count and model rules as today (cap 10). No new schema should be needed for (a). If one is, take the next free version: main is at v34 on 2026-11-08, and other sessions bump it.

## How to work
- Read AGENTS.md. Work in your own worktree, rebased on `origin/main`. Other sessions push often: expect conflicts in conversations.rs, db.rs, TodoHubModels.swift and ConversationFrame.swift.
- Process: write the stage 3 plan with superpowers:writing-plans, then ask the user how to execute it. Last two stages were "native": built inline, then one fresh review on the most capable model at the end. Use TDD for every step and record rulings in the plan's ledger.
- Commands:
  - `cd todo-app && PATH=$HOME/.cargo/bin:$PATH cargo test`
  - `ai-session-remote/scripts/todo/test-todo-scripts.sh` (~5 min; it stops at the first failure, so a new test placed after an older failing one is only seen red one at a time)
  - `cd ai-session-remote && swift test`
  - Mac/iOS builds: `xcodegen generate`, then `xcodebuild … CODE_SIGNING_ALLOWED=NO`
  - App tests on the "iPhone 17 Pro" simulator (`xcodebuild test -scheme AISessionRemote`)
- In shell tests, give scheduled runs distinct first-8 characters: the worktree branch uses `run_id[:8]`.
- Don't add conversations to the shared DemoFixtures: MacShellTests count the demo board.
- Install, only when the user says go:
  1. `git fetch`, then fast-forward to `origin/main` right before any app build. On 2026-11-08 a rebuild from a branch tip wiped another session's just-pushed shell panel.
  2. install.sh on all three Macs if scripts changed: here, the Spread Mac (tsvetelinpantev@100.94.164.63) and codbex (tsetso@100.107.204.56), via `tar -czf - scripts/todo watchers jobs | ssh -i ~/.ssh/id_ed25519_aisession -o IdentitiesOnly=yes <host> 'd=$(mktemp -d) && tar -xzf - -C "$d" && "$d/scripts/todo/install.sh"'`.
  3. Push to main. The Pi deploys the hub in ~4 min (check the "Deploy Pi" workflow).
  4. `ai-session-remote/scripts/rebuild-mac-app.sh`.
  5. iPhone: Release `generic/platform=iOS` with `DEVELOPMENT_TEAM=233QTK6KCL -allowProvisioningUpdates` and a separate `-derivedDataPath`, then `xcrun devicectl device install app --device 4D12CF95-8742-5E85-B437-8FA575F0DF13 <app>`.
  - Scripts go out before the hub and app: older runners lack newer routes. After a hub change, a runner that ticked before the deploy backs off an hour on new routes. Delete `~/.ai-remote/runner-state/tools.json` (or the matching state file) to retry at once.
- Testing the Mac app by hand: the user clicks. Driving it with AppleScript failed on 2026-11-08: there's no screen-recording permission, and the app kept jumping back to Sessions. You check the result behind it (hub API, worktrees, tmux panes).
- Write user-facing text in plain language: no jargon, short sentences.

## Open items (fix if you touch the code)
From stage 2's review (deferred):
- A newly failed research attempt reaches an open switcher only when `store.revision` bumps. Scheduled non-research todos also reload ideas.
- Late findings set an idea back to `researched` after the user dropped it.
- Two attempts saving findings first at the same moment: the later one becomes the idea's copy.
- The Research sheet with an unknown or empty computer list shows a blank picker and offers every tool.
- A retried attempt moves to the end of the attempts list.

Still open from stage 1:
- A failed add leaves its worktree and branch on disk.
- Add Agent stays enabled at the 10-agent cap.
- writePromptFile uses `base64 --decode`.
- In a monorepo subfolder project, a conversation opens at the worktree root.
- Fresh from a source with no `worktree_base` starts from the default branch, not a recorded base.
- Side by side: clicking a pane doesn't make it frontmost (the toolbar still acts on the selected tab).
- A newer app with an older hub silently shares the folder on Add Agent.
