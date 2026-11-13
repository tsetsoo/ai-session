"""Claude/Codex runtime status, an ordered durable outbox, and local-only RPC transport.

No third-party packages. Tokens are read only at delivery time and never written to the
outbox or log. The monitor reads metadata; it never resumes threads or submits prompts.
"""
import base64
import contextlib
from datetime import datetime
import fcntl
import glob
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import signal
import socket
import struct
import subprocess
import threading
import time
import urllib.error
import urllib.request


def codex_home():
    return Path(os.environ.get("CODEX_HOME", str(Path.home() / ".codex")))


def root():
    return Path(os.environ.get("AI_TODO_STATUS_DIR", str(Path.home() / ".ai-remote" / "status-state")))


def atomic_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    temporary = path.with_name(path.name + ".tmp-" + str(os.getpid()))
    try:
        with open(temporary, "w", opener=lambda p, flags: os.open(p, flags, 0o600)) as handle:
            json.dump(value, handle, separators=(",", ":"))
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def read_json(path, default=None):
    try:
        value = json.loads(path.read_text())
        return value if isinstance(value, dict) else default
    except (OSError, ValueError):
        return default


def configuration():
    values = hub_values()
    url = values.get("TODO_HUB_URL", "").rstrip("/")
    if not url.startswith(("http://", "https://")):
        raise ValueError("TODO_HUB_URL is missing or invalid")
    return url, values.get("TODO_API_TOKEN", "")


def hub_values():
    """Every KEY=value in todo-hub.conf (TODO_HUB_URL, TODO_API_TOKEN, TODO_COMPUTER_ID)."""
    path = Path(os.environ.get("AI_TODO_HUB_CONF", str(Path.home() / ".ai-remote" / "todo-hub.conf")))
    values = {}
    for line in path.read_text().splitlines():
        words = shlex.split(line, comments=True)
        if words[:1] == ["export"]:
            words = words[1:]
        if len(words) == 1 and "=" in words[0]:
            key, value = words[0].split("=", 1)
            values[key] = value
    return values


@contextlib.contextmanager
def session_lock(sid, blocking=True, tool="codex"):
    if not re.fullmatch(r"[A-Za-z0-9_-]{1,200}", sid):
        raise ValueError("invalid session id")
    directory = root()
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    key = ("claude." if tool == "claude" else "") + sid
    with open(directory / (key + ".lock"), "a") as handle:
        fcntl.flock(handle, fcntl.LOCK_EX | (0 if blocking else fcntl.LOCK_NB))
        yield directory / (key + ".json")


def runtime_status(status, approvals_reviewer=None):
    kind = status.get("type")
    if kind == "active":
        flags = set(status.get("activeFlags", []))
        if "waitingOnUserInput" in flags:
            return "waiting", "Codex needs your answer"
        # Automatic approval review is ongoing work, even though Codex exposes
        # the same active flag as an approval routed to the user.
        if "waitingOnApproval" in flags and approvals_reviewer not in ("auto_review", "guardian_subagent"):
            return "waiting", "Codex needs approval"
        return "busy", None
    if kind == "idle":
        return "idle", None
    if kind == "systemError":
        return "waiting", "Codex encountered an error; open the conversation"
    # notLoaded is not proof a turn finished: another Codex runtime may own it.
    return None


def fresh_runtime_state(sid, tool="codex"):
    snapshot = read_json(root() / ("claude-runtime.json" if tool == "claude" else "runtime.json"), {})
    observed = snapshot.get("observed_ns", 0)
    if not 0 <= time.time_ns() - observed < 8_000_000_000:
        return None
    state = snapshot.get("threads", {}).get(sid)
    return (observed, state) if state else None


def sync_legacy_state(sid, status, delivered=False, tool="codex"):
    directory = Path.home() / ".ai-remote" / "hook-state"
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / (("codex-" if tool == "codex" else "") + sid + (".sent" if delivered else ""))
    if not delivered and status == "waiting":
        try:
            if path.read_text().startswith("waiting "):
                return  # Preserve the hook's prompt identity for its attendance recheck.
        except OSError:
            pass
    path.write_text(status + "\n")


def deliver(path, record, timeout=0.5):
    """Called under the session lock. Failed/unknown-thread writes remain queued."""
    body = record["body"]
    try:
        url, token = configuration()
        headers = {"Content-Type": "application/json"}
        if token:
            headers["Authorization"] = "Bearer " + token
        request = urllib.request.Request(url + "/api/conversations/status", data=json.dumps(body).encode(), headers=headers)
        with urllib.request.urlopen(request, timeout=timeout) as response:
            if not 200 <= response.status < 300:
                raise OSError("HTTP " + str(response.status))
        record.update(pending=False, delivered_ns=time.time_ns(), last_error=None)
        sync_legacy_state(body["session_id"], body["status"], delivered=True, tool=body.get("tool", "codex"))
    except (OSError, ValueError, urllib.error.URLError) as error:
        # Error types/codes only: URLs, credentials and tool inputs do not belong in logs.
        record.update(pending=True, last_error=("HTTP " + str(error.code) if isinstance(error, urllib.error.HTTPError) else type(error).__name__))
        record["attempted_ns"] = time.time_ns()
    atomic_json(path, record)
    return not record["pending"]


def claude_tasks(value, excluding=None):
    """Keep only task identity/type; never persist commands, descriptions or prompts."""
    if not isinstance(value, list):
        return None  # An unavailable registry is not evidence that agents finished.
    result = []
    for task in value:
        if not isinstance(task, dict):
            return None
        if excluding and task.get("id") == excluding:
            continue
        result.append({"id": task.get("id"), "type": task.get("type")})
    return result


WORKER_ID = re.compile(r"[A-Za-z0-9_-]{1,80}")
MAX_WORKERS = 50


def worker_summary(workers, prompts=None):
    """The short per-worker list the hub keeps: id, state, needs_you and its message.
    Newest last; running and waiting workers are kept before finished ones at the cap."""
    prompts = prompts or {}
    rows = []
    for ident, worker in sorted(workers.items(), key=lambda item: item[1].get("ns", 0)):
        if not WORKER_ID.fullmatch(ident) or worker.get("state") not in ("working", "done"):
            continue
        row = {"id": ident, "state": worker["state"]}
        asks = [value for key, value in prompts.items() if key.startswith(ident + ":")]
        if worker.get("needs_you") or asks and worker["state"] == "working":
            row["needs_you"] = True
            message = worker.get("message") or (asks[-1].get("message") if asks else None)
            if isinstance(message, str) and message:
                row["message"] = message[:200]
        rows.append(row)
    while len(rows) > MAX_WORKERS:
        done = next((row for row in rows if row["state"] == "done"), rows[0])
        rows.remove(done)
    return rows


def claude_stop_confirmed(sid, completion):
    """A Stop hook runs before other hooks can block it. Confirm the final summary.

    Read a bounded tail, including on later polls: renewed main-thread activity must
    invalidate completion even if its hook was missed. Failure/unknown input stays busy.
    """
    try:
        path = Path(completion["transcript_path"])
        if path.name != sid + ".jsonl":
            return False
        with path.open("rb") as handle:
            size = handle.seek(0, os.SEEK_END)
            handle.seek(max(0, size - 262144))
            if size > 262144:
                handle.readline()
            lines = handle.read().splitlines()
        confirmed = False
        for line in lines:
            try:
                row = json.loads(line)
                stamp = row.get("timestamp")
                timestamp = int(datetime.fromisoformat(stamp.replace("Z", "+00:00")).timestamp() * 1_000_000_000)
            except (ValueError, TypeError, AttributeError):
                continue
            if timestamp < completion["stopped_ns"] or row.get("isSidechain") or row.get("agentId"):
                continue
            if row.get("sessionId", row.get("session_id")) != sid:
                continue
            if row.get("type") == "system" and row.get("subtype") == "stop_hook_summary":
                confirmed = (row.get("preventedContinuation") is False and not row.get("hookErrors")
                             and not row.get("hookAdditionalContext") and not row.get("stopReason"))
            elif (row.get("type") in ("user", "assistant") and not row.get("isMeta")
                  or row.get("type") == "api-request" and row.get("querySource") == "repl_main_thread"):
                # The final response can be flushed after our hook started. Only
                # activity after its summary proves that Claude continued.
                if confirmed:
                    return False
        return confirmed
    except (OSError, KeyError, TypeError, ValueError):
        return False


