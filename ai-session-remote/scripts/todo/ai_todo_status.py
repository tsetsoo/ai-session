"""Claude/Codex runtime status, an ordered durable outbox, and local-only RPC transport.

No third-party packages. Tokens are read only at delivery time and never written to the
outbox or log. The monitor reads metadata; it never resumes threads or submits prompts.
"""
import base64
import contextlib
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
    path = Path(os.environ.get("AI_TODO_HUB_CONF", str(Path.home() / ".ai-remote" / "todo-hub.conf")))
    values = {}
    for line in path.read_text().splitlines():
        words = shlex.split(line, comments=True)
        if words[:1] == ["export"]:
            words = words[1:]
        if len(words) == 1 and "=" in words[0]:
            key, value = words[0].split("=", 1)
            values[key] = value
    url = values.get("TODO_HUB_URL", "").rstrip("/")
    if not url.startswith(("http://", "https://")):
        raise ValueError("TODO_HUB_URL is missing or invalid")
    return url, values.get("TODO_API_TOKEN", "")


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


def runtime_status(status):
    kind = status.get("type")
    if kind == "active":
        flags = set(status.get("activeFlags", []))
        if "waitingOnApproval" in flags:
            return "waiting", "Codex needs approval"
        if "waitingOnUserInput" in flags:
            return "waiting", "Codex needs your answer"
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


def publish(body, observed_ns=None, source="hook", try_send=True):
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
    observed = int(observed_ns if observed_ns is not None else time.time_ns())
    if not 0 <= observed <= 2**63 - 1:
        raise ValueError("invalid event timestamp")
    with session_lock(sid, tool=tool) as path:
        previous = read_json(path, {})
        previous_body = previous.get("body", {})
        previous_time = previous_body.get("event_timestamp_ns", -1)
        previous_turn = previous_body.get("turn_started_ns", 0)
        turn_started = max(previous_turn, observed if hook_event == "UserPromptSubmit" else 0)
        new_turn = turn_started > previous_turn
        overridden = False
        if source != "runtime" and hook_event != "UserPromptSubmit":
            snapshot = fresh_runtime_state(sid, tool)
            if snapshot and snapshot[0] >= turn_started:
                observed, state = snapshot
                body["status"], body["message"] = state
                if body["message"] is None:
                    body.pop("message", None)
                overridden = True
        if previous_time > observed or (previous_time == observed and previous_body.get("status") != body["status"]):
            if not new_turn:
                sync_legacy_state(sid, previous["body"]["status"], tool=tool)
                return True
            # A runtime heartbeat can overtake the prompt hook. Keep the newer state,
            # but retain the turn identity so a fast/offline result becomes unread once.
            body = dict(previous_body)
            observed = previous_time
        body["event_timestamp_ns"] = observed
        if turn_started:
            body["turn_started_ns"] = turn_started
        attended_ns = previous.get("attended_ns", 0)
        if source != "runtime" and body.get("attended"):
            attended_ns = time.time_ns()
        if source == "runtime" and time.time_ns() - attended_ns < 60_000_000_000:
            body["attended"] = True
        record = {"body": body, "source": source, "pending": True, "attended_ns": attended_ns}
        # Persist before networking; a killed hook must leave the final event recoverable.
        atomic_json(path, record)
        if overridden or source == "runtime":
            sync_legacy_state(sid, body["status"], tool=tool)
        return deliver(path, record) if try_send else False


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
            with session_lock(sid, blocking=False, tool=tool):
                record = read_json(path, {})
                if not record.get("pending"):
                    continue
                body = record.get("body")
                if not isinstance(body, dict) or body.get("session_id") != sid or body.get("status") not in ("idle", "busy", "waiting"):
                    record.update(pending=False, last_error="InvalidOutboxRecord")
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
                    raise ValueError(method + " failed")
                return response.get("result", {})
        raise TimeoutError("runtime request timed out")

    def states(self):
        loaded = self.call("thread/loaded/list", {}).get("data", [])
        result = {}
        for sid in loaded:
            thread = self.call("thread/read", {"threadId": sid, "includeTurns": False}).get("thread", {})
            state = runtime_status(thread.get("status", {}))
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
    tmux = ["tmux"] + (["-L", os.environ["AI_TODO_TMUX_SOCKET"]] if os.environ.get("AI_TODO_TMUX_SOCKET") else [])
    try:
        sessions = subprocess.run(tmux + ["list-sessions", "-F", "#{session_name}"],
                                  capture_output=True, text=True, timeout=5).stdout.split("\n")
    except (OSError, subprocess.TimeoutExpired):
        sessions = []
    by_socket = {terminal_socket(session): session for session in sessions if session}
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
                if record.get("digest") != digest:
                    if any(value[0] != "idle" for value in existing.states().values()):
                        raise ValueError("runtime settings changed while a turn is active")
                    pid = record.get("pid")
                    # Only replace our own idle backend, never an unrelated reused PID.
                    command = subprocess.check_output(["ps", "-p", str(pid), "-o", "command="], text=True)
                    if endpoint not in command or os.getpgid(pid) != pid:
                        raise ValueError("could not verify the previous runtime process")
                    os.killpg(pid, signal.SIGTERM)
                    for _ in range(50):
                        try:
                            os.kill(pid, 0)
                        except ProcessLookupError:
                            break
                        time.sleep(0.1)
                    else:
                        # A listener can close before the process releases thread writer
                        # locks. The verified, idle backend must be gone before resuming.
                        os.killpg(pid, signal.SIGKILL)
                        time.sleep(0.2)
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
            atomic_json(record_path, {"pid": process.pid, "digest": digest})
    os.chdir(cwd)
    os.execv(client_args[0], client_args)


