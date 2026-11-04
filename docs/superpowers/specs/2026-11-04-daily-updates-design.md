# Daily updates per project

The user's decisions from 2026-11-03/04. Anything marked *my call* was decided by the assistant, and the user can overrule it.

## Intent

Every morning the user posts an update on their tasks: what they did yesterday, per project.
Today they rebuild that from memory. The hub already knows which todos and conversations ran
and where; what's missing is *what was achieved*. Daily updates write that down automatically,
per project, in the style each audience wants, so the morning update is mostly copy and paste.

## User's decisions

- **Stored on the hub, kept 90 days**, then deleted. (Storage is ~50–100 KB a day; not a concern.)
- **Generated automatically** for the window **08:00 → 08:00 Europe/Sofia**. The day's label
  is the window's start date: "Mon 2 Nov" covers Mon 08:00 to Tue 08:00 and is ready Tuesday morning.
- **Shown on each project's page** (Mac and iPhone), in an **Updates** section, newest day first.
  Not in Today, not its own mode.
- **Opt-in per project**: a **Daily updates** switch on the project. Nothing is summarized for a
  project that's off. The user will switch on Repositories (codbex), Repository (spread),
  sigma-revenue and ai-session.
- **Style per project**, as editable text (the **Update style**) on the project:
  - **codbex** (project "Repositories", Codbex Mac, `~/Repositories`): grouped by Jira task, key
    linked, a line or two on what moved and what's next. Jira: `https://jira.digital.ingka.com/browse/<KEY>`
    (keys seen: ACM, CH, PPM, DSMEM, ATK, …).
  - **spread** (project "Repository", Spread Mac, `~/Spread/Repository`): same shape. Jira:
    `https://solveit.atlassian.net/browse/<KEY>` (keys seen: EIN, SD, DT, SPB).
  - **sigma-revenue**: conversational, a few sentences as told to a teammate.
  - **ai-session**: for the user only: terse, technical, complete.
  - Any other project: a plain bullet list (the default style).
  The Jira sites were found from the conversation history on both Macs.
- **Jira keys** are found **from the conversation** when summarizing it. A key in the todo's
  title wins. The user will try to put keys in todo titles.
- The user's examples of the page were accepted: Copy per day, expandable conversation
  summaries, "Waiting on" a computer, Rewrite, no push, days with nothing skipped.

## Goals

- By ~08:15 on a normal morning, yesterday's update for each switched-on project is ready on its page.
- Copy gives text that's ready to paste.
- Every line can be traced: the day expands to the conversation summaries it was written from,
  and each opens its conversation.

## Non-goals

- Posting anywhere (Slack, Jira comments). The user posts it themselves.
- Pushes or notifications about updates.
- Filling in days before a project was switched on.
- Weekly or monthly recaps (the 90 days of data make them possible later).
- Changing Jira (no transitions, comments or worklogs).

## Anti-goals (would make it a failure even if it runs)

- **Made-up Jira keys or made-up work.** A key must appear in the conversation, a commit or the
  todo title; otherwise the work goes under "Other work". Summaries only state what the
  transcript, commits or todos show.
- **Secrets in summaries.** Summaries are copied into team channels.
- **Noticeable usage cost.** Summaries use the cheap models and must not compete with the
  user's own work for limits.
- **Missing work silently.** If a computer hasn't reported, the day says so.

## How it works

### Two steps

1. **Conversation summaries, on each Mac.** Only the Mac that ran a conversation has its
   transcript, so each Mac's runner (`ai-todo-runner`, which ticks every 60 s) summarizes its own.
2. **The project update, on the project's computer.** Once the day's conversation summaries are
   in, the runner on the project's computer (the one that has its folder, where the commits
   are) writes the project update from them. The hub makes no model calls (the same rule as the
   Today briefing).

### Step 1: conversation summaries

- After 08:00 Sofia, each runner **finds the window's work itself** by scanning its local
  Claude and Codex transcripts for entries timestamped in the window. It matches each
  transcript's working folder to a switched-on project's folder the way `ai-todo-memory` does
  (worktrees under `~/.ai-remote/worktrees/<project>/…` count for their project). The hub's activity
  times (`sessions.last_activity`) can't be used for this, because at 08:00 they can be hours
  behind (pushed at most every 30 min by the Stop hook, and nightly at 03:30).
- **Conversations with no todo count** (plain terminal runs, common on codbex and spread), and
  so do scheduled and watcher runs. Summaries are tied to the tool's session id. The page opens the
  conversation when a todo links it; otherwise it shows the summary with "terminal only".
- For each conversation it reads **only that window's entries** of the transcript
  (`ai-todo-transcript <tool> <session_id> --json --activity`, which has timestamps), passes
  them through the redaction filter (`ai_todo_redact.py`), and asks a cheap model for a short
  summary:
  what was asked, what got done, what's left or blocked, the Jira key(s) if any appear, and
  whether anything was committed or merged. 1–2 KB at most.
- It posts each summary to the hub, tied to the conversation, the project and the day. When
  it's done with the day it tells the hub "computer X has reported day D", even if it
  had nothing to report.
- A Mac that's asleep at 08:00 does this when it wakes (the runner catches up on the previous
  day). *My call:* it catches up at most 3 days back. Older ones are skipped and the day says so.
