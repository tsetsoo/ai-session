"""`ai-todo-status restart`: end one conversation's CLI cleanly so it starts again on the
installed version, with new MCP servers or tooling (Claude in Chrome), the same conversation
in the same folder. Only ever run for one conversation the user picked.

    restart <tmux name> <session id> <tool> [--force] [--chrome on|off|default]
            [--search on|off] [--reopen <cwd> [--mcp <names>] [--worktree <folder> <branch>]]

1. It refuses (exit 75) while the conversation is working, waiting for an answer or an
   approval, has Claude background tasks, or its state can't be read. --force restarts
   anyway (the app asks the user first); background tasks still refuse, they would be lost.
2. It ends the CLI with SIGTERM (SIGKILL after 10 s): its transcript is already on disk, and
   nothing in the folder or worktree is touched. Text typed but not sent is lost.
3. Codex: it waits for the conversation's writer lock. The conversation's own backend is
   replaced when it next opens if it is idle and older (terminal()).
4. With --reopen it starts it again detached through ai-todo-open (the same session id and
   tmux name, so never a second copy), then reports the version it now runs. Without it the
   app reattaches, which resumes it the same way. --worktree (the conversation's own
   worktree) goes to ai-todo-open, which makes the worktree again if it was deleted.

A failure after the stop leaves a saved conversation: opening it again resumes it.
Prints one JSON object; exit 0 done, 75 refused, 1 failed.

`ai-todo-status close-unused [--dry-run]` (the runner, every 10 minutes): ends the
ai/<tool>/todo-* sessions whose todo is archived (done more than a day ago) or deleted,
i.e. not among this computer's conversations on the hub. Only when the hub answered, only
sessions nobody typed into, attached to or ran a turn in for UNUSED_IDLE_S, and only through the
same refusals as a restart (never forced); sessions it can't check are left. Opening the
todo again resumes the conversation.
"""
import http.client
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request

import ai_todo_doctor as doctor
import ai_todo_launch as launch
import ai_todo_status as status

REFUSED = 75
STOP_WAIT_S = 10
LOCK_WAIT_S = 10
OPEN_TIMEOUT_S = 90
WORKTREE_OPEN_TIMEOUT_S = 240  # making a deleted worktree again can take a while in a big repo
MESSAGES = {
    "busy": "It's working on a turn.",
    "waiting": "It's waiting for your answer or approval.",
    "unknown": "Its state can't be read, so it may be working.",
    "background": "It has background tasks running, which a restart would end.",
}


def conversation_state(tool, sid):
    """{"state": busy | waiting | idle | unknown, "tasks": n}: the cautious one of the last
    published state and the live runtime's, waiting before busy before idle."""
    record = status.read_json(status.root() / (("claude." if tool == "claude" else "") + sid + ".json"), {}) or {}
    body = record.get("body") if isinstance(record.get("body"), dict) else {}
    seen = [body.get("status")]
    if tool in ("claude", "codex"):
        live = status.fresh_runtime_state(sid, tool)
        if live:
            seen.append(live[1][0] if isinstance(live[1], (list, tuple)) and live[1] else None)
    state = next((s for s in ("waiting", "busy", "idle") if s in seen), "unknown")
    tasks = (record.get("claude_turn") or {}).get("tasks") if tool == "claude" else None
    return {"state": state, "tasks": len(tasks) if isinstance(tasks, list) else 0}


def tmux_args():
    tmux = next((c for c in [shutil.which("tmux"), "/opt/homebrew/bin/tmux", "/usr/local/bin/tmux",
                             "/home/linuxbrew/.linuxbrew/bin/tmux"] if c and os.path.isfile(c)), None)
    if not tmux:
        raise OSError("tmux not found")
    socket_name = os.environ.get("AI_TODO_TMUX_SOCKET")
    return [tmux] + (["-L", socket_name] if socket_name else [])