class RuntimePool:
    """Observe the shared daemon plus app terminals with their own MCP settings."""
    def __init__(self):
        self.clients = {}

    def states(self):
        paths = {socket_path()}
        paths.update(path.with_suffix(".sock") for path in (root() / "r").glob("*.json"))
        result = {}
        connected = 0
        for path in sorted(paths):
            try:
                if path not in self.clients:
                    self.clients[path] = RuntimeSocket(path)
                result.update(self.clients[path].states())
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
            check = subprocess.run([candidate, "--version"], capture_output=True, text=True, timeout=4, env=env)
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


class ClaudeRuntime:
    def __init__(self):
        self.cli = find_claude()

    def states(self):
        env = dict(os.environ, PATH=str(Path(self.cli).parent) + os.pathsep + os.environ.get("PATH", ""))
        response = subprocess.run([self.cli, "agents", "--json", "--all"], capture_output=True, text=True, timeout=5, env=env)
        if response.returncode:
            raise OSError("Claude status command failed")
        rows = json.loads(response.stdout)
        if not isinstance(rows, list):
            raise ValueError("invalid Claude status response")
        result = {}
        for row in rows:
            if not isinstance(row, dict):
                continue
            sid = row.get("sessionId")
            if not isinstance(sid, str) or not re.fullmatch(r"[A-Za-z0-9_-]{1,200}", sid):
                continue
            state = claude_status(row)
            if state:
                result[sid] = state
        return result


def poll_runtime(client, previous, try_send=True, tool="codex"):
    states = client.states()
    observed = time.time_ns()
    effective = {}
    for sid, state in states.items():
        prior = previous.setdefault(sid, {})
        if state[0] == "idle":
            idle_since = prior.setdefault("idle_since_ns", observed)
            if observed - idle_since < 1_000_000_000:
                # A newly queued turn can briefly retain idle before the runtime starts it.
                # Confirm idle once more so that gap cannot emit a false completion/review.
                if prior.get("state"):
                    effective[sid] = prior["state"]
                continue
        else:
            prior.pop("idle_since_ns", None)
        effective[sid] = state
    atomic_json(root() / ("claude-runtime.json" if tool == "claude" else "runtime.json"), {"observed_ns": observed, "threads": effective})
    for sid, state in effective.items():
        prior = previous[sid]
        if tuple(prior.get("state", ())) != tuple(state) or observed - prior.get("reported_ns", 0) >= 30_000_000_000:
            publish({"session_id": sid, "tool": tool, "status": state[0], "message": state[1], "attended": False}, observed, source="runtime", try_send=try_send)
            prior.update(state=state, reported_ns=observed)
    for sid in set(previous) - set(states):
        previous.pop(sid)
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
