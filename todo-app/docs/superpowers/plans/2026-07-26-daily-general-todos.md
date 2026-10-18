# Daily + General Todos Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add dated Daily boards and General backlog with pull-to-daily, create-today/tomorrow carry-forward, and shared completion.

**Architecture:** Additive `daily_date` / `carried_from` on todos plus `daily_days` table; new `/api/daily/*` and `/api/todos/{id}/daily` endpoints; frontend top-level Daily | General modes.

**Tech Stack:** Rust (actix, rusqlite, leptos), existing WS refresh broadcast.

**Spec:** `docs/superpowers/specs/2026-07-26-daily-general-todos-design.md`

## Global Constraints

- Client sends `local_today` (YYYY-MM-DD) for status/create
- Create today vs tomorrow button rules per spec
- Pull requires today’s board (409 otherwise); targets today
- Same todo id in Daily + General; complete is global
- Carry only incompletes; Create still inserts `daily_days` when empty
- Create tomorrow moves incompletes off today immediately

## File Structure

| Path | Role |
|---|---|
| `crates/todo-shared/src/lib.rs` | Todo fields + Daily DTOs |
| `crates/todo-server/src/db.rs` | Migrations |
| `crates/todo-server/src/models.rs` | row_to_todo |
| `crates/todo-server/src/daily.rs` | Daily handlers + date helpers |
| `crates/todo-server/src/handlers.rs` | SELECT_COLS, clear carried_from on complete |
| `crates/todo-server/src/main.rs` | Routes |
| `crates/todo-frontend/src/api.rs` | Client calls |
| `crates/todo-frontend/src/components/daily_view.rs` | Daily UI |
| `crates/todo-frontend/src/app.rs` | Daily \| General nav |
| `crates/todo-frontend/src/components/todo_item.rs` | Badge + Add/Remove Daily |
| `crates/todo-server/tests/daily_api.rs` | Integration tests |

---

### Task 1: Shared types + DB migration + server daily API

**Files:** shared lib, db, models, new `daily.rs`, handlers, main

- [ ] Add `daily_date`, `carried_from` to `Todo`; add `DailyStatus`, `CreateDailyRequest`, `SetTodoDailyRequest`
- [ ] Migrate columns + `daily_days` table
- [ ] Implement status / list / create / set-daily handlers with carry logic
- [ ] Update SELECT_COLS + row_to_todo; clear `carried_from` when completing
- [ ] Wire routes; add integration tests with tempfile DB
- [ ] Commit

### Task 2: Frontend Daily mode + General pull UI

**Files:** api.rs, daily_view.rs, app.rs, todo_item.rs, mod.rs, CSS as needed

- [ ] API helpers + `local_today()` in JS/wasm
- [ ] DailyView with create button, list, carried-from, remove from daily
- [ ] App: Daily | General; nest existing views under General
- [ ] TodoItem: on-daily badge, Add to Daily when board exists
- [ ] Commit

### Task 3: Verify build + smoke

- [ ] `cargo test -p todo-server`, clippy on touched crates, trunk/frontend compile if feasible
- [ ] Commit any fixes