- **The model** (user's decision 2026-11-04): **Claude Haiku first**, as a single headless prompt
  with **no tools**, like `ai-todo-memory` does it (`claude -p --model haiku --tools ""
  --setting-sources "" --no-session-persistence`). Codex can't run without its shell, so
  **when Claude has no headroom it falls back to GPT-6.1 Terra** (`codex exec`) with a
  **read-only sandbox, no network, run in an empty temporary folder**. Its output goes through
  the redaction filter again before it's posted. The model ids come from the Today model setting.
  Either way it isn't a conversation and doesn't use a worktree. The transcript goes in as data, never as
  instructions.
- **Usage limits**, *my call:* summaries follow the scheduler's "wait for headroom" rule (5-hour
  and weekly, defaults 60% / 80%) for whichever tool is used. If neither tool has headroom, the
  runner waits and tries again on later ticks. The 10:00 fallback below still applies.
- A conversation with no entries in the window gets no summary. A Cursor transcript has no
  timestamps: *my call:* include it only if its status changed in the window, and summarize
  its last part.

### Step 2: the project update

- Every runner reports every day, even when it found nothing. *My call:* the computers that
  **should** report are those whose runner has checked in with the hub in the last 3 days. A
  laptop that has been off for longer isn't waited for. When all of them have reported, the day
  is **ready to write**. A summary that arrives after the update was written always triggers an
  automatic rewrite.
- The project's computer's runner then writes the update with a single model call. The call
  gets the day's conversation summaries, the project's **Update style**, todos of the project
  **completed** in the window (`completed_at`, including ones closed by hand with no
  conversation), current todo titles (for Jira keys), and the **commits** in the window. To get
  the commits it runs `git log --all` for every git repo in the project folder (the folder itself,
  or repos one or two levels down for `~/Repositories` and `~/Spread/Repository`).
  - *My call:* **only the user's commits count.** That means the author email is the repo's own
    `git config user.email`, or the commit is on a `scheduled/*` branch. Shared repos have
    teammates' commits on fetched `origin/*` branches, and those must not show up as the user's work.
  - The window is by **author date**, because rebases change committer dates. Commits are
    de-duplicated by subject and author date, so a rebased or cherry-picked commit counts once.
- The update is Markdown. Jira keys become links using the site in the style text.
- It posts the update to the hub for that project and day.
- **Late computers:** *my call:* if a computer still hasn't reported by 10:00 Sofia, the update is
  written anyway and marked "Waiting on: <computer>". When that computer reports, the update
  is rewritten automatically.
- **Rewrite** (a button on the day): the hub flags the day, and the project's computer rewrites
  it from the stored summaries with current todo titles and style. This is useful after adding a Jira key
  to a todo, or after editing the style.
- A day where nothing happened (no summaries, no completed todos, no commits) gets no update
  and doesn't appear.

### Hub

- Project gains `daily_updates` (bool, default off) and `update_style` (text, empty = the
  default plain-bullets style). Note: `digest_enabled` already exists and is the **memory**
  digest; it's unrelated.
- New storage: conversation summaries (conversation, project, computer, day, text, Jira keys,
  tool/model used); per-day computer reports (computer, day); project updates (project, day,
  Markdown text, waiting-on list, written at, rewrite requested).
- Endpoints for runners to list switched-on projects with their folders and styles, post
  summaries, report a day done, find days ready to write (with their summaries and completed
  todos), and post updates. Endpoints for apps to list a project's updates (paged, newest
  first), get a day's summaries, and request Rewrite.
- **Cleanup:** the existing scheduler tick deletes summaries, reports and updates whose day is
  more than 90 days old, once a day.
- **Rollout**, *my call:* the four style texts above are set on those projects during
  deploy. The switches stay off; the user turns them on.

### The app (Mac and iPhone)

- **Project page:** an **Updates** section below Todos, Conversations and Ideas.
  - One entry per day with an update, newest first, paged back 90 days. The newest is expanded.
  - Each day shows the rendered update with working Jira links, **Copy**, **Rewrite**, and
    "Waiting on: …" if a computer is missing.
  - "▸ N conversations · M commits" expands into the conversation summaries. Each one opens its
    conversation (or says it's gone if it was deleted).
- **Project settings:** the **Daily updates** switch and the **Update style** text.
- **Copy**, *my call:* copies the Markdown as written (with `[KEY](url)` links). Slack and Jira
  both accept pasted Markdown links well enough. If that's wrong in practice, change it later.

## Constraints

- Hub schema is v18 today, so this is v19. Rust server on the Pi. Clippy `-D warnings` runs on deploy.
- Runner and helpers are Python 3 stdlib only, installed on three Macs (this Mac, Codbex Mac,
  Spread Mac) with `install.sh`.
- Times are Europe/Sofia, like the scheduler.
- The apps' refresh-call count test (currently 10 hub calls) must not grow on every refresh.
  Updates load when a project page opens.

## Left to the builder

Table and endpoint shapes, exact prompts, how the runner tracks which days it has done, the
repo-scan depth, the 10:00 fallback mechanism, layout details, Markdown rendering, tests.