def claude_effective_state(sid, state, record, instance=None):
    evidence = record.get("claude_turn", {})
    prompts = evidence.get("prompts", {})
    if prompts and state[0] != "waiting":
        return "waiting", next(iter(prompts.values()))["message"]
    completion = evidence.get("completion")
    if not completion or state[0] == "waiting":
        return state  # A pending approval/question always takes precedence.
    # A newer/background runtime is independent work, not the stopped interactive turn.
    if not instance or instance.get("kind") != "interactive" or instance != completion.get("instance"):
        return state
    started = instance.get("startedAt")
    if isinstance(started, (int, float)) and started * 1_000_000 > completion["stopped_ns"]:
        return state
    tasks = evidence.get("tasks")
    if tasks is not None and any(task.get("type") != "shell" for task in tasks):
        return "busy", None
    if tasks is None or state[0] != "busy":
        return state
    return ("idle", None) if claude_stop_confirmed(sid, completion) else state


def claude_hook_evidence(previous, event, metadata, observed, snapshot):
    evidence = dict(previous.get("claude_turn", {}))
    if snapshot:
        if evidence.get("instance") and evidence["instance"] != snapshot:
            evidence = {}
        evidence["instance"] = snapshot
    agent = metadata.get("agent_id")
    lifecycle = event in ("SubagentStart", "SubagentStop")
    main = not agent and not lifecycle
    # Main activity and task snapshots have independent clocks. An agent completing
    # must not discard a delayed parent Stop, nor may that Stop resurrect the agent.
    if main and (event != "Notification" or metadata.get("waiting")):
        if observed <= evidence.get("main_hook_ns", -1):
            return evidence
        evidence["main_hook_ns"] = observed
    evidence["hook_ns"] = max(observed, evidence.get("hook_ns", 0))
    prompts = dict(evidence.get("prompts", {}))
    scope = agent or "main"
    prompt_id = metadata.get("prompt_id")
    key = scope + ":" + (prompt_id if isinstance(prompt_id, str) else "unknown")
    if metadata.get("waiting") and event in ("PermissionRequest", "PreToolUse", "Elicitation"):
        if observed >= prompts.get(key, {}).get("observed_ns", 0):
            prompts[key] = {"observed_ns": observed, "message": metadata.get("message") or "Claude needs your attention"}
    elif event in ("PostToolUse", "PostToolUseFailure", "ElicitationResult"):
        # Another parallel tool finishing cannot answer this tool's approval.
        if prompt_id and observed >= prompts.get(key, {}).get("observed_ns", 0):
            prompts.pop(key, None)
    elif event == "UserPromptSubmit":
        prompts = {k: v for k, v in prompts.items() if not k.startswith("main:")}
    if event == "SubagentStop" and isinstance(agent, str):
        # A finished agent's own approvals can no longer be answered.
        prompts = {k: v for k, v in prompts.items() if not k.startswith(agent + ":")}
    evidence["prompts"] = prompts
    workers = {k: dict(v) for k, v in evidence.get("workers", {}).items()}
    if isinstance(agent, str) and WORKER_ID.fullmatch(agent) and observed >= workers.get(agent, {}).get("ns", -1):
        # Any hook from inside an agent proves it runs (a resumed agent runs again).
        workers[agent] = {"state": "done" if event == "SubagentStop" else "working", "ns": observed}
    elif event == "UserPromptSubmit":
        workers = {k: v for k, v in workers.items() if v["state"] != "done"}
    if workers:
        evidence["workers"] = workers
    else:
        evidence.pop("workers", None)
    if event in ("Stop", "SubagentStart", "SubagentStop") and observed > evidence.get("tasks_ns", -1):
        tasks = claude_tasks(metadata.get("background_tasks"), excluding=agent if event == "SubagentStop" else None)
        if event == "SubagentStart":
            tasks = evidence.get("tasks")
            if tasks is not None:
                tasks = tasks + [{"id": agent, "type": "subagent"}]
        elif event == "SubagentStop" and tasks is None and evidence.get("tasks") is not None:
            tasks = [task for task in evidence["tasks"] if task.get("id") != agent]
        evidence.update(tasks=tasks, tasks_ns=observed)
        if event == "Stop" and tasks is not None:
            # The registry lists the agents still running; a foreground agent ends before Stop.
            running = {task.get("id") for task in tasks}
            for ident, worker in workers.items():
                if worker["state"] == "working" and ident not in running and worker["ns"] < observed:
                    worker.update(state="done", ns=observed)
    if event == "Stop" and isinstance(metadata.get("transcript_path"), str):
        evidence["completion"] = {
            "stopped_ns": observed, "transcript_path": metadata["transcript_path"], "instance": snapshot,
        }
    elif main and (event != "Notification" or metadata.get("waiting")):
        # Main tools include Stop-hook continuations and background wakeups.
        evidence.pop("completion", None)
    return evidence


def claude_runtime_evidence(evidence, state, observed, instance=None):
    evidence = dict(evidence)
    if instance:
        if evidence.get("instance") and evidence["instance"] != instance:
            evidence = {}
        evidence["instance"] = instance
    if state[0] == "waiting":
        evidence["runtime_waiting_ns"] = observed
    elif state[0] in ("busy", "idle") and evidence.get("runtime_waiting_ns"):
        answered = evidence.pop("runtime_waiting_ns")
        evidence.pop("completion", None)  # Answering a prompt resumes work; require a new Stop.
        evidence["prompts"] = {key: value for key, value in evidence.get("prompts", {}).items()
                               if value["observed_ns"] > answered}
    return evidence


# --- Usage-limit pauses ---------------------------------------------------------------
# A turn that stopped on a subscription usage limit is reported idle with
# "paused": {"kind": "session"|"weekly"|"limit", "resets_at": "<UTC RFC 3339>"|absent}.
# Claude: a StopFailure hook with error "rate_limit"; the limit text is the hook's
#   last_assistant_message or, failing that, the transcript's last rate_limit record:
#   "You've hit your session limit · resets 12:40am (Europe/Sofia)"
#   "You've hit your weekly limit · resets Mon 12:00am"
#   "5-hour limit reached ∙ resets 8pm", "Claude AI usage limit reached|1726000000"
# Codex: the rollout's last task_complete has error.codex_error_info usage_limit_exceeded;
#   the window at 100% in the last token_count rate_limits gives the kind and exact reset,
#   else its text: "... try again at 4:40 PM." / "... try again at Nov 5th, 2026 1:47 AM."

_MONTHS = ("jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec")
_WEEKDAYS = ("mon", "tue", "wed", "thu", "fri", "sat", "sun")
_RESET_TIME = re.compile(
    r"(?:resets|try again at)\s+(?:at\s+)?"
    r"(?:(?P<weekday>mon|tue|wed|thu|fri|sat|sun)[a-z]*,?\s+)?"
    r"(?:(?P<month>jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?\s+(?P<day>\d{1,2})(?:st|nd|rd|th)?,?\s+"
    r"(?:(?P<year>\d{4}),?\s+)?(?:at\s+)?)?"
    r"(?P<hour>\d{1,2})(?::(?P<minute>\d{2}))?\s*(?P<ampm>am|pm)"
    r"(?:\s*\((?P<zone>[A-Za-z_]+(?:/[A-Za-z0-9_+-]+)*)\))?",
    re.IGNORECASE)
_LEGACY_EPOCH = re.compile(r"usage limit reached\|(\d{9,11})", re.IGNORECASE)
_CODEX_WINDOWS = {300: "session", 10080: "weekly"}


def _utc_iso(moment):
    from datetime import timezone
    return moment.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def limit_reset_time(text, now=None):
    """The reset time a limit message names, as an aware datetime, or None. A bare time
    already past means tomorrow; a weekday means its next occurrence."""
    from datetime import timedelta
    legacy = _LEGACY_EPOCH.search(text or "")
    if legacy:
        return datetime.fromtimestamp(int(legacy.group(1))).astimezone()
    match = _RESET_TIME.search(text or "")
    if not match:
        return None
    zone = None
    if match.group("zone"):
        try:
            from zoneinfo import ZoneInfo
            zone = ZoneInfo(match.group("zone"))
        except Exception:
            zone = None
    now = (now or datetime.now().astimezone()).astimezone(zone) if zone else (now or datetime.now().astimezone()).astimezone()
    hour = int(match.group("hour")) % 12 + (12 if match.group("ampm").lower() == "pm" else 0)
    minute = int(match.group("minute") or 0)
    if hour > 23 or minute > 59:
        return None
    if match.group("month"):
        month = _MONTHS.index(match.group("month").lower()[:3]) + 1
        year = int(match.group("year") or now.year)
        try:
            moment = now.replace(year=year, month=month, day=int(match.group("day")), hour=hour, minute=minute,
                                 second=0, microsecond=0)
        except ValueError:
            return None
        if not match.group("year") and moment < now - timedelta(days=180):
            moment = moment.replace(year=year + 1)
        return moment
    moment = now.replace(hour=hour, minute=minute, second=0, microsecond=0)
    if match.group("weekday"):
        ahead = (_WEEKDAYS.index(match.group("weekday").lower()[:3]) - moment.weekday()) % 7
        moment += timedelta(days=ahead)
        if moment <= now:
            moment += timedelta(days=7)
    elif moment <= now:
        moment += timedelta(days=1)
    return moment


