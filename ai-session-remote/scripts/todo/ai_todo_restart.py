"""`ai-todo-status restart`: end one conversation's CLI cleanly so it starts again on the
installed version, with new MCP servers or tooling (Claude in Chrome), the same conversation
in the same folder. Only ever run for one conversation the user picked.

    restart <tmux name> <session id> <tool> [--force] [--chrome on|off|default]
            [--reopen <cwd> [--mcp <names>] [--worktree <folder> <branch>]]

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
"""
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import time

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


def restart(name, sid, tool, force=False, chrome="keep", cwd=None, mcp=None, worktree=None):
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


def main(args):
    if len(args) < 3:
        return 64, None
    name, sid, tool, rest = args[0], args[1], args[2], args[3:]
    options = {"force": False, "chrome": "keep", "cwd": None, "mcp": None, "worktree": None}
    while rest:
        if rest[0] == "--force":
            options["force"], rest = True, rest[1:]
        elif rest[0] == "--chrome" and len(rest) >= 2 and rest[1] in ("on", "off", "default"):
            options["chrome"], rest = rest[1], rest[2:]
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
