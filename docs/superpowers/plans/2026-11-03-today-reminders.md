# Today, Reminders, People & Briefing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Reminders and people's dates with pushes, an 08:00 morning briefing, a Today mode/tab in the app, and "Add with an agent" short conversations on a cheap model (Auto by weekly headroom, Claude Haiku or GPT-6.1 Terra).

**Architecture:** Hub v17 adds `reminders`, `people`, `today_settings` (briefing time/on, assistant model choice, last briefing) and `job_runs.chosen_tool`; the scheduler tick sends reminder, date and briefing pushes (held through quiet hours by state, not a queue). Conversation jobs gain `model` and tool `auto`; the runner picks the tool by weekly headroom and reports it at start; `ai-todo-open --model`. `ai-todo-remind` lets the agent list/add. The app gets a Today mode (Mac) and tab (iPhone).

**Tech Stack:** Rust (actix-web, rusqlite, chrono, chrono-tz via existing cron::TZ), sh+Python scripts, SwiftUI.

**Spec:** `docs/superpowers/specs/2026-11-03-today-reminders-design.md`

## Global Constraints

- Time zone Europe/Sofia (`cron::TZ`) for reminders, dates (09:00) and the briefing (default 08:00).
- Repeats: `none`, `daily`, `weekdays`, `weekly`, `monthly`, `yearly`; monthly on a missing day → the month's last day; 29 Feb → 28 Feb in other years.
- A reminder pushes once when due, then stays `due` until Done/Snooze; Done on a repeat → next time strictly after now.
- Quiet hours (push settings) hold reminder/date/briefing pushes until they end; pushed then with sound (not passive).
- Briefing: only non-empty sections; nothing → no push; sections in spec order.
- Assistant: project **Personal** (section P), folder `~/.ai-remote/assistant`, urgent, always run, no worktree; model setting `auto` (default) | `claude` | `codex`; ids default `haiku` and `gpt-6.1-terra`; auto rule: more weekly headroom; no reading for either → claude; one reading → that tool unless >80% weekly.
- Agent-created items save directly with `source: "agent"`.
- Commits end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`; clippy `-D warnings`.

## Review Focus

1. Month-end and leap-day repeats (31st monthly, 29 Feb yearly) land on real dates — Task 1 (`next_time_month_end_and_leap_day`).
2. A hub that was down over a reminder's time sends it once when back, not repeatedly — Task 2 (`overdue_reminder_pushes_once`).
3. Quiet hours spanning midnight (23:00–07:00) hold and then release — Task 2 (`quiet_hours_hold_then_release`).
4. An older runner (doesn't send `tool` at start) with an `auto` job still starts (falls back to claude) — Task 4 (`auto_job_start_without_tool_uses_claude`).
5. Agent text in the starting hint can't break the prompt (data, not instructions) — Task 4 (`assistant_prompt_marks_hint_as_data`).

---

### Task 1: Hub data — reminders, people, settings, recurrence

**Files:** create `todo-server/src/today.rs`; modify `db.rs` (v17), `main.rs`, `todo-shared/src/lib.rs`.

**Produces:**
- `Reminder { id, title, notes, next_at (RFC3339 UTC), repeat, state: "upcoming"|"due"|"done", pushed_at, source, created_at, updated_at }`.
- `Person { id, name, kind: "birthday"|"anniversary"|"other", month, day, year: Option<i32>, notes, source, created_at, updated_at }` + computed `next_date: "YYYY-MM-DD"`, `turns: Option<i32>`.
- `TodaySettings { briefing_enabled: bool, briefing_time: "HH:MM", assistant_model: "auto"|"claude"|"codex", claude_model: String, codex_model: String }`.
- `pub(crate) fn next_after(repeat, local: NaiveDateTime, after: DateTime<Utc>) -> Option<DateTime<Utc>>` (Sofia local wall time kept across DST).
- Routes: `GET/POST /api/reminders`, `PATCH/DELETE /api/reminders/{id}`, `POST /api/reminders/{id}/done`, `POST /api/reminders/{id}/snooze {until}`; `GET/POST /api/people`, `PATCH/DELETE /api/people/{id}`; `GET/PUT /api/today/settings`.

- [ ] Tests: `next_time_daily_weekdays_weekly`, `next_time_month_end_and_leap_day`, `next_time_keeps_wall_clock_across_dst`, `reminder_crud_and_validation` (bad repeat/time → 400), `done_moves_repeat_past_now_and_finishes_once`, `snooze_sets_time_and_upcoming`, `person_next_date_and_turns`, `people_validation` (Feb 30 → 400), `today_settings_defaults_and_update`, `v16_migrates_to_v17`.
- [ ] RED, implement, GREEN, clippy, commit `feat(hub): reminders, people and today settings`.

### Task 2: Hub pushes — reminders, dates, briefing

**Files:** `today.rs`, `scheduler.rs` (`run_tick` calls `today_tick_db`).

**Produces:**
- `pub(crate) fn today_tick_db(conn, now) -> rusqlite::Result<Vec<(String, String)>>`: pushes to send now. Quiet hours read from push settings; inside them nothing is marked sent.
  - Reminders `upcoming` with `next_at <= now` → state `due`, `pushed_at = now`; push (title, notes). A reminder already `due` never pushes again.
  - People: per person, a `people_pushes(person_id, date, kind:'eve'|'day')` row records sends; at/after 09:00 Sofia on the eve/day → push "Tomorrow: Maria's birthday" / "Today: Maria turns 35" (or "Today: Maria's birthday"). Kinds: anniversary "… anniversary", other "… (<notes first line or 'date'>)".
  - Briefing: at/after `briefing_time` Sofia when `last_briefing_on != today` and enabled → build; set `last_briefing_on` (even when empty, so it doesn't retry all day); push only if non-empty.
- `pub(crate) fn briefing_db(conn, now) -> Briefing { reminders_today, dates (today/tomorrow), ready_for_review: Vec<(todo_id,title)> since previous briefing (scheduled todos whose conversation is idle & unreviewed, finished after last briefing time), needs_you: count of conversations waiting, watch: counts by group }`; `GET /api/today` returns it live (for the Today view, `since` = last 24 h when none).
- Push text: title `Good morning`, body lines e.g. `2 reminders · Maria's birthday tomorrow · 3 ready for review · 1 needs you · Sentry: 5 fixed, 1 waiting`.