def limit_kind(text):
    lower = (text or "").lower()
    if "weekly" in lower:
        return "weekly"
    if "session limit" in lower or "5-hour" in lower:
        return "session"
    return "limit"


def _tail_lines(path, size=262144):
    try:
        with open(path, "rb") as handle:
            handle.seek(0, os.SEEK_END)
            end = handle.tell()
            handle.seek(max(0, end - size))
            raw = handle.read()
    except (OSError, TypeError, ValueError):
        return []
    lines = raw.decode("utf-8", "replace").splitlines()
    return lines[1:] if end > size else lines


def _claude_limit_text(transcript_path):
    """The text of the transcript's last rate_limit API error, if it is the last record
    that says anything."""
    for line in reversed(_tail_lines(transcript_path)):
        if '"rate_limit"' not in line and '"type":"user"' not in line and '"type": "user"' not in line:
            continue
        try:
            record = json.loads(line)
        except ValueError:
            continue
        if not isinstance(record, dict):
            continue
        if record.get("type") == "user" and not record.get("isMeta"):
            return None  # The user wrote after the error.
        if record.get("error") == "rate_limit":
            content = (record.get("message") or {}).get("content")
            if isinstance(content, str):
                return content
            if isinstance(content, list):
                return " ".join(b.get("text", "") for b in content if isinstance(b, dict) and isinstance(b.get("text"), str))
    return None


def claude_limit_pause(message, transcript_path, now=None):
    """The pause for a Claude StopFailure with error rate_limit."""
    text = message if isinstance(message, str) and limit_reset_time(message, now) else None
    if text is None and transcript_path:
        text = _claude_limit_text(transcript_path)
    if text is None:
        text = message if isinstance(message, str) else ""
    pause = {"kind": limit_kind(text)}
    reset = limit_reset_time(text, now)
    if reset is not None:
        pause["resets_at"] = _utc_iso(reset)
        if pause["kind"] == "limit":
            pause["kind"] = "session"  # Named a reset but no window: the 5-hour one is the usual.
    return pause


def codex_rollout(session_id):
    if not re.fullmatch(r"[A-Za-z0-9_-]+", session_id or ""):
        return None
    pattern = str(codex_home() / "sessions" / "*" / "*" / "*" / ("rollout-*-" + session_id + ".jsonl"))
    found = sorted(glob.glob(pattern))
    return found[-1] if found else None


def codex_limit_pause(session_id, now=None):
    """The pause when the Codex thread's last turn ended on its usage limit, else None."""
    path = codex_rollout(session_id)
    if not path:
        return None
    limits = None
    ended = None
    for line in _tail_lines(path):
        if '"token_count"' not in line and '"task_complete"' not in line and '"task_started"' not in line:
            continue
        try:
            payload = json.loads(line).get("payload")
        except (ValueError, AttributeError):
            continue
        if not isinstance(payload, dict):
            continue
        kind = payload.get("type")
        if kind == "task_started":
            ended = None
        elif kind == "task_complete":
            ended = payload
        elif kind == "token_count" and isinstance(payload.get("rate_limits"), dict):
            if payload["rate_limits"].get("limit_id") in (None, "codex"):
                limits = payload["rate_limits"]
    error = ended.get("error") if isinstance(ended, dict) else None
    if not isinstance(error, dict):
        return None
    text = error.get("message") if isinstance(error.get("message"), str) else ""
    if error.get("codex_error_info") != "usage_limit_exceeded" and "usage limit" not in text.lower():
        return None
    best = None
    for name in ("primary", "secondary"):
        window = (limits or {}).get(name)
        if not isinstance(window, dict):
            continue
        try:
            used, minutes, resets = float(window.get("used_percent")), int(window.get("window_minutes")), int(window.get("resets_at"))
        except (TypeError, ValueError):
            continue
        if used >= 100 and (best is None or resets > best[1]):
            best = (_CODEX_WINDOWS.get(minutes, "limit"), resets)
    if best:
        from datetime import timezone
        return {"kind": best[0], "resets_at": _utc_iso(datetime.fromtimestamp(best[1], timezone.utc))}
    pause = {"kind": limit_kind(text)}
    reset = limit_reset_time(text, now)
    if reset is not None:
        pause["resets_at"] = _utc_iso(reset)
    return pause


def limit_pause_message(pause):
    return {"session": "Session limit reached", "weekly": "Weekly limit reached"}.get(pause.get("kind"), "Usage limit reached")


def codex_parent(session_id):
    """The parent thread of a spawned Codex agent (its rollout's session_meta), or None."""
    path = codex_rollout(session_id)
    if not path:
        return None
    try:
        with open(path, errors="replace") as handle:
            meta = json.loads(handle.readline()).get("payload", {})
        spawn = ((meta.get("source") or {}).get("subagent") or {}).get("thread_spawn") or {}
        parent = spawn.get("parent_thread_id")
        return parent if isinstance(parent, str) and WORKER_ID.fullmatch(parent) and parent != session_id else None
    except (OSError, ValueError, AttributeError):
        return None


# A spawned Codex agent unheard of this long when its parent starts a turn is dropped: its
# runtime may never have been watched, so nothing would say it ended.
CODEX_WORKER_FORGOTTEN_NS = 30 * 60 * 1_000_000_000
# A spawned agent's thread missing from a connected runtime this long has ended. Live threads
# are reported every 30 s; the wait rides out one runtime reconnecting.
CODEX_CHILD_GONE_NS = 60 * 1_000_000_000


def codex_turn_workers(workers, new_turn, now):
    """The parent's Codex workers for this report. A new turn starts a new strip: finished
    agents leave it, and so do agents nothing was heard from for 30 minutes."""
    workers = dict(workers or {})
    if new_turn:
        workers = {k: v for k, v in workers.items()
                   if v.get("state") != "done" and now - v.get("ns", 0) < CODEX_WORKER_FORGOTTEN_NS}
    return workers


def note_codex_worker(parent, child, body, try_send=True):
    """A spawned Codex agent reports as its own thread. Fold its state into the parent's
    record and resend the parent's last status with the new worker list."""
    status = body.get("status")
    worker = {"state": "done" if status == "idle" else "working", "ns": body.get("event_timestamp_ns", 0)}
    if status == "waiting":
        worker.update(needs_you=True, message=body.get("message"))
    with session_lock(parent, tool="codex") as path:
        record = read_json(path, {})
        workers = dict(record.get("codex_workers", {}))
        if worker["ns"] < workers.get(child, {}).get("ns", -1):
            return False
        workers[child] = {k: v for k, v in worker.items() if v is not None}
        record["codex_workers"] = workers
        parent_body = record.get("body")
        if not isinstance(parent_body, dict) or parent_body.get("session_id") != parent:
            atomic_json(path, record)  # The parent's own next status carries the list.
            return False
        summary = worker_summary(workers)
        if summary == parent_body.get("workers"):
            atomic_json(path, record)
            return True
        parent_body = dict(parent_body)
        if summary:
            parent_body["workers"] = summary
        else:
            parent_body.pop("workers", None)
        record.update(body=parent_body, pending=True)
        atomic_json(path, record)
        return deliver(path, record) if try_send else False


def publish(body, observed_ns=None, source="hook", try_send=True):
    result = _publish(body, observed_ns, source, try_send)
    if (body.get("tool") or "codex") == "codex" and isinstance(body.get("session_id"), str):
        sid = body["session_id"]
        record = read_json(root() / (sid + ".json"), {})
        parent = record.get("codex_parent")
        if parent and isinstance(record.get("body"), dict):
            try:
                note_codex_worker(parent, sid, record["body"], try_send)
            except (OSError, ValueError):
                pass  # The worker list is a nicety; the child's own status went out.
    return result