def session_exists(name):
    return subprocess.run(tmux_args() + ["has-session", "-t", "=" + name], capture_output=True, timeout=5).returncode == 0


def running_entry(name):
    """This session's entry from the doctor's running list, or None."""
    sessions = doctor.panes()
    if not sessions or name not in sessions:
        return None
    found = doctor.running_report({}, sessions={name: sessions[name]})
    return found[0] if found else None


def alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    # A child of ours that exited is a zombie until reaped; ps says so.
    state = subprocess.run(["ps", "-p", str(pid), "-o", "stat="], capture_output=True, text=True).stdout.strip()
    return bool(state) and not state.startswith("Z")


def stop(name, entry, wait_s=None):
    """SIGTERM the CLI, SIGKILL it after `wait_s` (STOP_WAIT_S), then end the tmux session."""
    wait_s = STOP_WAIT_S if wait_s is None else wait_s
    pid = entry.get("pid") if entry else None
    if isinstance(pid, int):
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        deadline = time.monotonic() + wait_s
        while alive(pid) and time.monotonic() < deadline:
            time.sleep(0.1)
        if alive(pid):
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
    subprocess.run(tmux_args() + ["kill-session", "-t", "=" + name], capture_output=True, timeout=5)


def wait_for_writer(name, sid, wait_s=None):
    """None once nothing else holds the Codex conversation's writer lock, else who does."""
    wait_s = LOCK_WAIT_S if wait_s is None else wait_s
    deadline = time.monotonic() + wait_s
    while True:
        conflict = status.writer_conflict(name, sid)
        if not conflict or time.monotonic() >= deadline:
            return conflict
        time.sleep(0.2)


def installed_version(tool):
    finder = {"claude": status.find_claude, "codex": status.find_codex, "cursor": doctor.find_cursor}[tool]
    try:
        binary = finder()
    except FileNotFoundError:
        return None
    return doctor.path_version(os.path.realpath(binary))


def reopen(name, cwd, sid, tool, mcp, worktree=None):
    open_bin = os.environ.get("AI_TODO_OPEN_BIN") or str(Path(__file__).with_name("ai-todo-open"))
    argv = [open_bin, "--detached"] + (["--mcp", mcp] if mcp is not None and tool != "cursor" else []) \
        + (["--worktree", worktree[0], worktree[1]] if worktree else []) + [name, cwd, sid, tool]
    result = subprocess.run(argv, capture_output=True, text=True, stdin=subprocess.DEVNULL,
                            timeout=WORKTREE_OPEN_TIMEOUT_S if worktree else OPEN_TIMEOUT_S)
    if result.returncode:
        error = RuntimeError((result.stderr or "").strip()[:300].rstrip(".") or "ai-todo-open exit %d" % result.returncode)
        error.code = result.returncode
        raise error
    return (result.stdout or "").strip()


