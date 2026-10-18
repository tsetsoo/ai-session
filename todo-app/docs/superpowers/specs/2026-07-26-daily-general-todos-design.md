# Daily + General Todos Design

**Date:** 2026-07-26  
**Status:** Approved  
**Repo:** todo-app

## Goal

Extend the app so users have a dated **Daily** focus list and a **General** backlog. The same todo can appear in both; completing it anywhere completes it everywhere. Users explicitly create today’s or tomorrow’s Daily board; unfinished Daily items can be carried forward with a “carried from …” hint.

## Context (current)

- Todos have sections Sp / I / Si / P, importance, optional due date, completion/archive.
- No daily board, carry-forward, or “on daily” membership today.

## Product decisions

| Topic | Decision |
|---|---|
| Relationship to sections | **B** — Daily is today’s focus; General is backlog; Sp/I/Si/P still apply in both |
| Pull General → Daily | Same item identity; visible in both; complete either place closes both |
| Carry-forward | **C** hybrid — explicit Create button, dated boards, carried-from hint |
| Create button | No daily for today → **Create todos for today**; else → **Create todos for tomorrow** |
| Create tomorrow mid-day | Incomplete items **leave today’s Daily immediately** (move `daily_date`) |
| Data approach | **A** — fields on `todos` + small `daily_days` table for empty-board existence |

## Data model

### `todos` (additive columns)

| Column | Type | Meaning |
|---|---|---|
| `daily_date` | `TEXT NULL` (`YYYY-MM-DD`) | On a Daily board for that date; `NULL` = General-only |
| `carried_from` | `TEXT NULL` (`YYYY-MM-DD`) | Previous daily date when carried; cleared on complete or remove-from-daily / manual pull |

Existing columns (`section`, `title`, `completed`, `importance`, `due_date`, …) unchanged in meaning. `completed` remains global.

### `daily_days`

```sql
CREATE TABLE IF NOT EXISTS daily_days (
  date TEXT PRIMARY KEY  -- YYYY-MM-DD
);
```

A board for date `D` **exists** iff `daily_days` contains `D`. Create always inserts the target date even when there is nothing to carry.

## Rules

### Views

- **Daily (today):** If `daily_days` contains local today, show todos with `daily_date = today` (incomplete + completed as existing list filters allow). Header shows that date.
- **Daily empty state:** No row for today → empty Daily + primary **Create todos for today**.
- **General:** Existing section UX; all todos remain listed per current filters. Items with `daily_date` set show an “On daily · YYYY-MM-DD” badge.
- **Carried hint:** If `carried_from` is set, show “Carried from YYYY-MM-DD” on Daily (and optionally General).

### Pull / remove

- **Add to Daily:** Requires today’s board (`daily_days` contains `local_today`). Sets `daily_date = local_today` and clears `carried_from`. If today’s board does not exist, UI prompts **Create todos for today** first (API returns 409).
- After **Create todos for tomorrow**, incompletes already live on tomorrow; further pulls during the same calendar day still target **today** (today’s board remains until the calendar rolls).
- **Remove from Daily:** set `daily_date = NULL`, `carried_from = NULL`.

### Create button

Client sends `local_today` (`YYYY-MM-DD`). Server derives `tomorrow = local_today + 1 day`.

| Condition | Button label | Action |
|---|---|---|
| `daily_days` lacks `local_today` | Create todos for today | Insert `daily_days(local_today)`. Let `prior` = latest `daily_days.date < local_today` if any. For each incomplete todo with `daily_date = prior`, set `daily_date = local_today`, `carried_from = prior`. |
| `daily_days` has `local_today` | Create todos for tomorrow | If `daily_days` already has tomorrow → no-op. Else insert tomorrow. For each incomplete todo with `daily_date = local_today`, set `daily_date = tomorrow`, `carried_from = local_today`. |

Completed todos never move. Re-Create for an existing target date is a no-op.

### Completion

- Toggling complete/incomplete updates the single row; Daily and General both reflect it.
- On complete, clear `carried_from` (optional cleanup; `daily_date` may remain for history on that day).

## UI

### Navigation

- Top-level modes: **Daily** | **General** (General retains Sp/I/Si/P tabs/views).
- Daily header: date + Create button with dynamic label.
- Daily list: keep importance / due date; show section badge; carried-from line; actions complete, edit, remove from Daily.

### General

- Per-item **Add to Daily** when today’s board exists; otherwise disabled or CTA to Create.
- Badge when `daily_date` is set.

### Non-goals (v1)

- Recurring todos, multi-day calendar planner, rich past-day editing (read-only past Daily later).
- Automatic midnight rollover.
- Copy-on-pull (duplicate instances).

## API (additive)

Timezone: client sends `local_today` on status/create so the Pi’s clock/timezone does not redefine “today”.

| Endpoint | Purpose |
|---|---|
| `GET /api/daily/status?local_today=YYYY-MM-DD` | `{ local_today, has_today, has_tomorrow, button: "today"\|"tomorrow", previous_date?: string }` |
| `GET /api/daily?date=YYYY-MM-DD` | Todos with `daily_date = date` |
| `POST /api/daily/create` | Body `{ "local_today": "YYYY-MM-DD", "for": "today"\|"tomorrow" }` — apply Create rules; idempotent if target exists |
| `POST /api/todos/{id}/daily` | Body `{ "date": "YYYY-MM-DD" \| null }` — pull or remove |
| Todo JSON | Add `daily_date`, `carried_from` (`Option<String>`) |

Existing CRUD/toggle/WS continue; broadcasts include the new fields.

## Migration

1. `ALTER TABLE todos ADD COLUMN daily_date TEXT;`
2. `ALTER TABLE todos ADD COLUMN carried_from TEXT;`
3. `CREATE TABLE daily_days (...)`
4. Existing rows: both new columns NULL; no `daily_days` → Daily empty until first Create.

## Success criteria

1. Create today carries incompletes from prior daily date (if any) and shows them on Daily.
2. Pull from General → same `id` on Daily and General; complete once → done in both.
3. Create tomorrow moves incompletes off today onto tomorrow with carried-from hint.
4. When calendar today equals a created daily date, Daily mode shows that board.
5. Empty Create (nothing to carry) still creates the day so the board exists.

## Open implementation notes

- Prefer server-side date arithmetic with the client-provided `local_today` string (no TZ DB required).
- WS payload shape: extend existing todo event JSON; no new event type required for v1.
- Archive/show-completed filters for Daily follow the same conventions as General lists where applicable.
