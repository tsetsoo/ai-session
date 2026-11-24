"""Antigravity operations through the vendor CLI, without handling Google credentials."""
import fcntl
import json
import os
from pathlib import Path
import re
import select
import shlex
import sys
import signal
import subprocess
import struct
import termios
import tempfile
import time
import uuid

import ai_todo_status as status


def environment():
    # Health and quota reads must not update the CLI as a side effect.
    return dict(os.environ, AGY_CLI_DISABLE_AUTO_UPDATE="true")


class ACPError(Exception):
    def __init__(self, code, message):
        self.code = code
        self.message = message


def acp(binary, method, params, timeout=10):
    deadline = time.monotonic() + timeout
    with subprocess.Popen([binary, "acp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                          stderr=subprocess.DEVNULL, env=environment(), start_new_session=True) as child:
        buffer = b""
        try:
            requests = [("initialize", {"protocolVersion": 1, "clientCapabilities": {}}), (method, params)]
            for ident, (operation, payload) in enumerate(requests, 1):
                child.stdin.write(json.dumps({"jsonrpc": "2.0", "id": ident, "method": operation,
                                              "params": payload}).encode() + b"\n")
                child.stdin.flush()
                while True:
                    if b"\n" not in buffer:
                        if not select.select([child.stdout], [], [], max(0, deadline - time.monotonic()))[0]:
                            raise TimeoutError("Antigravity ACP timed out")
                        data = os.read(child.stdout.fileno(), 65536)
                        if not data:
                            raise EOFError("Antigravity ACP exited")
                        buffer += data
                        continue
                    line, buffer = buffer.split(b"\n", 1)
                    response = json.loads(line)
                    if response.get("id") == ident:
                        if "error" in response:
                            raise ACPError(response["error"].get("code"), response["error"].get("message"))
                        result = response["result"]
                        break
            return result
        finally:
            try:
                os.killpg(child.pid, signal.SIGTERM)
                child.wait(timeout=1)
            except subprocess.TimeoutExpired:
                os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass


def login_state(binary):
    try:
        with tempfile.TemporaryDirectory() as directory:
            result = acp(binary, "session/list", {"cwd": directory}, timeout=5)
            return True if isinstance(result.get("sessions"), list) else None
    except ACPError as error:
        return False if error.code == -32000 and error.message == "Authentication required" else None
    except (OSError, EOFError, ValueError, KeyError):
        return None


def allocate(binary, name, cwd):
    # The hub can retry after losing the SSH response. Reuse this todo's allocated ID.
    root = status.root() / "antigravity"
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    path = root / (name.rsplit("/", 1)[-1] + ".json")
    with path.with_suffix(".lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        record = status.read_json(path, {}) or {}
        if record.get("cwd") == cwd and record.get("id"):
            return str(uuid.UUID(record["id"]))
        result = acp(binary, "session/new", {"cwd": cwd, "mcpServers": []}, timeout=20)
        session_id = str(uuid.UUID(result["sessionId"]))
        status.atomic_json(path, {"cwd": cwd, "id": session_id})
        return session_id


def quota_windows(binary):
    with tempfile.TemporaryDirectory() as directory:
        process = subprocess.Popen([binary, "--settings", '{"disableSlashCommands":false}',
                                    "--print", "/usage", "--output-format", "json"],
                                   cwd=directory, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                   stderr=subprocess.DEVNULL, env=environment(), start_new_session=True)
        try:
            raw, _ = process.communicate(timeout=12)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.communicate()
            raise
    if process.returncode:
        raise ValueError("Antigravity quota request failed")
    command = json.loads(raw).get("command") or {}
    if command.get("name") != "usage":
        raise ValueError("Antigravity returned no usage data")
    return parse_windows(command["data"]["groups"])


def parse_windows(groups):
    windows = {}
    kinds = {"weekly": "weekly", "five_hour": "5h", "five-hour": "5h", "5h": "5h", "monthly": "monthly"}
    for group in groups:
        title = group.get("name")
        if not isinstance(title, str) or not title:
            continue
        for bucket in group.get("buckets", []):
            kind = kinds.get(bucket.get("window"))
            remaining = bucket.get("remaining_fraction")
            if not kind or not isinstance(remaining, (int, float)) or not 0 <= remaining <= 1:
                continue
            item = {"kind": kind, "used_percent": round((1 - remaining) * 100, 1), "scope": title}
            if isinstance(bucket.get("reset_time"), str):
                item["resets_at"] = bucket["reset_time"]
            windows[kind, title] = item
    return list(windows.values())


def terminal_settings(helper, sid):
    command = " ".join(shlex.quote(word) for word in (helper, "antigravity", "statusline", sid))
    return {"statusLine": {"type": "command", "command": command, "stack_with_default": True},
            "clearScrollbackOnResize": False}


PANE_FORMAT = "#{?pane_dead,dead,#{pid}:#{pane_id}:#{pane_pid}}"


def pane_identity(target, tmux=None):
    result = subprocess.run((tmux or ["tmux"]) + ["display-message", "-p", "-t", target, PANE_FORMAT],
                            capture_output=True, text=True, timeout=2)
    value = result.stdout.strip()
    return value if result.returncode == 0 and re.fullmatch(r"\d+:%\d+:\d+", value) else None


def pane_state(sid, identity):
    if not identity:
        return None
    path = status.root() / "antigravity" / ("pane-" + sid + ".json")
    state = status.read_json(path, {}) or {}
    return state if state.get("pane") == identity else None


def pane_waits_for_workspace_trust(sid, name, identity):
    if not re.fullmatch(r"ai/antigravity/todo-[a-z0-9-]+", name):
        return False
    allocation = status.root() / "antigravity" / (name.rsplit("/", 1)[-1] + ".json")
    if (status.read_json(allocation, {}) or {}).get("id") != sid:
        return False
    socket = os.environ.get("AI_TODO_TMUX_SOCKET")
    tmux = ["tmux"] + (["-L", socket] if socket else [])
    target = "=" + name + ":"
    launch = subprocess.run(tmux + ["display-message", "-p", "-t", target,
                                   PANE_FORMAT + " #{pane_start_command}"],
                            capture_output=True, text=True, timeout=2)
    pane, _, command = launch.stdout.strip().partition(" ")
    if launch.returncode or pane != identity:
        return False
    arguments = shlex.split(command)
    if ("--conversation", sid) not in zip(arguments, arguments[1:]):
        return False
    snapshot = pane_state(sid, identity)
    if snapshot and snapshot.get("state") == "mismatch":
        return False
    result = subprocess.run(tmux + ["capture-pane", "-p", "-t", target],
                            capture_output=True, text=True, timeout=2)
    return (result.returncode == 0
            and "Do you trust the contents of this project?" in result.stdout
            and "Yes, I trust this folder" in result.stdout
            and "No, exit" in result.stdout
            and pane_identity(target, tmux) == identity)


def refresh_pane(sid, name, identity, timeout=3):
    """Request a TUI redraw through its terminal size, leaving tmux sizing untouched."""
    if not re.fullmatch(r"\d+:%\d+:\d+", identity):
        return False
    root = status.root() / "antigravity"
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (root / ("refresh-" + identity + ".lock")).open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            # The other observer can supply the fresh snapshot for this reconnect.
            return False
        return refresh_pane_locked(sid, name, identity, timeout)


def refresh_pane_locked(sid, name, identity, timeout):
    socket = os.environ.get("AI_TODO_TMUX_SOCKET")
    tmux = ["tmux"] + (["-L", socket] if socket else [])
    target = "=" + name + ":"
    result = subprocess.run(tmux + ["display-message", "-p", "-t", target,
                                   PANE_FORMAT + " #{pane_tty} #{pane_start_command}"],
                            capture_output=True, text=True, timeout=2)
    fields = result.stdout.strip().split(maxsplit=2)
    if (result.returncode or len(fields) != 3 or fields[0] != identity
            or "clearScrollbackOnResize" not in fields[2]):
        return False
    with open(fields[1], "rb", buffering=0, opener=lambda path, flags: os.open(path, flags | os.O_NOCTTY)) as tty:
        old_size = fcntl.ioctl(tty, termios.TIOCGWINSZ, bytes(8))
        rows, columns, x_pixels, y_pixels = struct.unpack("HHHH", old_size)
        if not rows or not 1 < columns < 65535:
            return False
        probe_size = struct.pack("HHHH", rows, columns + 1, x_pixels, y_pixels)
        observed_after = time.time_ns()
        interrupted = False

        def cancel(_signum, _frame):
            nonlocal interrupted
            interrupted = True

        handlers = {sig: signal.signal(sig, cancel) for sig in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT)}
        previous_mask = signal.pthread_sigmask(signal.SIG_UNBLOCK, handlers)
        try:
            if interrupted:
                return False
            fcntl.ioctl(tty, termios.TIOCSWINSZ, probe_size)
            deadline = time.monotonic() + timeout
            while not interrupted and time.monotonic() < deadline:
                snapshot = pane_state(sid, identity)
                if snapshot and snapshot.get("observed_ns", 0) >= observed_after:
                    if snapshot.get("state") == "mismatch":
                        return False
                    if snapshot.get("terminal_width") == columns + 1 and snapshot.get("state") in ("idle", "busy", "waiting"):
                        return True
                time.sleep(0.1)
            return False
        finally:
            try:
                if fcntl.ioctl(tty, termios.TIOCGWINSZ, bytes(8)) == probe_size:
                    fcntl.ioctl(tty, termios.TIOCSWINSZ, old_size)
            finally:
                signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
                for sig, handler in handlers.items():
                    signal.signal(sig, handler)


def prompt_path(sid):
    return status.root() / "antigravity" / ("prompt-" + sid)


def remember_prompt(sid, message):
    path = prompt_path(sid)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    with path.with_suffix(".lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if not path.exists() and not path.with_suffix(".accepted").exists():
            with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as pending:
                pending.write(message)
            os.replace(pending.name, path)


def user_request_text(content):
    """Extract the user request from agy's transcript envelope."""
    wrapped = re.fullmatch(
        r"<USER_REQUEST>\n(.*)\n</USER_REQUEST>"
        r"(?:\n<ADDITIONAL_METADATA>\n.*?\n</ADDITIONAL_METADATA>)?"
        r"(?:\n<USER_SETTINGS_CHANGE>\n.*?\n</USER_SETTINGS_CHANGE>)?\n*",
        content, flags=re.DOTALL,
    )
    return wrapped.group(1) if wrapped else content


def pending_prompt(sid):
    path = prompt_path(sid)
    if not path.exists():
        return None
    with path.with_suffix(".lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if not path.exists():
            return None
        receipt = path.with_suffix(".accepted")
        if receipt.exists():
            path.unlink()
            return None
        text = path.read_bytes().decode().rstrip("\n")
        transcript = (Path.home() / ".gemini/antigravity-cli/brain" / sid /
                      ".system_generated/logs/transcript.jsonl")
        if transcript.is_file():
            with transcript.open(errors="replace") as handle:
                for line in handle:
                    try:
                        entry = json.loads(line)
                    except ValueError:
                        continue
                    if (isinstance(entry, dict) and entry.get("type") == "USER_INPUT"
                            and entry.get("source") == "USER_EXPLICIT"
                            and isinstance(entry.get("content"), str)
                            and user_request_text(entry["content"]).rstrip("\n") == text):
                        # Keep a receipt so a client retry cannot recreate this prompt.
                        status.atomic_json(receipt, {"accepted": True})
                        path.unlink()
                        return None
        return path


def claim_prompt(sid):
    """Persist the dispatch boundary before passing the message to the CLI."""
    path = prompt_path(sid)
    with path.with_suffix(".lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        dispatched = path.with_suffix(".dispatched")
        if not path.exists() or dispatched.exists() or path.with_suffix(".accepted").exists():
            return None
        message = path.read_bytes().decode().rstrip("\n")
        status.atomic_json(dispatched, {"dispatched": True})
        return message


def dispatch_prompt(sid, argv):
    message = claim_prompt(sid)
    # If another launch already claimed it, open the CLI without sending the text again.
    args = argv if message is None else argv + ["-i", message]
    os.execvp(args[0], args)


def record_pane(sid, state, tasks, terminal_width=None):
    pane = os.environ.get("TMUX_PANE")
    if not pane:
        return
    identity = pane_identity(pane)
    if not identity:
        return
    path = status.root() / "antigravity" / ("pane-" + sid + ".json")
    data = {"pane": identity, "state": state, "tasks": tasks, "terminal_width": terminal_width}
    prior = status.read_json(path, {}) or {}
    now = time.time_ns()
    observed = prior.pop("observed_ns", 0)
    if data != prior or now - observed >= 2_000_000_000:
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        status.atomic_json(path, dict(data, observed_ns=now))


def read_statusline(sid, payload):
    if payload.get("conversation_id") != sid:
        record_pane(sid, "mismatch" if payload.get("conversation_id") else "unknown", 0)
        return
    active = payload.get("agent_state")
    tasks = payload.get("task_count", 0)
    tasks = tasks if isinstance(tasks, int) and tasks >= 0 else 0
    if payload.get("tool_confirmation_pending") is True or active == "reviewing":
        state = "waiting"
    elif active in ("working", "tool_use") or tasks:
        state = "busy"
    elif active in ("idle", "error"):
        state = "idle"
    else:
        record_pane(sid, "unknown", tasks)
        return
    record_pane(sid, state if active != "error" else "unknown", tasks, payload.get("terminal_width"))
    pending_prompt(sid)
    current = status.read_json(status.root() / ("antigravity." + sid + ".json"), {}).get("body", {})
    if current.get("status") != state:
        body = {"tool": "antigravity", "session_id": sid, "status": state}
        if state == "busy" and current.get("status") != "waiting":
            body["_hook_event"] = "UserPromptSubmit"
        status.publish(body, source="runtime", try_send=False)


def main(args, finder):
    try:
        if len(args) == 3 and args[0] == "new" and re.fullmatch(r"ai/antigravity/todo-[a-z0-9-]+", args[1]):
            print(allocate(finder(), args[1], str(Path(args[2]).resolve(strict=True))))
        elif len(args) == 2 and args[0] == "remember-prompt":
            remember_prompt(str(uuid.UUID(args[1])), sys.stdin.buffer.read())
        elif len(args) == 2 and args[0] == "pending-prompt":
            pending = pending_prompt(str(uuid.UUID(args[1])))
            if pending:
                print(pending)
        elif len(args) == 2 and args[0] == "prompt-state":
            sid = str(uuid.UUID(args[1]))
            pending = pending_prompt(sid)
            if not pending:
                print("none")
            elif pending.with_suffix(".dispatched").exists():
                print("uncertain")
            else:
                print("unsent")
        elif len(args) >= 4 and args[0] == "dispatch-prompt" and args[2] == "--":
            dispatch_prompt(str(uuid.UUID(args[1])), args[3:])
        elif len(args) == 4 and args[0] == "refresh-pane":
            return 0 if refresh_pane(str(uuid.UUID(args[1])), args[2], args[3]) else 1
        elif args == ["observation-start"]:
            print(time.time_ns())
        elif len(args) == 4 and args[0] == "workspace-trust":
            return 0 if pane_waits_for_workspace_trust(str(uuid.UUID(args[1])), args[2], args[3]) else 1
        elif len(args) in (3, 4) and args[0] == "ready":
            snapshot = pane_state(str(uuid.UUID(args[1])), args[2])
            if snapshot and snapshot.get("state") == "mismatch":
                return 2
            after = int(args[3]) if len(args) == 4 else 0
            return 0 if (snapshot and snapshot.get("observed_ns", 0) >= after
                         and snapshot.get("state") in ("idle", "busy", "waiting")) else 1
        elif len(args) == 3 and args[0] == "settings":
            print(json.dumps(terminal_settings(str(Path(args[1]).resolve()), str(uuid.UUID(args[2])))))
        elif len(args) == 2 and args[0] == "statusline":
            payload = json.load(sys.stdin)
            if isinstance(payload, dict):
                read_statusline(str(uuid.UUID(args[1])), payload)
        elif args == ["quota"]:
            print(json.dumps(quota_windows(finder())))
        else:
            return 64
    except (OSError, EOFError, ValueError, KeyError, ACPError, subprocess.TimeoutExpired):
        return 75
    return 0
