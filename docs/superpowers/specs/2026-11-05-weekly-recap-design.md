# Weekly recap

The user's decisions from 2026-11-05. Anything marked *my call* was decided by the assistant, and the user can overrule it.

## Intent

On Monday morning the user wants to look back at last week and **feel a sense of accomplishment**: what
they worked on, the big things and how much. It's for the user only. Nobody else reads it, and nobody
posts it anywhere. The daily updates (spec `2026-11-04-daily-updates-design.md`) already record each day
per project, but they're written for whoever reads them (the team for codbex and spread) and are mostly
about what's next and what's blocked. The weekly recap turns a week of them into wins.

## User's decisions

- **One recap per week, with a section per project.**
- **The scheduled jobs are part of it**: what the jobs did that week (this absorbs the pending idea
  "Weekly scheduled-jobs summary").
- **Every section is written as a win for the user**, whatever the project's Update style is. That holds
  for codbex and spread too, even though their daily updates are written for the team.
- **Both the big things and the volume**: the highlights plus counts.
- **Ready Monday morning**, in its **own Weekly section** of the app, not on project pages or in Today's briefing.
- The sketch they saw was accepted ("gogo"). It had totals on top, a headline, a section per project with
  a count line and 3–5 wins, scheduled jobs last, and past weeks kept.

## Goals

- By about 08:30 on Monday, last week's recap is in the Weekly section on the Mac and the iPhone.
- It reads as a list of things done, not a to-do list.
- Each project section can be traced back to its days: the daily updates it was written from.

## Non-goals

- Posting or sharing it anywhere, or a Copy button tuned for a team. *My call:* no Copy button at all.
- "Next", "Open", "Blocked" and "waiting on you" items. The daily updates and Today already cover them.
- Monthly or yearly recaps.
- Weeks before this ships. *My call:* the first recap is for the week of Mon 2026-11-02, ready Mon 2026-11-09. It's
  partial, written from the daily updates of 2026-11-04 on. Days before a project's Daily updates were switched on
  are **not tracked**. They're never shown as missing.

## Anti-goals

- **Made-up wins.** Every win must come from a daily update or a conversation summary of that week. No
  inflating ("shipped" when the update says "PR open").
- **Turning into a to-do list.** If a project had nothing finished, its section says what moved, briefly,
  and doesn't fill up with what's pending.
- **Work content leaving its computer's account.** codbex and spread work is only summarized by
  models run on that project's own computer, as it is today for daily updates. See "No cross-project model call".
- **Noticeable usage cost.** One cheap-model call per project per week.

## The week

- **Mon 08:00 → Mon 08:00, Europe/Sofia.** That's the seven daily-update days Mon–Sun. The week is labelled by
  its Monday ("Week of Mon 9 Nov"). *My call*, matching the daily-update window.
- The recap is written once Sunday's daily update exists for each project in it, which is normally
  about 08:15 Monday. *My call:* by 10:00 Monday it's written anyway, from whatever days exist, and the missing
  days are named in that section ("Thu and Fri missing").

## What's on the page

Top to bottom (the sketch the user accepted, with the changes noted):

1. **Title and window**: "Week of Mon 9 Nov", "Mon 9 Nov 08:00 → Mon 16 Nov 08:00".
2. **Totals across all projects**: commits, conversations and scheduled runs.
   - Commits come from that week's `project_updates` rows. Conversations are distinct conversations (see Hub).
     The hub computes them, not a model.
   - *My call:* the sketch's "PRs merged" and "tickets closed" are **dropped**, because nothing counts them reliably today.
     The model may still mention PRs and tickets in the wins.
3. **Headlines**: one line per project, which is that project's own headline (see below). *My call*,
   replacing the sketch's single cross-project sentence (see "No cross-project model call").
4. **A section per project**, for each project with Daily updates on that has at least one daily update
   that week:
   - Name, then a count line: conversations, commits, and days with work (for example "5 of 7 days").
   - **3–5 wins**, written as wins for the user (the model may write fewer for a quiet week).
   - "▸ From 6 daily updates" expands to the week's days. Each one opens that day in the project's Updates section.
   - **Rewrite** (as on daily updates): the project's computer writes the section again.
   - Missing days are named.
   - Project order: *my call*, by number of conversations that week, highest first.
5. **Scheduled jobs**, across all projects, computed by the hub (no model):
   - Totals: runs, succeeded, failed, skipped.
   - Per job: name, project, runs / ✓ / ✗ / skipped.
   - **What they did for you**: a short count line built from the runs. It counts todos created (`todo_id` set), conversations
     started, and watcher findings ("N new").
   - Expanding a job lists its runs, one line each, with the outcome and a link to its todo/conversation where there is one.
     Failed runs come first, then runs whose todo is still waiting for review, as the old idea asked.
   - **Watchers** (jobs whose action kind is `watch`): quiet checks and skipped checks are **not** counted as
     runs. They're shown as "checked N times" on the job's row, so the counts aren't flooded. *My call.*
   - Framed as more wins, but failures are shown plainly, in red, not hidden.

### No cross-project model call

The hub makes no model calls. Each project's section is written by **that project's computer**, as its
daily updates are. So codbex and spread content only goes to the models on the Codbex and Spread Macs. That's
why there's no single cross-project headline: writing one would mean sending every project's work to one
machine's model. *My call*, from the daily-updates rule that summaries stay on the computer that owns the work.

## How it gets written

- **Who:** the runner (`ai-todo-runner`) on the project's computer, the same one that writes its daily updates,
  extended in `ai_todo_updates.py` or alongside it.
