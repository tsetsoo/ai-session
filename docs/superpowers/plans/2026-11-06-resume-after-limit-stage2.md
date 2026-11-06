# Resume after a usage limit: stage 2

Idea 6458f675. Stage 1 (f3f21e0) shows a quiet "Paused" status. Stage 2 resumes it.

**Revised 2026-11-06:** Claude's own `autoContinueAtUsageLimit` handles Claude session limits,
so the computer auto-resumes only Codex (the toggle shows for Codex only; the hub refuses an
automatic Claude claim with `claude_continues`). Weekly and unknown limits get the one-tap
Resume for both tools. Claude's auto-continue arms for any limit that resets within 24 h, so
it may also continue a weekly limit on its last day. Input in the last 2 minutes defers a
resume rather than cancelling it.

Binding decisions: no push ever; a session limit resumes on its own only with the
conversation's toggle on (default off, switching it off cancels); a weekly or unknown limit
never resumes on its own and gets a one-tap "Resume" at the reset; this is separate from the
scheduler's headroom gate.

## Hub (schema v27)

`conversations` gains:

| column | meaning |
| --- | --- |
| `resume_on_reset` | the toggle (0/1, default 0) |
| `resume_off_reason` | `cap` when the hub turned the toggle off |
| `resume_attempts` | JSON list of UTC times in the last 24 h: auto-resumes, and limit hits within 10 min of a resume |
| `resume_last_at` | when the last resume was typed |
| `resume_at` | when the host plans to type it (shown as "Resumes at 16:42") |
| `resume_offer` | the one-tap Resume is offered |
| `resume_token`, `resume_lease_until` | the lease: one sender at a time |

`resume_at`, `resume_offer` and the lease belong to one pause. A new pause or the end of a
pause (any other status or a new turn) clears them.

Routes:

- `PUT /api/conversations/{id}/resume {resume_on_reset}` (the app). On clears the off reason
  and the attempt count; off clears `resume_at`.
- `POST /api/conversations/resume {tool, session_id, action, ...}` (the host), answers the
  conversation's resume state plus `granted`/`reason`:
  - `state`: read only
  - `arm {resume_at}`: kept only while paused by a session limit with the toggle on
  - `disarm`
  - `offer`: raise the one-tap Resume (still paused only)
  - `claim {token, manual}`: compare-and-set lease (3 min). Auto needs the toggle, a
    session pause, not reviewed, fewer than 3 attempts in 24 h. At the cap the toggle goes
    off with reason `cap` and the offer is raised instead.
  - `sent {token}`: the keys were typed; `release {token}`: they weren't.

A paused idle conversation still sends no push; none of these routes push.

## Host (ai_todo_status.py, the status service)

- `publish()` writes `status-state/resume/<tool>.<sid>.json` when it sends a pause and removes
  it when the status leaves idle, a new turn starts, or Claude reports
  `quota_auto_resume_fired` (the hook maps that notification to busy).
- `watch()` runs a resume loop (every 15 s) over those files:
  - due = reset + 2 min + 0-90 s jitter (from the session id). No reset time: read
    `ai-todo-limits` for the exhausted window's reset; else back off 5, 15, 30, 30... min.
  - session limit before due: `arm` every minute, which also tells it the toggle.
  - at due: missed by over 12 h, weekly, unknown, or the cap: `offer` and stop. Session with
    the toggle off: stop.
  - session with the toggle on: checks, `claim`, type, `sent`.
- Checks (also for the manual tap, except the first two): toggle on and not reviewed
  (auto only), no tmux keyboard activity since the pause (auto only), still paused and not
  closed, an empty prompt with no question card (Python port of the phone's
  TerminalPrompt, tested on its fixtures), `ai-todo-limits` headroom (a window past its
  reset counts as reset).
- Typing: Escape, the text, Enter, to the `=name:` target. A missing tmux session is
  reopened with `ai-todo-open --detached` first. A question card is never answered.
- `ai-todo-status resume <tool> <session_id>`: the app's one-tap Resume, over SSH. Exit 0
  typed, 75 not now (reason on stdout as JSON).

## App

- Conversation `resume_on_reset`, `resume_off_reason`; `paused.resume_at`, `paused.offer`.
- Conversation menu: "Resume after the session limit" toggle.
- Status detail: "Session limit · resumes 16:42"; "Auto-resume off after 3 in 24 h".
- "Resume" button in the conversation toolbar and the row when offered; runs the host command.