- [ ] Tests: `due_reminder_pushes_once`, `overdue_reminder_pushes_once`, `quiet_hours_hold_then_release` (23:00–07:00 window), `person_eve_and_day_pushes_once`, `briefing_at_time_once_and_empty_sends_nothing`, `briefing_sections_in_order`, `today_endpoint_live`.
- [ ] RED, implement, GREEN, clippy, commit `feat(hub): reminder, date and briefing pushes; today summary`.

### Task 3: Assistant model and tool choice (hub)

**Files:** `todo-shared/src/lib.rs` (`JobAction::Conversation.model: Option<String>` serde default; tool may be `auto` for the assistant job), `jobs.rs` (validate: `auto` allowed only with `model` none), `runner_api.rs` (start accepts `tool`; job tool `auto` → use request tool if claude/codex else claude; store `job_runs.chosen_tool`; conversation tool = chosen; `StartResponse` gains `model`), `today.rs` (assistant endpoint).

**Produces:**
- `POST /api/today/assistant {text, kind: "reminder"|"person"|null}` → ensures project **Personal** (section P, folder `~/.ai-remote/assistant`) and job `Assistant · Personal` (Conversation, tool from setting: `auto`/`claude`/`codex`, model None — models come from settings at start, urgent, always) and a due run with note = text (≤1000 chars). Returns the run.
- `start_db` for the assistant job: prompt = ASSISTANT_PROMPT (today's date and weekday in Sofia, hint marked as data, helper usage); response `model` = settings' claude_model/codex_model for the chosen tool.
- Due answer for an `auto` job includes `auto_tool: true` so the runner chooses.

- [ ] Tests: `assistant_creates_personal_project_and_run`, `auto_job_start_uses_runner_tool`, `auto_job_start_without_tool_uses_claude`, `start_response_carries_model`, `assistant_prompt_marks_hint_as_data`.
- [ ] RED, implement, GREEN, clippy, commit `feat(hub): assistant conversations with a chosen model`.

### Task 4: Scripts — ai-todo-open --model, runner auto pick, ai-todo-remind, install

**Files:** `ai-todo-open` (`--model <id>`: claude `--model`, codex `-m`), `ai-todo-runner` (auto pick; send `tool` at start; pass `--model` from start response), create `ai-todo-remind`, `install.sh` (HELPERS + `~/.ai-remote/assistant` with `.claude/settings.json` allowing `Bash(~/.ai-remote/bin/ai-todo-remind:*)`, `AGENTS.md` one line), `fixtures/fake-hub.py`, tests.

**Produces:**
- Runner `choose_tool(settings_hint)`: weekly used % per tool via `ai-todo-limits --tool`; rule from Global Constraints.
- `ai-todo-remind list` (reminders + people, compact), `add "<title>" --at "YYYY-MM-DD HH:MM" [--repeat r] [--notes n]`, `person "<name>" --kind k --date MM-DD [--year YYYY] [--notes n]`; posts with `source: agent`; redacts notes; exit 64/65/1.

- [ ] Tests: `open_passes_model_to_claude_and_codex`, `runner_auto_picks_more_weekly_headroom`, `runner_auto_without_readings_uses_claude`, `runner_start_sends_chosen_tool_and_model`, `remind_add_posts_reminder`, `remind_person_posts_person`, `remind_bad_args_exit_64`, `install_creates_assistant_folder_with_allowlist`.
- [ ] RED, implement, GREEN (full suite), commit `feat(scripts): assistant model choice, ai-todo-remind, assistant folder`.

### Task 5: Swift core

**Files:** create `Sources/AISessionCore/TodoHub/TodayModels.swift`; modify `TodoHubClient.swift`, `JobModels.swift` (`model` on ConversationJobAction, decode tool `auto`); test `Tests/AISessionCoreTests/TodayTests.swift`.

**Produces:** `Reminder`, `Person`, `TodaySettings`, `Briefing` models; `ReminderDraft`/`PersonDraft` (validation, request bodies); `ReminderRepeat` with labels; `SnoozeOption` (`.hour`, `.evening`, `.tomorrow`) → `until(now:)` in Sofia; client calls for all routes in Tasks 1–3.

- [ ] Tests: `reminderAndPersonDecode`, `snoozeTimesInSofia`, `draftsValidate`, `briefingDecodesAndIsEmpty`, `clientRoutes`.
- [ ] RED, implement, GREEN, commit `feat(core): today, reminders and people models`.

### Task 6: App — Today mode and tab

**Files:** `AppModels`/`AutomationModels.swift` (`AppMode.today`, ⌃⌘3), new `Views/Today/TodayPanes.swift` (Today, Reminders, People panes, forms, Add with an agent sheet), `PhoneToday.swift`, `TodoHubStore.swift` (today state + calls; refresh unchanged), Mac/iOS root views (mode switch, phone tab), push routing to Today.

- [ ] App tests + Mac build pass; commit `feat(app): Today mode with reminders, people and the briefing`.