def _publish(body, observed_ns=None, source="hook", try_send=True):
    sid = body.get("session_id") or body.get("claude_session_id")
    tool = body.get("tool", "claude" if body.get("claude_session_id") else "codex")
    if tool not in ("claude", "codex"):
        raise ValueError("invalid tool")
    if not isinstance(sid, str):
        raise ValueError("invalid session id")
    if body.get("status") not in ("busy", "idle", "waiting"):
        raise ValueError("invalid status")
    body = dict(body, session_id=sid, tool=tool)
    body.pop("claude_session_id", None)
    hook_event = body.pop("_hook_event", None)
    claude_metadata = body.pop("_claude", {})
    limit = body.pop("_limit", None)
    auto_resumed = body.pop("_auto_resumed", None)
    body.pop("paused", None)  # Only this publisher decides a pause.
    instance = body.pop("_claude_instance", None)
    observed = int(observed_ns if observed_ns is not None else time.time_ns())
    if not 0 <= observed <= 2**63 - 1:
        raise ValueError("invalid event timestamp")
    with session_lock(sid, tool=tool) as path:
        if auto_resumed:
            # Claude continued on its own: never type a second "continue", even if this report
            # turns out stale or idle.
            try:
                import ai_todo_resume
                ai_todo_resume.forget(tool, sid, "claude_auto_resumed")
            except (ImportError, OSError):
                pass
        previous = read_json(path, {})
        previous_body = previous.get("body", {})
        previous_time = previous_body.get("event_timestamp_ns", -1)
        previous_turn = previous_body.get("turn_started_ns", 0)
        turn_started = max(previous_turn, observed if hook_event == "UserPromptSubmit" else 0)
        new_turn = turn_started > previous_turn
        overridden = False
        evidence = previous.get("claude_turn", {})
        if tool == "claude" and source != "runtime":
            raw_snapshot = read_json(root() / "claude-runtime.json", {})
            instance = raw_snapshot.get("instances", {}).get(sid)
            claude_metadata = dict(claude_metadata, message=body.get("message"))
            evidence = claude_hook_evidence(previous, hook_event, claude_metadata, observed, instance)
        elif tool == "claude":
            evidence = claude_runtime_evidence(evidence, (body["status"], body.get("message")), observed, instance)
        if tool == "codex" and hook_event == "PermissionRequest" and body["status"] == "waiting":
            # Review routing is configuration, not transient activity. Keep using
            # the observed policy when a slow/disconnected poll makes its activity
            # snapshot too old to override hooks. Questions still need an answer.
            routing = read_json(root() / "runtime.json", {}).get("approvals_reviewers", {})
            if routing.get(sid) in ("auto_review", "guardian_subagent"):
                body["status"] = "busy"
                body.pop("message", None)
        if source != "runtime" and hook_event != "UserPromptSubmit":
            snapshot = fresh_runtime_state(sid, tool)
            if snapshot and snapshot[0] >= turn_started:
                observed, state = snapshot
                body["status"], body["message"] = state
                if body["message"] is None:
                    body.pop("message", None)
                overridden = True
        if tool == "claude":
            # Resolve both hooks and runtime heartbeats with the same durable evidence.
            state = (body["status"], body.get("message"))
            if hook_event in ("Stop", "SubagentStop") and evidence.get("completion") and state[0] == "idle":
                state = ("busy", None)  # Wait for the successful Stop summary.
            body["status"], body["message"] = claude_effective_state(
                sid, state, {"claude_turn": evidence}, instance)
            if body["message"] is None:
                body.pop("message")
        if previous_time > observed or (previous_time == observed and previous_body.get("status") != body["status"]):
            if tool == "claude" and source != "runtime" and evidence != previous.get("claude_turn", {}):
                # Runtime heartbeats may overtake a hook. Their timestamp must not
                # erase lifecycle evidence or keep a new turn falsely idle.
                observed = previous_time + 1
            elif not new_turn:
                sync_legacy_state(sid, previous["body"]["status"], tool=tool)
                return True
            # A runtime heartbeat can overtake the prompt hook. Keep the newer state,
            # but retain the turn identity so a fast/offline result becomes unread once.
            else:
                body = dict(previous_body)
                observed = previous_time
        body.pop("paused", None)  # A copied earlier body must not repeat its pause.
        if body["status"] == "idle":
            pause = None
            try:
                if tool == "claude" and source != "runtime" and hook_event == "StopFailure" and isinstance(limit, dict):
                    pause = claude_limit_pause(limit.get("message"), limit.get("transcript_path"))
                elif tool == "codex" and (source != "runtime" or previous_body.get("status") != "idle"):
                    # Codex may end an errored turn without its Stop hook or notify, so the
                    # monitor's busy -> idle counts too; idle heartbeats don't re-read.
                    pause = codex_limit_pause(sid)
            except Exception:
                pause = None  # A pause is a nicety; the status must still go out.
            if pause:
                body["paused"] = pause
                body["message"] = limit_pause_message(pause)
        body.pop("workers", None)
        codex_workers = None
        if tool == "claude" and evidence.get("workers"):
            if body["status"] == "idle":
                # An idle parent has no running agents: the registry would have kept it busy.
                evidence = dict(evidence, workers={k: dict(v, state="done") for k, v in evidence["workers"].items()})
            summary = worker_summary(evidence["workers"], evidence.get("prompts"))
            if summary:
                body["workers"] = summary
        codex_workers = codex_turn_workers(previous.get("codex_workers"), new_turn, observed)
        if tool == "codex" and codex_workers:
            summary = worker_summary(codex_workers)
            if summary:
                body["workers"] = summary
        body["event_timestamp_ns"] = observed
        if turn_started:
            body["turn_started_ns"] = turn_started
        try:
            import ai_todo_resume
            if body.get("paused") and not auto_resumed:
                ai_todo_resume.note_pause(tool, sid, body["paused"], observed)
            elif body["status"] != "idle" or new_turn:
                ai_todo_resume.forget(tool, sid, "new_turn" if new_turn else body["status"])
        except (ImportError, OSError, ValueError):
            pass  # Resuming is a nicety; the status must still go out.
        attended_ns = previous.get("attended_ns", 0)
        if source != "runtime" and body.get("attended"):
            attended_ns = time.time_ns()
        if source == "runtime" and time.time_ns() - attended_ns < 60_000_000_000:
            body["attended"] = True
        record = {"body": body, "source": source, "pending": True, "attended_ns": attended_ns}
        if tool == "claude" and evidence:
            record["claude_turn"] = evidence
        if "codex_parent" in previous:
            record["codex_parent"] = previous["codex_parent"]
        if tool == "codex" and codex_workers:
            record["codex_workers"] = codex_workers
        if tool == "codex" and "codex_parent" not in record:
            record["codex_parent"] = codex_parent(sid) or ""
        # Persist before networking; a killed hook must leave the final event recoverable.
        atomic_json(path, record)
        if overridden or source == "runtime":
            sync_legacy_state(sid, body["status"], tool=tool)
        if (tool == "claude" and hook_event in ("PreToolUse", "PostToolUse", "PostToolUseFailure", "ElicitationResult") and not previous.get("pending", True)
                and all(previous_body.get(key) == body.get(key) for key in ("status", "message", "turn_started_ns", "attended", "workers"))):
            record.update(pending=False, delivered_ns=previous.get("delivered_ns"))
            atomic_json(path, record)
            return True
        return deliver(path, record) if try_send else False


# The status service reports every conversation on the computer; the hub answers 404 for
# those no todo links to. Retrying lets one linked later still get its state, but only
# for a day: after that its next change is reported anew. Settled records go after a week.
GIVE_UP_404_NS = 24 * 3600 * 1_000_000_000
PRUNE_SETTLED_NS = 7 * 24 * 3600 * 1_000_000_000