- **Input:** that week's daily updates for the project (Markdown), and *my call*, for days whose update is
  missing or failed, that day's conversation summaries instead. The day's commit and conversation counts too.
  It does **not** need transcripts or `git log` again.
- **Output:** JSON with `headline` (one line, at most about 120 characters) and `wins` (Markdown bullets, 3–5).
- **Prompt rules:** written to the user in second person ("you shipped…"), as wins. Use only what the inputs say,
  keep the user's strongest concrete numbers (latency, counts, versions), and leave out what's next or blocked.
  Ignore the project's Update style for voice, but keep Jira keys as links when the style gives a Jira site.
  Redact as daily updates do.
- **Model, limits, fallbacks:** the same as daily-update writing (Haiku headless with no tools, a Codex fallback with
  a read-only sandbox, and the scheduler's wait-for-headroom rule). Retry 3 times, then the section says it couldn't be written and offers Rewrite.
- **Late daily updates:** if a day's daily update is written or rewritten after the recap section,
  the section is rewritten automatically, as late summaries do for daily updates. *My call*: this stops 7 days after the week ends.

## Hub

- **Schema v21.** It adds `weekly_job_tallies` and a per-week jobs snapshot (see below), and a `weekly_recaps` table with one row per (week, project): week start date,
  project id, headline, wins Markdown, days used, days missing, commits, conversations, written at,
  rewrite requested, and failure count.
- *My call:* **kept for good**, with no 90-day cleanup. They're small, and looking back over months is the point.
  The daily updates they were written from still go after 90 days. Past weeks keep their text, and their
  "From N daily updates" list says the days are gone.
- **Runner endpoints:** weeks ready to write for this computer's projects, with their daily updates and fallback
  summaries; post a section; failure reporting. They follow the daily-update ones.
- **App endpoints:**
  - List weeks, newest first and paged. Each week has its sections, totals and scheduled-jobs block.
  - Request Rewrite for a (week, project).
- **Scheduled jobs block**, *my call*: **stored, not computed live.** `job_runs` doesn't keep a week's history:
  `watch_upkeep` (`watch.rs`, `QUIET_RUNS_KEPT_DAYS = 2`) deletes quiet, failed, skipped and missed watcher
  runs after 2 days, and deleting a job cascades to its runs. So:
  - A `weekly_job_tallies` row per (week, job) is updated by the hub **as each run settles**: runs, done, failed,
    skipped, watcher checks, watcher findings, todos created. It also keeps the job's name and project, so it
    survives the job being deleted. Watcher counts are right even though the runs themselves are pruned.
  - The per-run lines (failed and waiting-for-review first) are built from `job_runs` while the week is current.
    When the week ends they're **snapshotted** onto the week, together with the tallies, so a past week never changes. Watcher
    runs pruned before then appear only in the tallies, not as lines.
  - The existing `/api/runs` caps at a small number, so it can't be used.
- **Missing vs quiet days**, *my call*: a day counts as **covered** when every computer that should report has an
  `update_reports` row for it, or the project has a `project_updates` row (failed writes included, with
  `WRITE_FAILED_NOTE`). Covered with no update means a **quiet day**, which isn't shown as missing. **Missing** means
  not covered. **Failed** means a failed-write row; its section falls back to that day's summaries. Only
  missing and failed days are named. "Days with work" counts days that have an update.
- **Ready check:** a week is ready for a project once Sunday is covered (normally right after 08:00, or
  once Sunday's update is written), or it's past 10:00 Monday. A week with a day still handed out for writing in
  the same runner poll waits for a later poll, so a day written alongside the recap isn't missed. The recap PUT
  echoes the item's `built_at`; a daily update of the week written at or after it leaves the recap stale. A failed
  rewrite (`failed: true` over a recap that has wins) keeps the written recap and only clears its flags.
- **Conversation counts**, *my call*: **distinct conversations** (`(tool, session_id)` in `update_summaries` for
  the week). This avoids summing daily counts, which counts a conversation that spans days several times. It's
  computed when the section is written and stored on the recap row, since summaries go after 90 days. Commits are
  summed from `project_updates.commits`.

## The app (Mac and iPhone)

- **Mac:** a **Weekly** item in the Today mode sidebar, after Today, Reminders and People & Dates. *My call* for where.
- **iPhone:** reached from the Today tab: a "This week's recap" row at the top on Mondays, and a Weekly entry
  always reachable from there. *My call*: there's no room for a seventh tab.
- The list shows newest week first, with the latest expanded and older weeks collapsed to their title and totals.
- **No push.** It's a quiet place to look on Monday, matching daily updates. *My call* (the old idea had one push).
- Loads when the Weekly section opens, never on the general refresh. The refresh-call count test must not grow.

## Rollout

- Deploy hub v21 to the Pi. Install the runner change on all three Macs (`install.sh`). Rebuild and install the Mac app, then the iPhone.
- Mark the hub idea "Weekly scheduled-jobs summary" done, as covered by this.
- First real check: on Mon 2026-11-09 the week of Mon 2026-11-02 is written from the daily updates that exist
  (from 2026-11-04 on). It's partial, so it shows the untracked-days path too.

## Constraints

- Rust hub on the Pi. Clippy runs with `-D warnings` on deploy.
- Runner and helpers are Python 3 stdlib only, on this Mac, the Codbex Mac and the Spread Mac.
- Times are Europe/Sofia.

## Left to the builder

Table and endpoint shapes, the exact prompt, how the runner tracks done weeks, layout and
Markdown rendering, the run outcome line text (from `result`, the todo title and state), tests.