def restart(name, sid, tool, force=False, chrome="keep", cwd=None, mcp=None, worktree=None, search="keep"):
    """The steps in the module's docstring; returns (exit code, result)."""
    if tool not in ("claude", "codex", "cursor") or not name.startswith("ai/%s/todo-" % tool):
        raise ValueError("invalid tmux name or tool")
    launch.record_path(tool, sid)  # validates the id
    result = {"tmux": name, "session_id": sid, "tool": tool}
    running = session_exists(name)
    entry = running_entry(name) if running else None
    result["before"] = entry.get("version") if entry else None
    if running and not entry and not force:
        # A session whose CLI the doctor can't find (starting, or behind a wrapper) can't be
        # read either: it may be in a turn.
        return REFUSED, dict(result, result="refused", reason="unknown", message=MESSAGES["unknown"])
    if running and entry:
        state = conversation_state(tool, sid)
        result["state"] = state["state"]
        if state["tasks"]:
            return REFUSED, dict(result, result="refused", reason="background", message=MESSAGES["background"])
        if state["state"] != "idle" and not force:
            return REFUSED, dict(result, result="refused", reason=state["state"], message=MESSAGES[state["state"]])
    if chrome != "keep" and tool == "claude":
        launch.update(tool, sid, chrome={"on": True, "off": False, "default": None}[chrome])
    if search != "keep" and tool == "codex":
        launch.update(tool, sid, search=search == "on")
    if running:
        stop(name, entry)
    result["stopped"] = running
    if tool == "codex":
        conflict = wait_for_writer(name, sid)
        if conflict:
            return 1, dict(result, result="failed", stage="writer", message=conflict)
    if cwd is None:
        return 0, dict(result, result="stopped")
    try:
        result["mode"] = reopen(name, cwd, sid, tool, mcp, worktree)
    except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
        # 94: there is nothing to resume (a Codex conversation with no message yet); the
        # helper's own words say what to do. Anything else: the conversation is saved.
        cannot_resume = getattr(error, "code", None) == 94
        message = ("Starting it again failed: %s." % error) if cannot_resume else \
            ("Starting it again failed: %s. It's saved: open it again." % error)
        return 1, dict(result, result="failed", stage="reopen", message=message)
    after = None
    for _ in range(30):  # the CLI shows up in the pane a moment after tmux starts it
        after = running_entry(name)
        if after and after.get("version"):
            break
        time.sleep(0.2)
    result["after"] = after.get("version") if after else None
    result["installed"] = installed_version(tool)
    return 0, dict(result, result="restarted")


UNUSED_IDLE_S = 6 * 3600
SESSION_PREFIXES = ("ai/claude/todo-", "ai/codex/todo-", "ai/cursor/todo-")


def hub_get(path, timeout=10):
    """GET a hub path as JSON, or None when the hub can't be asked."""
    try:
        url, token = status.configuration()
    except (OSError, ValueError):
        return None
    request = urllib.request.Request(url + path, headers={"Authorization": "Bearer " + token} if token else {})
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return json.loads(response.read().decode())
    except (OSError, ValueError, urllib.error.URLError, http.client.HTTPException):
        return None


def hub_view():
    """{"linked": tmux names of this computer's listed conversations, "open": ids of the
    todos the hub still lists}, or None when that can't be known for sure: the hub didn't
    answer, there's no TODO_COMPUTER_ID, or the hub lists no conversation of this computer
    (a reset hub or a wrong id would otherwise make every session look unused)."""
    try:
        computer = os.environ.get("TODO_COMPUTER_ID") or status.hub_values().get("TODO_COMPUTER_ID")
    except (OSError, ValueError):
        return None
    if not computer:
        return None
    conversations = hub_get("/api/conversations")
    todos = hub_get("/api/todos")
    if not isinstance(conversations, list) or not isinstance(todos, list):
        return None
    linked = {c.get("tmux_name") for c in conversations
              if isinstance(c, dict) and c.get("tmux_name") and (c.get("computer") or {}).get("id") == computer}
    if not linked:
        return None
    return {"linked": linked, "open": {t.get("id") for t in todos if isinstance(t, dict) and t.get("id")}}