def retry_pending(budget=None, respect_backoff=False):
    result = {"delivered": 0, "pending": 0}
    deadline = time.monotonic() + budget if budget is not None else float("inf")
    for path in sorted(root().glob("*.json"), key=lambda p: p.stat().st_mtime_ns, reverse=True):
        if time.monotonic() >= deadline:
            break
        if path.name in ("runtime.json", "health.json", "delivery.json", "claude-runtime.json", "claude-health.json"):
            continue
        try:
            # Codex's existing filenames stay compatible; Claude gets its own namespace.
            preview = read_json(path, {}).get("body", {})
            tool = preview.get("tool", "codex") if isinstance(preview, dict) else "codex"
            sid = path.stem[7:] if tool == "claude" and path.stem.startswith("claude.") else path.stem
            with session_lock(sid, blocking=False, tool=tool) as locked:
                record = read_json(path, {})
                now = time.time_ns()
                if not record.get("pending"):
                    body = record.get("body") if isinstance(record.get("body"), dict) else {}
                    latest = max(body.get("event_timestamp_ns", 0), record.get("delivered_ns", 0), record.get("attempted_ns", 0))
                    if now - latest > PRUNE_SETTLED_NS:
                        locked.unlink(missing_ok=True)
                        # Keep the lock inode: another publisher may already be waiting
                        # on it. Unlinking lets a third process lock a new inode while
                        # that waiter still owns the old one, breaking event ordering.
                    continue
                body = record.get("body")
                if not isinstance(body, dict) or body.get("session_id") != sid or body.get("status") not in ("idle", "busy", "waiting"):
                    record.update(pending=False, last_error="InvalidOutboxRecord")
                    atomic_json(path, record)
                    continue
                if record.get("last_error") == "HTTP 404" and now - body.get("event_timestamp_ns", now) > GIVE_UP_404_NS:
                    record.update(pending=False, gave_up_ns=now)
                    atomic_json(path, record)
                    continue
                wait = 30 if record.get("last_error") == "HTTP 404" else 5
                if respect_backoff and time.time_ns() - record.get("attempted_ns", 0) < wait * 1_000_000_000:
                    result["pending"] += 1
                    continue
                ok = deliver(path, record, timeout=1)
                result["delivered" if ok else "pending"] += 1
        except (BlockingIOError, ValueError, OSError):
            continue
    return result


class RuntimeRPCError(ValueError):
    """A rejected request, with the socket itself still usable."""


