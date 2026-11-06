"""Resume a conversation once its usage limit resets.

The status publisher (ai_todo_status.publish) leaves a small file per paused conversation in
<status dir>/resume/ and removes it when the pause ends (a new turn, another status, or
Claude's own auto-continue). The status service's resume loop (tick) works through them:

- Claude, session (5-hour) limit: nothing. Claude continues on its own once the limit resets
  (its autoContinueAtUsageLimit), so no entry is kept for it.
- Codex, session (5-hour) limit with the conversation's toggle on: at reset + 2 min (+ up to 90 s,
  fixed per conversation) it checks the conversation, takes the hub's lease, and types
  ESC, "The usage limit has reset; continue where you left off." and Enter into its tmux
  session. Before that it tells the hub the planned time every minute (the apps show it).
- weekly or unknown limit, a reset missed by more than 12 hours, or the 3-a-day cap: the hub
  offers a one-tap Resume instead (`ai-todo-status resume <tool> <id>` runs it).
- no reset time: ai-todo-limits names the exhausted window's reset; else it backs off
  5, 15, then 30 minutes, then offers.

It never answers a question card, never types over a draft, and never sends a push.
Network and tmux calls happen outside the session lock; the hub's lease decides who types.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time
import urllib.error
import urllib.request
import uuid
from datetime import datetime, timezone

import ai_todo_status as status

TEXT = "The usage limit has reset; continue where you left off."
GRACE_S = 120
JITTER_S = 90
MISSED_S = 12 * 3600
BACKOFF_S = (5 * 60, 15 * 60, 30 * 60)
ARM_EVERY_S = 60
RETRY_S = 5 * 60
REOPEN_WAIT_S = 90
# Keys typed right after a client attaches are the app's own terminal replies, not you.
ATTACH_SETTLE_S = 5
# Input this recent means you are at the conversation: wait rather than type over you.
ACTIVE_S = 120


# --- Entries -------------------------------------------------------------------------

def directory():
    return status.root() / "resume"


def entry_path(tool, sid):
    return directory() / (tool + "." + sid + ".json")


def claude_continues(tool, kind):
    return tool == "claude" and kind == "session"


def note_pause(tool, sid, pause, observed_ns):
    """A new pause (called by publish, under its session lock)."""
    if claude_continues(tool, pause.get("kind")):
        forget(tool, sid, "claude_continues")
        return
    entry = {"tool": tool, "session_id": sid, "kind": pause.get("kind"), "resets_at": pause.get("resets_at"),
             "paused_ns": int(observed_ns), "tries": 0}
    status.atomic_json(entry_path(tool, sid), entry)
    log("paused", tool, sid, kind=entry["kind"], resets_at=entry["resets_at"])


def forget(tool, sid, why=None):
    """The pause is over (called by publish, under its session lock)."""
    path = entry_path(tool, sid)
    if path.exists():
        path.unlink(missing_ok=True)
        log("forgot", tool, sid, why=why)


def entries():
    found = []
    for path in sorted(directory().glob("*.json")):
        entry = status.read_json(path)
        if isinstance(entry, dict) and entry.get("tool") in ("claude", "codex") and isinstance(entry.get("session_id"), str):
            found.append(entry)
    return found


def save(entry):
    """Write back the loop's changes unless publish replaced or removed the entry meanwhile."""
    tool, sid = entry["tool"], entry["session_id"]
    with status.session_lock(sid, tool=tool):
        current = status.read_json(entry_path(tool, sid))
        if current and current.get("paused_ns") == entry.get("paused_ns"):
            status.atomic_json(entry_path(tool, sid), entry)


def undelivered(entry, now):
    """The pause may not have reached the hub yet: its outbox record is still pending, or it is
    under a minute old. The hub saying "not paused" then means nothing yet."""
    tool, sid = entry["tool"], entry["session_id"]
    record = status.read_json(status.root() / (("claude." if tool == "claude" else "") + sid + ".json"), {})
    young = now - entry["paused_ns"] / 1e9 < 60
    return bool(record.get("pending")) or young


def drop(entry, why):
    tool, sid = entry["tool"], entry["session_id"]
    with status.session_lock(sid, tool=tool):
        current = status.read_json(entry_path(tool, sid))
        if current and current.get("paused_ns") == entry.get("paused_ns"):
            forget(tool, sid, why)


