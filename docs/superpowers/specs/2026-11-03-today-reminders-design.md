# Stage 4: Today, reminders, people & dates, morning briefing

Stage 4 of the scheduler (`2026-11-02-scheduler-design.md`, section 7), with the user's decisions
of 2026-11-03. Where they differ, this document wins.

## Intent

The user wants the hub to remind them of everyday things and people's dates, and to start the
day with one short summary of what the automation did and what needs them. Getting things in
must be easy: by hand, or by telling a cheap agent loosely and letting it ask what's unclear.

## User's decisions

- **Two ways in:** a form by hand, or "Add with an agent": a **short conversation** with a
  cheap model that reads some context, asks qualifying questions, then creates the items.
- **A new tab:** Today is its own place, a third mode on the Mac next to Sessions and
  Automation, and its own tab on the iPhone.
- **Today does not show daily todos.**
- From the main spec: reminders have a title, time and repeat; people & dates have a name, kind,
  date (year optional) and notes; the briefing is computed on the hub, with no model call;
  Europe/Sofia time; reminders follow quiet hours (delivered when they end).

## Design

### Reminders

- Fields: title, notes (optional), next time (date + time, Sofia), repeat: none, daily, weekdays,
  weekly, monthly, yearly.
- At its time the hub pushes it (silent push held until quiet hours end, if any are set). The
  reminder then waits as **due** until the user marks it **Done** or **Snoozes** it (1 hour,
  this evening 18:00, tomorrow 09:00). Done on a repeating reminder moves it to its next time.
  *My call:* a reminder stays visible until handled, like a todo.
- A monthly reminder on the 31st falls on the month's last day.

### People & dates

- Fields: name, kind (birthday, anniversary, other), month and day, year (optional), notes.
- Pushes at 09:00 Sofia the day before ("Tomorrow: Maria's birthday") and on the day ("Today:
  Maria turns 35" when the year is known). 29 February falls on 28 February in other years.

### Morning briefing

- A push at a user-set time (default 08:00; off is allowed), held until quiet hours end.
- It lists, in this order and only what's non-empty: today's reminders, today's and tomorrow's
  dates, scheduled conversations that finished since the last briefing and are Ready for review,
  how many conversations need the user, open watcher issues by group. Nothing at all → no push.
- The **Today** view shows the same, live, each line opening its thing.

### Add with an agent

- A button in Reminders and People ("Add with an agent") opens a sheet for a starting text,
  then starts a short conversation, like "Shape an idea".
- It runs with **Claude Haiku** (`claude --model haiku`). *My call:* the cheap model the user
  asked for; one setting on the hub if it needs changing.
- Where: a hub project **Personal** in section P (this Mac), folder `~/.ai-remote/assistant`
  (created by install.sh, not a git repo). The conversation runs there in place.
  `install.sh` writes `~/.ai-remote/assistant/.claude/settings.json` allowing only
  `~/.ai-remote/bin/ai-todo-remind`, so creating items doesn't stop for a permission prompt.
  *My call:* a plain folder, so no worktree per chat.
- Its prompt gives today's date and weekday, the starting text (as data), and how to use the
  helper. The agent can list existing reminders and people for context, asks at most a few short
  questions, creates the items, says what it created, and stops.
- The helper `ai-todo-remind`: `list`, `add "<title>" --at "YYYY-MM-DD HH:MM" [--repeat …]
  [--notes …]`, `person "<name>" --kind birthday --date MM-DD [--year YYYY] [--notes …]`. Items
  an agent creates are saved directly (the user asked), marked `source: agent`.
- These conversations are urgent (they push when they need the user) and are closed after an
  idle day like other conversations. *My call.*

### The app

- Mac: mode switch Sessions / Automation / **Today** (⌃⌘3). Today's sidebar: **Today**,
  **Reminders**, **People**. iPhone: a **Today** tab with the same three.
- Today: the briefing's sections; reminders due now on top with Done and Snooze.
- Reminders: upcoming and due, a form (new/edit/delete), Add with an agent.
- People: sorted by next date, a form, Add with an agent.
- Briefing settings (time, on/off) at the top of Today.
- The briefing push and reminder pushes open Today.

## Non-goals

- Daily todos in Today. Calendar or Contacts import. Location reminders.
- A model call on the hub.

## Left to the builder

Tables and endpoints, snooze option wording, layout, the exact agent prompt, where the hub's
clock sends these pushes (the existing scheduler tick), tests.