class RuntimeSocket:
    """JSON-RPC over a WebSocket on a private Unix socket; never a TCP listener."""
    def __init__(self, path, timeout=2, experimental=False):
        self.socket = socket.socket(socket.AF_UNIX)
        self.socket.settimeout(timeout)
        self.file = None
        self.request_id = 0
        try:
            self.socket.connect(str(path))
            key = base64.b64encode(os.urandom(16)).decode()
            self.socket.sendall(("GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: " + key + "\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())
            self.file = self.socket.makefile("rb", buffering=0)
            first = self.file.readline(8192).decode().strip()
            headers = {}
            for _ in range(100):
                line = self.file.readline(8192)
                if line in (b"\r\n", b"\n", b""):
                    break
                key_name, value = line.decode().split(":", 1)
                headers[key_name.lower()] = value.strip()
            expected = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
            if " 101 " not in first or headers.get("sec-websocket-accept") != expected:
                raise ValueError("invalid runtime WebSocket handshake")
            self.call("initialize", {"clientInfo": {"name": "ai-remote-status", "version": "2"},
                                     "capabilities": {"experimentalApi": experimental}})
            self.send({"method": "initialized"})
        except Exception:
            self.close()
            raise

    def close(self):
        if self.file:
            self.file.close()
        self.socket.close()

    def send(self, value, opcode=1):
        data = json.dumps(value).encode() if opcode == 1 else value
        size = len(data)
        header = bytes([128 | opcode, 128 | size]) if size < 126 else bytes([128 | opcode, 254]) + struct.pack("!H", size) if size < 65536 else bytes([128 | opcode, 255]) + struct.pack("!Q", size)
        mask = os.urandom(4)
        self.socket.sendall(header + mask + bytes(byte ^ mask[i % 4] for i, byte in enumerate(data)))

    def exact(self, count):
        chunks = []
        while count:
            data = self.file.read(count)
            if not data:
                raise EOFError("runtime connection closed")
            chunks.append(data)
            count -= len(data)
        return b"".join(chunks)

    def receive(self):
        chunks = []
        total = 0
        while True:
            flags, length = self.exact(2)
            size = length & 127
            if size == 126:
                size = struct.unpack("!H", self.exact(2))[0]
            elif size == 127:
                size = struct.unpack("!Q", self.exact(8))[0]
            total += size
            if total > 16 * 1024 * 1024:
                raise ValueError("oversized runtime message")
            mask = self.exact(4) if length & 128 else None
            data = self.exact(size)
            if mask:
                data = bytes(byte ^ mask[i % 4] for i, byte in enumerate(data))
            opcode = flags & 15
            if opcode == 8:
                raise EOFError("runtime connection closed")
            if opcode == 9:
                self.send(data, opcode=10)
                continue
            if opcode == 10:
                continue
            chunks.append(data)
            if flags & 128:
                return json.loads(b"".join(chunks))

    def call(self, method, params):
        self.request_id += 1
        request_id = self.request_id
        self.send({"id": request_id, "method": method, "params": params})
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            response = self.receive()
            if response.get("id") == request_id and "method" not in response:
                if "error" in response:
                    raise RuntimeRPCError(method + " failed")
                return response.get("result", {})
        raise TimeoutError("runtime request timed out")

    def states(self):
        loaded = self.call("thread/loaded/list", {}).get("data", [])
        result = {}
        self.approvals_reviewers = {}
        configs = {}
        for sid in loaded:
            try:
                thread = self.call("thread/read", {"threadId": sid, "includeTurns": False}).get("thread", {})
            except RuntimeRPCError:
                # A thread can unload between listing and reading. Keep observing the
                # other threads; transport errors still reconnect the whole socket.
                continue
            raw_status = thread.get("status", {})
            reviewer = None
            if raw_status.get("type") == "active":
                try:
                    cwd = thread.get("cwd")
                    if cwd not in configs:
                        configs[cwd] = self.call("config/read", {"cwd": cwd}).get("config", {})
                    config = configs[cwd]
                    reviewer = config.get("approvals_reviewer")
                    if reviewer is not None:
                        self.approvals_reviewers[sid] = reviewer
                except RuntimeRPCError:
                    pass  # Older runtimes may not expose config; retain the prompt.
            state = runtime_status(raw_status, reviewer)
            if state:
                result[sid] = state
        return result


def socket_path():
    return Path(os.environ.get("AI_TODO_CODEX_SOCKET", str(codex_home() / "app-server-control" / "app-server-control.sock")))


def find_codex():
    # Match the TUI client to the already-installed managed server when possible. This
    # avoids using an older npm client simply because a non-interactive PATH found it first.
    candidates = [os.environ.get("AI_TODO_CODEX_BIN"), str(codex_home() / "packages/app-server-daemon/current/bin/codex"),
                  shutil.which("codex"), str(Path.home() / ".local/bin/codex"), "/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
    candidates += sorted(glob.glob(str(Path.home() / ".nvm/versions/node/*/bin/codex")), reverse=True)
    candidates += ["/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"]
    for candidate in dict.fromkeys(candidates):
        if not candidate or not os.path.isfile(candidate):
            continue
        environment = os.environ.copy()
        environment["PATH"] = str(Path(candidate).parent) + os.pathsep + environment.get("PATH", "")
        try:
            checked = subprocess.run([candidate, "--version"], capture_output=True, text=True, timeout=4, env=environment)
            if checked.returncode == 0:
                return candidate
        except (OSError, subprocess.TimeoutExpired):
            continue
    raise FileNotFoundError("No working Codex binary; run ai-todo-status doctor")


def terminal_arguments(args, endpoint):
    """Remote TUIs ignore MCP -c flags and reject resume permission overrides.

    Apply configuration and approval defaults on the owning backend instead.
    Values stay as argv, never evaluated or written into the registry.
    """
    backend = [args[0], "app-server", "-c", 'approval_policy="on-request"',
               "-c", 'approvals_reviewer="auto_review"', "-c", 'sandbox_mode="workspace-write"']
    terminal = [args[0], "--remote", endpoint]
    index = 1
    while index < len(args):
        arg = args[index]
        if arg in ("-c", "--config"):
            if index + 1 >= len(args):
                raise ValueError("missing config override")
            backend += args[index:index + 2]
            index += 2
        elif arg == "--approve-for-me":
            index += 1
        else:
            terminal.append(arg)
            index += 1
    # Updater UI belongs to the client; this one option must remain there too.
    terminal[1:1] = ["-c", "check_for_update_on_startup=false"]
    return backend + ["--listen", endpoint], terminal


def terminal_socket(name):
    """Where the backend for tmux session `name` listens; its .json/.lock/.log sit beside it."""
    return root() / "r" / (hashlib.sha256(name.encode()).hexdigest()[:12] + ".sock")


def terminal_threads(name):
    """The threads the backend for tmux session `name` has loaded; empty without one.
    A fresh TUI's thread is loaded there at startup, before anything is written for it."""
    try:
        client = RuntimeSocket(terminal_socket(name))
    except (OSError, ValueError, EOFError):
        return []
    try:
        return client.call("thread/loaded/list", {}).get("data", [])
    finally:
        client.close()


def file_holders(path):
    """Pids with `path` open: /proc where there is one, else lsof."""
    target = os.path.realpath(path)
    if os.path.isdir("/proc/self/fd"):
        pids = set()
        for pid in filter(str.isdigit, os.listdir("/proc")):
            try:
                if any(os.readlink(f"/proc/{pid}/fd/{fd}") == target for fd in os.listdir(f"/proc/{pid}/fd")):
                    pids.add(int(pid))
            except OSError:
                continue
        return sorted(pids)
    try:
        listed = subprocess.run([os.environ.get("AI_TODO_LSOF", "lsof"), "-t", "--", target],
                                capture_output=True, text=True, timeout=10).stdout
    except (OSError, subprocess.TimeoutExpired):
        return []
    return sorted({int(word) for word in listed.split() if word.isdigit()})


def tmux_sessions():
    """Running tmux session names, or None when tmux can't be asked. The status service runs
    under launchd without Homebrew on PATH, so the usual places are tried too."""
    tmux = next((c for c in [shutil.which("tmux"), "/opt/homebrew/bin/tmux", "/usr/local/bin/tmux",
                             "/home/linuxbrew/.linuxbrew/bin/tmux"] if c and os.path.isfile(c)), None)
    if not tmux:
        return None
    socket_name = os.environ.get("AI_TODO_TMUX_SOCKET")
    try:
        listed = subprocess.run([tmux] + (["-L", socket_name] if socket_name else []) + ["list-sessions", "-F", "#{session_name}"],
                                capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if listed.returncode:
        # No server (or no socket yet) means no sessions; anything else is not an answer.
        return set() if "no server running" in listed.stderr or "error connecting" in listed.stderr else None
    return {line for line in listed.stdout.split("\n") if line}


def run_group(args, timeout, env=None):
    """subprocess.run in its own process group. On timeout the whole group is killed:
    `claude agents` starts keychain lookups (`security`) that outlive a killed claude,
    and those left behind made the next calls time out too (2026-11-03)."""
    process = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                               env=env, start_new_session=True)
    try:
        stdout, stderr = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass
        process.communicate()
        raise
    return subprocess.CompletedProcess(args, process.returncode, stdout, stderr)


def stop_process_group(pid):
    """SIGTERM a backend's process group, then SIGKILL if it is still there after 5 s."""
    os.killpg(pid, signal.SIGTERM)
    for _ in range(50):
        try:
            # Our own child (a backend this process started) stays a zombie until reaped.
            if os.waitpid(pid, os.WNOHANG)[0] == pid:
                return
        except ChildProcessError:
            pass
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return
        time.sleep(0.1)
    # A listener can close before the process releases thread writer locks.
    try:
        os.killpg(pid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        # Gone meanwhile, or only a zombie left (macOS refuses to signal its group).
        return
    time.sleep(0.2)


def reap_backends():
    """Stop the terminal backends whose tmux session has gone, once their threads are idle.

    terminal() starts each in its own session so it outlives the pane, with that
    conversation's MCP servers; nothing else stops it. A backend is stopped only when its
    record's pid is still the process listening on its socket. Returns the pids stopped.
    """
    directory = root() / "r"
    sessions = tmux_sessions()
    if sessions is None:
        return []
    stopped = []
    for record_path in sorted(directory.glob("*.json")):
        if record_path.stem in {terminal_socket(name).stem for name in sessions}:
            continue
        try:
            with open(directory / (record_path.stem + ".lock"), "a") as lock:
                # terminal() holds this while it starts or reuses a backend, inside a tmux
                # session that already exists: under it, a session that is still missing is gone.
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                sessions = tmux_sessions()
                if sessions is None or record_path.stem in {terminal_socket(name).stem for name in sessions}:
                    continue
                pid = reap_backend(record_path)
                if pid:
                    stopped.append(pid)
        except (BlockingIOError, OSError, ValueError, EOFError, TimeoutError, subprocess.SubprocessError):
            continue
    return stopped


def reap_backend(record_path):
    """Stop one backend whose session has gone (called under its lock); its pid, or None."""
    path = record_path.with_suffix(".sock")
    pid = read_json(record_path, {}).get("pid")
    alive = isinstance(pid, int) and pid > 0
    if alive:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            alive = False
    if alive:
        command = subprocess.run(["ps", "-p", str(pid), "-o", "command="], capture_output=True, text=True, timeout=5).stdout
        if "unix://" + str(path) not in command or os.getpgid(pid) != pid:
            return None
        client = RuntimeSocket(path)
        try:
            if any(value[0] != "idle" for value in client.states().values()):
                return None
        finally:
            client.close()
        stop_process_group(pid)
    for suffix in (".json", ".sock", ".log"):
        record_path.with_suffix(suffix).unlink(missing_ok=True)
    return pid if alive else None


def writer_conflict(name, sid):
    """Who else holds Codex thread `sid`'s writer lock, as a message; None when it is free or
    held by the backend for tmux session `name` (the conversation's own).

    Codex keeps a thread's lock file flocked while a process writes the thread, so a
    non-blocking probe answers whether it is held; naming the holder needs lsof or /proc.
    A free lock is taken for an instant and released.
    """
    lock = codex_home() / "thread-writer-locks" / (sid + ".lock")
    try:
        fd = os.open(lock, os.O_RDONLY)
    except OSError:
        return None
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return None
    except BlockingIOError:
        pass
    finally:
        os.close(fd)
    own = terminal_socket(name)
    backends = own.parent
    by_socket = {terminal_socket(session): session for session in tmux_sessions() or ()}
    lines, hints = [], []
    for pid in file_holders(lock):
        try:
            command = subprocess.run(["ps", "-p", str(pid), "-o", "command="],
                                     capture_output=True, text=True, timeout=5).stdout.strip()
        except (OSError, subprocess.TimeoutExpired):
            command = ""
        if not command:
            continue
        # A backend's argv ends with `--listen unix://<socket>` (terminal_arguments).
        listen = Path(command.rsplit(" unix://", 1)[1]) if " unix://" in command else None
        if listen == own:
            return None
        if listen is not None and listen.parent == backends:
            session = by_socket.get(listen)
            if session:
                lines.append(f"  pid {pid}: this computer's Codex backend for {session}, which has it open")
                hints.append(f"Close Codex in {session} and stop its backend with `kill {pid}`, then open this one again.")
            else:
                lines.append(f"  pid {pid}: this computer's Codex backend for a todo session that has closed")
                hints.append(f"Nothing uses it any more. Stop it with `kill {pid}`, then open this one again.")
        elif "--managed-daemon" in command or str(socket_path()) in command:
            lines.append(f"  pid {pid}: Codex's shared server")
            hints.append("Run `codex app-server daemon restart` on this computer, then open it again. "
                         "The restart also disconnects plain `codex` windows that use that server.")
        elif "/ChatGPT.app/" in command:
            lines.append(f"  pid {pid}: the ChatGPT app")
            hints.append("Close the conversation in the ChatGPT app, or quit it, then open it again.")
        else:
            lines.append(f"  pid {pid}: {command[:160]}")
            hints.append("Close it there, or stop that process, then open it again.")
    if not lines:
        # Held, but the holder could not be named (no lsof, or another user's process).
        lines.append("  a process this script can't identify")
        hints.append(f"Find it with `lsof {lock}`, close it, then open it again.")
    return "\n".join([f"Codex conversation {sid} is open in another Codex on this computer:"]
                     + lines + list(dict.fromkeys(hints)))


def trust_folder(client, cwd):
    """Save `cwd` as trusted, as Codex's own "Trust and continue" does, unless it already is.

    A conversation started from the app is in a folder the user picked. The TUI asks "Trust
    this folder?" from the saved config (a launch -c override doesn't count), and a fresh
    start attaches only once its id appears, so nobody would see the question.
    """
    projects = (client.call("config/read", {"cwd": cwd}).get("config") or {}).get("projects") or {}
    if (projects.get(cwd) or {}).get("trust_level") == "trusted":
        return
    client.call("config/value/write", {"keyPath": "projects", "mergeStrategy": "upsert",
                                       "value": {cwd: {"trust_level": "trusted"}}})


def backend_decision(settings_changed, upgraded, busy, verified):
    """Whether terminal() replaces a conversation's running backend: "keep" or "replace".

    Changed settings (MCP servers, approval flags, folder) need a new backend, so a busy or
    unverifiable one is an error, as before. A newer Codex alone (`upgraded`) replaces an
    idle, verified backend; otherwise the conversation opens on the older one, never fails.
    """
    if not settings_changed and not upgraded:
        return "keep"
    if busy:
        if settings_changed:
            raise ValueError("runtime settings changed while a turn is active")
        return "keep"
    if not verified:
        if settings_changed:
            raise ValueError("could not verify the previous runtime process")
        return "keep"
    return "replace"


def terminal(name, cwd, args):
    """Launch an observable backend with this terminal's MCP config and environment."""
    path = terminal_socket(name)
    directory = path.parent
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    key = path.stem
    endpoint = "unix://" + str(path)
    backend, client_args = terminal_arguments(args, endpoint)
    env_file = Path.home() / ".ai-remote/mcp/env"
    stamp = env_file.stat().st_mtime_ns if env_file.exists() else 0
    digest = hashlib.sha256(json.dumps([backend, cwd, stamp]).encode()).hexdigest()
    # The binary behind backend[0]: `…/current/bin/codex` and ~/.local/bin links keep their
    # path when Codex updates, so the resolved file tells an older backend apart.
    binary = os.path.realpath(backend[0])
    record_path = directory / (key + ".json")
    with open(directory / (key + ".lock"), "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        record = read_json(record_path, {})
        existing = None
        try:
            existing = RuntimeSocket(path)
        except (OSError, ValueError, EOFError):
            pass
        if existing:
            try:
                settings_changed = record.get("digest") != digest
                upgraded = record.get("binary") != binary
                if settings_changed or upgraded:
                    busy = any(value[0] != "idle" for value in existing.states().values())
                    pid = record.get("pid")
                    verified = False
                    if not busy:
                        # Only replace our own idle backend, never an unrelated reused PID.
                        try:
                            command = subprocess.check_output(["ps", "-p", str(pid), "-o", "command="], text=True)
                            verified = endpoint in command and os.getpgid(pid) == pid
                        except (subprocess.CalledProcessError, OSError, TypeError):
                            verified = False
                    if backend_decision(settings_changed, upgraded, busy, verified) == "replace":
                        # The verified, idle backend must be gone before resuming.
                        stop_process_group(pid)
                        existing.close()
                        existing = None
            finally:
                if existing:
                    existing.close()
        if not existing:
            path.unlink(missing_ok=True)
            # This file contains server diagnostics only; credentials are inherited via
            # the environment, not included in the registry or status service's log.
            log_fd = os.open(directory / (key + ".log"), os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
            try:
                process = subprocess.Popen(backend, cwd=cwd, stdin=subprocess.DEVNULL,
                                           stdout=log_fd, stderr=log_fd, start_new_session=True)
            finally:
                os.close(log_fd)
            ready = False
            for _ in range(100):
                if process.poll() is not None:
                    break
                try:
                    probe = RuntimeSocket(path)
                    probe.close()
                    ready = True
                    break
                except (OSError, ValueError, EOFError):
                    time.sleep(0.1)
            if not ready:
                if process.poll() is None:
                    os.killpg(process.pid, signal.SIGTERM)
                raise OSError("terminal runtime did not become ready")
            atomic_json(record_path, {"pid": process.pid, "digest": digest, "binary": binary})
    try:
        client = RuntimeSocket(path)
        try:
            trust_folder(client, cwd)
        finally:
            client.close()
    except (OSError, ValueError, EOFError, TimeoutError):
        pass  # Codex then asks as usual.
    os.chdir(cwd)
    os.execv(client_args[0], client_args)


class RuntimePool:
    """Observe the shared daemon plus app terminals with their own MCP settings."""
    def __init__(self):
        self.clients = {}

    def states(self):
        paths = {socket_path()}
        paths.update(path.with_suffix(".sock") for path in (root() / "r").glob("*.json"))
        for removed in set(self.clients) - paths:
            self.clients.pop(removed).close()
        result = {}
        self.approvals_reviewers = {}
        connected = 0
        for path in sorted(paths):
            try:
                if path not in self.clients:
                    self.clients[path] = RuntimeSocket(path)
                states = self.clients[path].states()
                # If multiple runtimes know a thread, its routing must match the
                # same runtime whose state wins, including unknown routing.
                for sid in states:
                    self.approvals_reviewers.pop(sid, None)
                result.update(states)
                self.approvals_reviewers.update(getattr(self.clients[path], "approvals_reviewers", {}))
                connected += 1
            except (OSError, ValueError, EOFError, TimeoutError):
                client = self.clients.pop(path, None)
                if client:
                    client.close()
        if not connected:
            raise OSError("no connected runtimes")
        return result

    def close(self):
        for client in self.clients.values():
            client.close()
        self.clients.clear()


def find_claude():
    candidates = [os.environ.get("AI_TODO_CLAUDE_BIN"), shutil.which("claude"),
                  str(Path.home() / ".local/bin/claude"), "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
    candidates += sorted(glob.glob(str(Path.home() / ".nvm/versions/node/*/bin/claude")), reverse=True)
    for candidate in dict.fromkeys(candidates):
        if not candidate or not os.path.isfile(candidate):
            continue
        env = dict(os.environ, PATH=str(Path(candidate).parent) + os.pathsep + os.environ.get("PATH", ""))
        try:
            check = run_group([candidate, "--version"], timeout=10, env=env)
            if check.returncode == 0:
                return candidate
        except (OSError, subprocess.TimeoutExpired):
            pass
    raise FileNotFoundError("No working Claude binary")


def claude_status(row):
    status, state = row.get("status"), row.get("state")
    if status == "waiting" or state == "blocked":
        reason = row.get("waitingFor")
        reason = reason if isinstance(reason, str) else None
        return "waiting", {"permission prompt": "Claude needs approval", "input needed": "Claude needs your answer",
                           "sandbox request": "Claude needs sandbox approval"}.get(reason, "Claude needs your attention")
    if state == "failed":
        return "waiting", "Claude encountered an error; open the conversation"
    if status == "busy" or state == "working":
        return "busy", None
    if status in ("idle", "shell") or state in ("done", "stopped"):
        return "idle", None
    return None  # Missing or new status values are not proof that work completed.


def reconcile_claude_sessions(rows):
    """Follow /clear and other session changes in the same live todo terminal.

    Match the local process registry to the runtime and the hub's exact tmux name
    and computer. A cwd or todo prefix alone cannot identify a conversation.
    """
    computer_id = hub_values().get("TODO_COMPUTER_ID")
    if not computer_id:
        return
    terminals = {}
    for row in rows:
        pid, sid = row.get("pid"), row.get("sessionId")
        if row.get("kind") != "interactive" or not isinstance(pid, int) or isinstance(pid, bool):
            continue
        local = read_json(Path.home() / ".claude" / "sessions" / f"{pid}.json", {})
        if (local.get("sessionId") != sid or local.get("pid") != pid
                or local.get("startedAt") != row.get("startedAt")):
            continue
        tmux = local.get("tmux")
        if not isinstance(tmux, str):
            continue
        name = tmux.split(":", 1)[0]
        if not name.startswith("ai/claude/todo-"):
            continue
        # Multiple processes in one terminal are ambiguous; never guess which owns it.
        terminals.setdefault(name, []).append(sid)
    if not terminals:
        return
    url, token = configuration()
    headers = {"Authorization": "Bearer " + token, "Content-Type": "application/json"}
    with urllib.request.urlopen(urllib.request.Request(url + "/api/conversations", headers=headers), timeout=2) as response:
        conversations = json.load(response)
    if not isinstance(conversations, list):
        return
    for conversation in conversations:
        if (conversation.get("tool") != "claude" or conversation.get("status") == "closed"
                or conversation.get("computer", {}).get("id") != computer_id):
            continue
        candidates = terminals.get(conversation.get("tmux_name"), [])
        if len(candidates) != 1 or candidates[0] == conversation.get("session_id"):
            continue
        identifier = conversation.get("id", "")
        if not re.fullmatch(r"[A-Za-z0-9_-]{1,200}", identifier):
            continue
        request = urllib.request.Request(url + "/api/conversations/" + identifier + "/session",
                                         headers=headers, method="PUT",
                                         data=json.dumps({"session_id": candidates[0]}).encode())
        with urllib.request.urlopen(request, timeout=2):
            pass


class ClaudeRuntime:
    def __init__(self):
        self.cli = find_claude()
        self.listed = set()
        self.instances = {}
        self.reconciled_at = float("-inf")

    def states(self):
        env = dict(os.environ, PATH=str(Path(self.cli).parent) + os.pathsep + os.environ.get("PATH", ""))
        # Under launchd (Background) this takes 1-2 s, not 0.2 s: leave room for a busy moment.
        response = run_group([self.cli, "agents", "--json", "--all"], timeout=10, env=env)
        if response.returncode:
            raise OSError("Claude status command failed")
        rows = json.loads(response.stdout)
        if not isinstance(rows, list):
            raise ValueError("invalid Claude status response")
        # --all keeps finished background copies, so one conversation can be listed twice:
        # an old background copy still marked blocked beside the terminal that resumed it.
        # The copy started last is the one running now.
        newest = {}
        for row in rows:
            if not isinstance(row, dict):
                continue
            sid = row.get("sessionId")
            if not isinstance(sid, str) or not re.fullmatch(r"[A-Za-z0-9_-]{1,200}", sid):
                continue
            started = row.get("startedAt")
            started = started if isinstance(started, (int, float)) else 0
            if sid not in newest or started >= newest[sid][0]:
                newest[sid] = (started, row)
        # Listed with a status we can't read is still listed: poll_runtime must not settle it.
        self.listed = set(newest)
        self.instances = {sid: {key: row.get(key) for key in ("kind", "startedAt", "pid")}
                          for sid, (_, row) in newest.items()}
        if time.monotonic() - self.reconciled_at >= 30:
            try:
                reconcile_claude_sessions([row for _, row in newest.values()])
                self.reconciled_at = time.monotonic()
            except (OSError, ValueError):
                # Hub connectivity must not prevent local status collection.
                self.reconciled_at = time.monotonic() - 25
        result = {}
        for sid, (_, row) in newest.items():
            state = claude_status(row)
            if state:
                result[sid] = state
        return result


# A Claude conversation gone from `claude agents` has no process left, so a turn it was
# running has ended. It is settled as idle once it stays gone this long (two polls at least),
# so a missed listing can't end a live turn. An empty listing (Claude restarting) settles
# nothing, and neither does a newer hook report. Codex is never settled this way: an
# unloaded thread may be running in another runtime.
VANISHED_NS = 3_000_000_000


def poll_runtime(client, previous, try_send=True, tool="codex"):
    states = client.states()
    observed = time.time_ns()
    effective = {}
    instances = getattr(client, "instances", {}) if tool == "claude" else {}
    for sid, state in states.items():
        prior = previous.setdefault(sid, {})
        prior.pop("missing_since_ns", None)
        if state[0] == "idle":
            idle_since = prior.setdefault("idle_since_ns", observed)
            if observed - idle_since < 1_000_000_000:
                # A newly queued turn can briefly retain idle before the runtime starts it.
                # Confirm idle once more so that gap cannot emit a false completion/review.
                retained = prior.get("raw_state", prior.get("state"))
                if retained:
                    effective[sid] = retained
                continue
        else:
            prior.pop("idle_since_ns", None)
        effective[sid] = state
    snapshot = {"observed_ns": observed, "threads": effective, "instances": instances}
    if tool == "codex":
        snapshot["approvals_reviewers"] = getattr(client, "approvals_reviewers", {})
    atomic_json(root() / ("claude-runtime.json" if tool == "claude" else "runtime.json"), snapshot)
    for sid, raw_state in effective.items():
        filename = f"claude.{sid}.json" if tool == "claude" else f"{sid}.json"
        record = read_json(root() / filename, {})
        record["claude_turn"] = claude_runtime_evidence(record.get("claude_turn", {}), raw_state, observed, instances.get(sid))
        state = claude_effective_state(sid, raw_state, record, instances.get(sid)) if tool == "claude" else raw_state
        prior = previous[sid]
        # A hook can land between unchanged polls. Don't leave its stale prompt
        # up until the next heartbeat. Retained busy during idle confirmation
        # isn't evidence of work, and must not undo a real completion.
        codex_prompt_answered = (tool == "codex" and states[sid][0] == "busy"
                                 and record.get("body", {}).get("status") == "waiting")
        if (tuple(prior.get("state", ())) != tuple(state)
                or tool == "claude" and tuple(prior.get("raw_state", ())) != tuple(raw_state)
                or codex_prompt_answered
                or observed - prior.get("reported_ns", 0) >= 30_000_000_000):
            publish({"session_id": sid, "tool": tool, "status": raw_state[0], "message": raw_state[1], "attended": False, "_claude_instance": instances.get(sid)}, observed, source="runtime", try_send=try_send)
            prior.update(state=state, raw_state=raw_state, reported_ns=observed)
    listed = getattr(client, "listed", None) or set(states)
    for sid in set(previous) - set(states):
        prior = previous[sid]
        if sid in listed:
            continue  # Still running, in a state we can't read: keep what was reported.
        if tool == "codex" and prior.get("state", ("idle",))[0] != "idle":
            record = read_json(root() / (sid + ".json"), {})
            if record.get("codex_parent"):
                # A spawned agent's thread that unloads reports nothing more: say it ended,
                # so its parent's list doesn't keep it working.
                missing_since = prior.setdefault("missing_since_ns", observed)
                if observed - missing_since < CODEX_CHILD_GONE_NS:
                    continue
                previous.pop(sid)
                if record.get("body", {}).get("event_timestamp_ns", 0) < missing_since:
                    publish({"session_id": sid, "tool": tool, "status": "idle", "message": None, "attended": False},
                            observed, source="runtime", try_send=try_send)
                continue
        if tool != "claude" or prior.get("state", ("idle",))[0] == "idle":
            previous.pop(sid)
            continue
        if not listed:
            prior.pop("missing_since_ns", None)
            continue
        missing_since = prior.setdefault("missing_since_ns", observed)
        if observed - missing_since >= VANISHED_NS:
            previous.pop(sid)
            record = read_json(root() / f"claude.{sid}.json", {})
            if record.get("source") != "runtime" and record.get("body", {}).get("event_timestamp_ns", 0) >= missing_since:
                continue  # A hook reported after the listing lost it; that report stands.
            publish({"session_id": sid, "tool": tool, "status": "idle", "message": None, "attended": False}, observed, source="runtime", try_send=try_send)
    return len(effective)


def watch():
    previous = {}
    client = None
    enabled = set(os.environ.get("AI_TODO_MONITOR_TOOLS", "claude,codex").split(","))
    def delivery_loop():
        while True:
            try:
                summary = retry_pending(budget=2, respect_backoff=True)
                atomic_json(root() / "delivery.json", dict(summary, checked_ns=time.time_ns()))
            except OSError:
                pass
            time.sleep(1)

    threading.Thread(target=delivery_loop, daemon=True).start()
    def claude_loop():
        client, previous = None, {}
        while True:
            health = {"checked_ns": time.time_ns(), "runtime_connected": False}
            try:
                if client is None:
                    client = ClaudeRuntime()
                health["threads"] = poll_runtime(client, previous, try_send=False, tool="claude")
                health["runtime_connected"] = True
            except (OSError, ValueError, subprocess.TimeoutExpired):
                client = None
            atomic_json(root() / "claude-health.json", health)
            time.sleep(1 if health["runtime_connected"] else 5)
    if "claude" in enabled:
        threading.Thread(target=claude_loop, daemon=True).start()
    def reap_loop():
        while True:
            time.sleep(60)
            try:
                reap_backends()
            except (OSError, ValueError):
                pass
    if "codex" in enabled:
        threading.Thread(target=reap_loop, daemon=True).start()
    def resume_loop():
        import ai_todo_resume
        while True:
            time.sleep(15)
            try:
                ai_todo_resume.tick()
            except Exception:
                pass  # One bad entry or a hub outage must not stop the loop.
    threading.Thread(target=resume_loop, daemon=True).start()
    while True:
        health = {"protocol_version": 2, "checked_ns": time.time_ns(), "runtime_connected": False}
        try:
            if "codex" in enabled:
                if client is None:
                    client = RuntimePool()
                health["threads"] = poll_runtime(client, previous, try_send=False)
                health["runtime_connected"] = True
        except (OSError, ValueError, EOFError, TimeoutError):
            if client:
                client.close()
            client = None
        health["delivery"] = read_json(root() / "delivery.json", {})
        atomic_json(root() / "health.json", health)
        time.sleep(1)