def session_info():
    """{session name: {"activity": epoch s, "attached": bool}}, or None when tmux can't be
    asked. tmux moves a session's activity when someone types into it or attaches; the
    screen's own output can't be used, since an idle Claude redraws now and then."""
    try:
        listed = subprocess.run(tmux_args() + ["list-sessions", "-F", "#{session_name}\t#{session_activity}\t#{session_attached}"],
                                capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if listed.returncode:
        return {} if "no server running" in listed.stderr or "error connecting" in listed.stderr else None
    result = {}
    for line in listed.stdout.splitlines():
        parts = line.rsplit("\t", 2)
        if len(parts) == 3 and parts[1].isdigit():
            result[parts[0]] = {"activity": int(parts[1]), "attached": parts[2] not in ("", "0")}
    return result


def transcript_time(tool, sid):
    """When the conversation's transcript last changed (a turn ran), or None when it can't
    be found: every turn, typed or sent from the app, writes it."""
    path = launch.claude_transcript(sid) if tool == "claude" else status.codex_rollout(sid) if tool == "codex" else None
    try:
        return os.stat(path).st_mtime if path else None
    except OSError:
        return None


def close_unused(hub, now=None, dry_run=False, idle_s=None):
    """End the long-idle sessions of archived or deleted todos (see the module docstring).
    Idle means nobody typed or attached and no turn ran for `idle_s`. Kept: a listed
    conversation's, an open todo's (one whose conversation was replaced), attached ones, and
    any it can't check: no conversation id or transcript, working, waiting, background tasks
    or an unreadable state. Never forced."""
    now = time.time() if now is None else now
    idle_s = UNUSED_IDLE_S if idle_s is None else idle_s
    sessions = session_info() or {}
    candidates = [name for name in sorted(sessions)
                  if name.startswith(SESSION_PREFIXES) and name not in hub["linked"]
                  and not sessions[name]["attached"] and now - sessions[name]["activity"] >= idle_s]
    panes = doctor.panes() or {}
    entries = {e.get("tmux"): e for e in doctor.running_report({}, sessions={n: panes[n] for n in candidates if n in panes})}
    closed, left = [], []
    for name in candidates:
        tool = name.split("/")[1]
        slug = name.split("todo-", 1)[1][:8]
        if any(todo.startswith(slug) for todo in hub["open"]):
            left.append({"tmux": name, "reason": "open todo"})
            continue
        entry = entries.get(name)
        sid = entry.get("session_id") if entry else None
        written = transcript_time(tool, sid) if sid else None
        if written is None:
            # No CLI found, one started fresh (its id isn't on its command line) or no
            # transcript: when it last worked can't be told, so it may be working.
            left.append({"tmux": name, "reason": "unknown"})
            continue
        if now - written < idle_s:
            continue  # a turn ran lately
        state = conversation_state(tool, sid)
        reason = "background" if state["tasks"] else (None if state["state"] == "idle" else state["state"])
        if reason:
            left.append({"tmux": name, "reason": reason})
            continue
        if not dry_run:
            stop(name, entry)
        closed.append(name)
    return {"closed": closed, "left": left, "dry_run": dry_run}


def close_unused_main(args):
    if args not in ([], ["--dry-run"]):
        return 64, None
    hub = hub_view()
    if hub is None:
        return 1, {"closed": [], "left": [], "error": "the hub's conversations couldn't be read for this computer"}
    return 0, close_unused(hub, dry_run=bool(args))


def main(args):
    if len(args) < 3:
        return 64, None
    name, sid, tool, rest = args[0], args[1], args[2], args[3:]
    options = {"force": False, "chrome": "keep", "cwd": None, "mcp": None, "worktree": None, "search": "keep"}
    while rest:
        if rest[0] == "--force":
            options["force"], rest = True, rest[1:]
        elif rest[0] == "--chrome" and len(rest) >= 2 and rest[1] in ("on", "off", "default"):
            options["chrome"], rest = rest[1], rest[2:]
        elif rest[0] == "--search" and len(rest) >= 2 and rest[1] in ("on", "off"):
            options["search"], rest = rest[1], rest[2:]
        elif rest[0] == "--reopen" and len(rest) >= 2:
            options["cwd"], rest = rest[1], rest[2:]
        elif rest[0] == "--mcp" and len(rest) >= 2:
            options["mcp"], rest = rest[1], rest[2:]
        elif rest[0] == "--worktree" and len(rest) >= 3 and rest[1] and rest[2]:
            options["worktree"], rest = (rest[1], rest[2]), rest[3:]
        else:
            return 64, None
    if (options["mcp"] is not None or options["worktree"]) and options["cwd"] is None:
        return 64, None  # --mcp and --worktree only mean something when this reopens it
    code, result = restart(name, sid, tool, **options)
    return code, result