def log(event, tool, sid, **fields):
    """Ids and outcomes only: never conversation text."""
    try:
        line = {"at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"), "event": event, "tool": tool,
                "session": (sid or "")[:8]}
        line.update({k: v for k, v in fields.items() if v is not None})
        path = status.root() / "resume.log"
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        if path.exists() and path.stat().st_size > 512 * 1024:
            path.replace(path.with_suffix(".log.1"))
        with open(path, "a") as handle:
            handle.write(json.dumps(line, separators=(",", ":")) + "\n")
    except OSError:
        pass


# --- Times ---------------------------------------------------------------------------

def epoch(iso):
    if not isinstance(iso, str):
        return None
    try:
        return datetime.fromisoformat(iso.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def iso(seconds):
    return datetime.fromtimestamp(seconds, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def jitter(sid):
    return int(hashlib.sha256(sid.encode()).hexdigest()[:8], 16) % (JITTER_S + 1)


def due(entry):
    """When to act: after the reset, or the next back-off step without one."""
    if entry.get("next_at"):
        return entry["next_at"]
    reset = epoch(entry.get("resets_at"))
    if reset is not None:
        return reset + GRACE_S + jitter(entry["session_id"])
    step = BACKOFF_S[min(entry.get("tries", 0), len(BACKOFF_S) - 1)]
    return entry["paused_ns"] / 1e9 + sum(BACKOFF_S[:min(entry.get("tries", 0), len(BACKOFF_S) - 1)]) + step


# --- Hub -----------------------------------------------------------------------------

class HubUnavailable(Exception):
    pass


def hub(action, tool, sid, **extra):
    """The hub's resume state after `action`, or None for a conversation it doesn't know."""
    body = dict(extra, tool=tool, session_id=sid, action=action)
    try:
        url, token = status.configuration()
        headers = {"Content-Type": "application/json"}
        if token:
            headers["Authorization"] = "Bearer " + token
        request = urllib.request.Request(url + "/api/conversations/resume", data=json.dumps(body).encode(), headers=headers)
        with urllib.request.urlopen(request, timeout=10) as response:
            return json.loads(response.read() or b"{}")
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return None
        raise HubUnavailable("HTTP " + str(error.code))
    except (OSError, ValueError) as error:
        raise HubUnavailable(type(error).__name__)


# --- Usage limits --------------------------------------------------------------------

def limits_bin():
    return os.environ.get("AI_TODO_LIMITS_BIN", str(Path.home() / ".ai-remote" / "bin" / "ai-todo-limits"))


def limit_windows(tool, sid):
    try:
        done = subprocess.run([limits_bin(), "--tool", tool, "--session", sid], capture_output=True, text=True,
                              timeout=30, stdin=subprocess.DEVNULL)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if done.returncode != 0:
        return None
    try:
        windows = json.loads(done.stdout).get("windows")
    except (ValueError, AttributeError):
        return None
    return windows if isinstance(windows, list) else None


def headroom(windows, now):
    """("ok" | "blocked" | "unknown", the blocking reset in epoch seconds). A full window whose
    reset has passed counts as reset: Codex's reading is its last snapshot."""
    if not windows:
        return "unknown", None
    blocked = None
    for window in windows:
        if not isinstance(window, dict) or window.get("kind") not in ("5h", "weekly"):
            continue
        used = window.get("used_percent")
        if not isinstance(used, (int, float)) or used < 100:
            continue
        reset = epoch(window.get("resets_at"))
        if reset is None or reset > now:
            blocked = max(blocked or 0, reset or 0)
    if blocked is not None:
        return "blocked", blocked or None
    return "ok", None


# --- tmux ----------------------------------------------------------------------------

def tmux_bin():
    configured = os.environ.get("AI_TODO_TMUX")
    if configured:
        return configured
    for candidate in ("/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/home/linuxbrew/.linuxbrew/bin/tmux"):
        if os.access(candidate, os.X_OK):
            return candidate
    return shutil.which("tmux") or "tmux"


def tmux(*args, timeout=10):
    socket = os.environ.get("AI_TODO_TMUX_SOCKET")
    command = [tmux_bin()] + (["-L", socket] if socket else []) + list(args)
    return subprocess.run(command, capture_output=True, text=True, timeout=timeout, stdin=subprocess.DEVNULL)


def agent_pane(name):
    """The pane the tool runs in: the session's first pane (ai-todo-open starts it there), not
    the active one, where a shell opened beside it would take the message as a command."""
    try:
        done = tmux("list-panes", "-s", "-t", "=" + name, "-F", "#{window_index} #{pane_index} #{pane_id}")
    except (OSError, subprocess.TimeoutExpired):
        return None
    rows = []
    for line in done.stdout.splitlines():
        parts = line.split()
        if len(parts) == 3 and parts[0].isdigit() and parts[1].isdigit():
            rows.append((int(parts[0]), int(parts[1]), parts[2]))
    return min(rows)[2] if done.returncode == 0 and rows else None


def session_exists(name):
    try:
        return tmux("has-session", "-t", "=" + name).returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def typed_since(name, since):
    """Input from a client of this session after `since` (epoch seconds) and within the last
    ACTIVE_S: you are there now. Older input (scrolling to read it, say) doesn't count."""
    since = max(since, time.time() - ACTIVE_S)
    try:
        done = tmux("list-clients", "-t", "=" + name, "-F", "#{client_activity} #{client_created}")
    except (OSError, subprocess.TimeoutExpired):
        return False
    for line in done.stdout.splitlines():
        try:
            activity, created = (int(x) for x in line.split()[:2])
        except ValueError:
            continue
        if activity > since and activity > created + ATTACH_SETTLE_S:
            return True
    return False


def capture(name):
    pane = agent_pane(name)
    if pane is None:
        return None
    try:
        done = tmux("capture-pane", "-p", "-e", "-t", pane)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return done.stdout.split("\n") if done.returncode == 0 else None


def type_resume(name):
    pane = agent_pane(name)
    if pane is None:
        raise OSError("no pane")
    for args in (("Escape",), ("-l", TEXT), ("Enter",)):
        done = tmux("send-keys", "-t", pane, *args)
        if done.returncode != 0:
            raise OSError("tmux send-keys failed")
        time.sleep(0.4)


# --- The screen ----------------------------------------------------------------------

_ESCAPE = re.compile(r"\x1b\[([0-9;:?]*)([A-Za-z])|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b[@-Z\\-_]")
_BOX = "│╭╮╰╯┌┐└┘"


def _faint(params, faint):
    """Whether text after this SGR is a placeholder: dim, or grey (older Claude, 246)."""
    codes = [p for p in params.replace(":", ";").split(";")]
    i = 0
    while i < len(codes):
        code = codes[i] or "0"
        if code in ("0", "22", "39"):
            faint = False
        elif code in ("2", "90"):
            faint = True
        elif code == "38" and i + 2 < len(codes) and codes[i + 1] == "5":
            faint = codes[i + 2].isdigit() and 240 <= int(codes[i + 2]) <= 250
            i += 2
        elif code == "38" and i + 4 < len(codes) and codes[i + 1] == "2":
            i += 4
        elif code in ("48",) and i + 2 < len(codes) and codes[i + 1] == "5":
            i += 2
        elif code in ("48",) and i + 4 < len(codes) and codes[i + 1] == "2":
            i += 4
        elif code.isdigit() and (30 <= int(code) <= 37 or 91 <= int(code) <= 97):
            faint = False
        i += 1
    return faint


def styled(line):
    """(all text, the text not drawn faint)."""
    plain, firm, faint, at = [], [], False, 0
    for match in _ESCAPE.finditer(line):
        text = line[at:match.start()]
        plain.append(text)
        if not faint:
            firm.append(text)
        if match.group(2) == "m":
            faint = _faint(match.group(1), faint)
        at = match.end()
    plain.append(line[at:])
    if not faint:
        firm.append(line[at:])
    return "".join(plain), "".join(firm)


def _clean(line):
    for box in _BOX:
        line = line.replace(box, " ")
    return line.rstrip()


def _rule(line, solid=False):
    trimmed = line.strip()
    return bool(trimmed) and all(c in ("─" if solid else "─╌━═") for c in trimmed)


_OPTION = re.compile(r"^\s*([❯›>])?\s*(\d+)\.\s+(.*)$")


def question_card(screen):
    """A Claude or Codex question on screen: Python port of the phone's TerminalPrompt.parse
    (Sources/AISessionCore/Chat/TerminalPrompt.swift), tested on the same captures."""
    lines = [_clean(line) for line in screen]
    hint = next((i for i in range(len(lines) - 1, -1, -1) if lines[i] and not _rule(lines[i])), None)
    if hint is None or not re.search(r"(?i)\besc\b", lines[hint]):
        return False
    footer = hint if not _OPTION.match(lines[hint]) else hint + 1
    first = None
    row = footer - 1
    while row >= 0:
        line = lines[row]
        if not line or _rule(line):
            row -= 1
            continue
        option = _OPTION.match(line)
        if option:
            if int(option.group(2)) == 1:
                first = row
                break
        elif len(line) - len(line.lstrip(" ")) < 4:
            return False
        row -= 1
    if first is None:
        return False
    options = [_OPTION.match(line) for line in lines[first:footer] if line and not _rule(line)]
    numbers = [int(o.group(2)) for o in options if o]
    if len(numbers) < 2 or numbers != list(range(1, len(numbers) + 1)):
        return False
    if sum(1 for o in options if o and o.group(1)) != 1:
        return False
    # A question line ending in "?" above the options, up to a rule, two blanks or a transcript line.
    row = first - 1
    while row >= 0 and not lines[row]:
        row -= 1
    blanks = 0
    while row >= 0:
        line = lines[row]
        if not line:
            blanks += 1
            if blanks == 2:
                break
        else:
            blanks = 0
            trimmed = line.strip()
            if _rule(line, solid=True) or (trimmed and trimmed[0] in "•⏺✻⎿❯›■✗"):
                break
            if trimmed.endswith("?"):
                return True
        row -= 1
    return False


def input_state(screen):
    """"empty", "draft" (you have typed something), or "none" (no input line found)."""
    for line in reversed(screen):
        plain, firm = styled(line)
        plain, firm = _clean(plain).strip(), _clean(firm).strip()
        for marker in ("❯", "›"):
            if plain.startswith(marker):
                rest = firm[firm.index(marker) + 1:].strip() if marker in firm else firm
                return "draft" if rest else "empty"
        if plain.startswith("> ") or plain == ">":
            return "draft" if firm.lstrip("> ").strip() else "empty"
    return "none"


def screen_ready(name):
    """None when the conversation can take the message, else why not."""
    screen = capture(name)
    if screen is None:
        return "no_session"
    plain = [styled(line)[0] for line in screen]
    if question_card(plain):
        return "question"
    state = input_state(screen)
    if state == "draft":
        return "draft"
    if state == "none":
        return "busy"
    return None


# --- Resuming ------------------------------------------------------------------------

def open_bin():
    return os.environ.get("AI_TODO_OPEN_BIN", str(Path.home() / ".ai-remote" / "bin" / "ai-todo-open"))


def reopen(state, tool, sid):
    """Start the conversation's tmux session again (same id and folder) and wait for its prompt."""
    try:
        subprocess.run([open_bin(), "--detached", state["tmux_name"], state["cwd"], sid, tool],
                       capture_output=True, text=True, timeout=120, stdin=subprocess.DEVNULL)
    except (OSError, subprocess.TimeoutExpired):
        return "no_session"
    deadline = time.monotonic() + REOPEN_WAIT_S
    why = "no_session"
    while time.monotonic() < deadline:
        if session_exists(state["tmux_name"]):
            why = screen_ready(state["tmux_name"])
            if why is None:
                return None
        time.sleep(2)
    return why


def resume(tool, sid, manual, since=None, state=None):
    """Check, lease, check again, type. Returns (typed, reason, retry_at, resets_at): resets_at
    is the blocking window's reset when the limit hasn't reset, if known."""
    now = time.time()
    if state is None:
        state = hub("state", tool, sid)
    if state is None:
        return False, "unknown", None, None
    if state.get("status") == "closed":
        return False, "closed", None, None
    pause = state.get("paused")
    if not pause:
        return False, "not_paused", None, None
    name = state.get("tmux_name") or ""

    def not_now():
        """Why the conversation can't take the message at this moment, if anything."""
        if not manual and since is not None and typed_since(name, since):
            return "typed"
        return screen_ready(name)

    alive = session_exists(name)
    if alive:
        why = not_now()
        if why:
            return False, why, now + RETRY_S, None
    verdict, blocked = headroom(limit_windows(tool, sid), now)
    if verdict == "blocked":
        return False, "limit", (blocked + GRACE_S) if blocked else now + RETRY_S, blocked
    if verdict == "unknown" and epoch(pause.get("resets_at")) is None and not manual:
        return False, "no_reading", now + RETRY_S, None
    token = uuid.uuid4().hex
    claim = hub("claim", tool, sid, token=token, manual=manual)
    if claim is None:
        return False, "unknown", None, None
    if not claim.get("granted"):
        reason = claim.get("reason") or "refused"
        return False, reason, (now + 3 * 60) if reason == "leased" else None, None
    try:
        # Reading the limits and claiming took a while: look again right before typing.
        why = reopen(state, tool, sid) if not alive else not_now()
        if why:
            hub("release", tool, sid, token=token)
            return False, why, time.time() + RETRY_S, None
        type_resume(name)
    except (OSError, subprocess.TimeoutExpired):
        hub("release", tool, sid, token=token)
        return False, "tmux", time.time() + RETRY_S, None
    hub("sent", tool, sid, token=token)
    log("resumed", tool, sid, manual=manual, reopened=not alive)
    return True, None, None, None


def tick_one(entry, now=None):
    """Advance one paused conversation. Returns what happened, for tests and the log."""
    now = time.time() if now is None else now
    tool, sid = entry["tool"], entry["session_id"]
    if claude_continues(tool, entry.get("kind")):
        drop(entry, "claude_continues")
        return "dropped"
    when = due(entry)
    reset = epoch(entry.get("resets_at"))
    if now < when:
        if entry.get("kind") == "session" and now - entry.get("armed_check", 0) >= ARM_EVERY_S:
            state = hub("arm", tool, sid, resume_at=iso(when))
            entry["armed_check"] = now
            if state is None or not state.get("paused"):
                if state is not None and undelivered(entry, now):
                    return "waiting"
                drop(entry, "not_paused")
                return "dropped"
            save(entry)
            return "armed" if state.get("resume_on_reset") else "waiting"
        return "waiting"
    state = hub("state", tool, sid)
    if state is None or not state.get("paused"):
        if state is not None and undelivered(entry, now):
            return "waiting"
        drop(entry, "not_paused")
        return "dropped"
    kind = state["paused"].get("kind")
    if reset is None:
        # No reset time: the limits reading names it, else back off.
        verdict, blocked = headroom(limit_windows(tool, sid), now)
        if verdict == "blocked" and blocked:
            entry.update(resets_at=iso(blocked), next_at=None)
            save(entry)
            return "reset_found"
        if verdict == "unknown" or verdict == "blocked":
            entry["tries"] = entry.get("tries", 0) + 1
            entry["next_at"] = None
            if entry["tries"] >= len(BACKOFF_S):
                hub("offer", tool, sid)
                drop(entry, "offered")
                return "offered"
            save(entry)
            return "backoff"
    missed = reset is not None and now - reset > MISSED_S
    on = state.get("resume_on_reset")
    if not on and kind == "session" and state.get("resume_off_reason") != "cap":
        # Off: nothing is typed. Look again now and then: switching it on still resumes, until
        # the reset is half a day old.
        if missed:
            drop(entry, "toggle_off")
            return "off"
        if (state["paused"] or {}).get("resume_at"):
            hub("disarm", tool, sid)
        entry["next_at"] = now + RETRY_S
        save(entry)
        return "off"
    if kind != "session" or missed or not on:
        hub("offer", tool, sid)
        drop(entry, "offered")
        log("offered", tool, sid, kind=kind, missed=missed or None)
        return "offered"
    typed, reason, retry_at, _ = resume(tool, sid, manual=False, since=entry["paused_ns"] / 1e9, state=state)
    if typed:
        drop(entry, "resumed")
        return "resumed"
    log("not_resumed", tool, sid, reason=reason, retry=bool(retry_at))
    if retry_at:
        entry["next_at"] = retry_at
        save(entry)
        hub("arm", tool, sid, resume_at=iso(retry_at))
        return "retry:" + reason
    drop(entry, reason)
    return "stopped:" + reason


def tick(now=None):
    results = {}
    for entry in entries():
        try:
            results[entry["session_id"]] = tick_one(entry, now)
        except HubUnavailable:
            results[entry["session_id"]] = "hub_unavailable"
        except (OSError, ValueError, KeyError, subprocess.TimeoutExpired) as error:
            log("error", entry.get("tool"), entry.get("session_id"), error=type(error).__name__)
            results[entry["session_id"]] = "error"
    return results


def resume_now(tool, sid):
    """The one-tap Resume from the app. (exit code, JSON result)."""
    if not re.fullmatch(r"[A-Za-z0-9_-]{1,200}", sid or ""):
        return 75, {"resumed": False, "reason": "unknown"}
    try:
        typed, reason, _, resets_at = resume(tool, sid, manual=True)
    except HubUnavailable:
        typed, reason, resets_at = False, "hub_unavailable", None
    if typed:
        with status.session_lock(sid, tool=tool):
            forget(tool, sid, "resumed")
        return 0, {"resumed": True}
    result = {"resumed": False, "reason": reason}
    if resets_at:
        result["resets_at"] = iso(resets_at)
    return 75, result
