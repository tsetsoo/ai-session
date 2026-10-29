"""Codex runtime status, an ordered durable outbox, and local-only RPC transport.

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
def session_lock(sid, blocking=True):
    if not re.fullmatch(r"[A-Za-z0-9_-]{1,200}", sid):
        raise ValueError("invalid session id")
    directory = root()
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    with open(directory / (sid + ".lock"), "a") as handle:
        fcntl.flock(handle, fcntl.LOCK_EX | (0 if blocking else fcntl.LOCK_NB))
        yield directory / (sid + ".json")


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


def fresh_runtime_state(sid):
    snapshot = read_json(root() / "runtime.json", {})
    observed = snapshot.get("observed_ns", 0)
    if not 0 <= time.time_ns() - observed < 8_000_000_000:
        return None
    state = snapshot.get("threads", {}).get(sid)
    return (observed, state) if state else None


def sync_legacy_state(sid, status, delivered=False):
    directory = Path.home() / ".ai-remote" / "hook-state"
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / ("codex-" + sid + (".sent" if delivered else ""))
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
        sync_legacy_state(body["session_id"], body["status"], delivered=True)
    except (OSError, ValueError, urllib.error.URLError) as error:
        # Error types/codes only: URLs, credentials and tool inputs do not belong in logs.
        record.update(pending=True, last_error=("HTTP " + str(error.code) if isinstance(error, urllib.error.HTTPError) else type(error).__name__))
        record["attempted_ns"] = time.time_ns()
    atomic_json(path, record)
    return not record["pending"]


def publish(body, observed_ns=None, source="hook", try_send=True):
    sid = body.get("session_id")
    if not isinstance(sid, str):
        raise ValueError("invalid session id")
    if body.get("status") not in ("busy", "idle", "waiting"):
        raise ValueError("invalid status")
    body = dict(body, tool="codex")
    body.pop("claude_session_id", None)
    observed = int(observed_ns if observed_ns is not None else time.time_ns())
    overridden = False
    if source != "runtime":
        snapshot = fresh_runtime_state(sid)
        if snapshot:
            observed, state = snapshot
            body["status"], body["message"] = state
            if body["message"] is None:
                body.pop("message", None)
            overridden = True
    body["event_timestamp_ns"] = observed
    with session_lock(sid) as path:
        previous = read_json(path, {})
        previous_body = previous.get("body", {})
        previous_time = previous_body.get("event_timestamp_ns", -1)
        if previous_time > observed or (previous_time == observed and previous_body.get("status") != body["status"]):
            sync_legacy_state(sid, previous["body"]["status"])
            return True
        attended_ns = previous.get("attended_ns", 0)
        if source != "runtime" and body.get("attended"):
            attended_ns = time.time_ns()
        if source == "runtime" and time.time_ns() - attended_ns < 60_000_000_000:
            body["attended"] = True
        record = {"body": body, "source": source, "pending": True, "attended_ns": attended_ns}
        # Persist before networking; a killed hook must leave the final event recoverable.
        atomic_json(path, record)
        if overridden or source == "runtime":
            sync_legacy_state(sid, body["status"])
        return deliver(path, record) if try_send else False


def retry_pending(budget=None, respect_backoff=False):
    result = {"delivered": 0, "pending": 0}
    deadline = time.monotonic() + budget if budget is not None else float("inf")
    for path in sorted(root().glob("*.json"), key=lambda p: p.stat().st_mtime_ns, reverse=True):
        if time.monotonic() >= deadline:
            break
        if path.name in ("runtime.json", "health.json", "delivery.json"):
            continue
        try:
            with session_lock(path.stem, blocking=False):
                record = read_json(path, {})
                if not record.get("pending"):
                    continue
                body = record.get("body")
                if not isinstance(body, dict) or body.get("session_id") != path.stem or body.get("status") not in ("idle", "busy", "waiting"):
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


def poll_runtime(client, previous, try_send=True):
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
    atomic_json(root() / "runtime.json", {"observed_ns": observed, "threads": effective})
    for sid, state in effective.items():
        prior = previous[sid]
        if tuple(prior.get("state", ())) != tuple(state) or observed - prior.get("reported_ns", 0) >= 30_000_000_000:
            publish({"session_id": sid, "status": state[0], "message": state[1], "attended": False}, observed, source="runtime", try_send=try_send)
            prior.update(state=state, reported_ns=observed)
    for sid in set(previous) - set(states):
        previous.pop(sid)
    return len(effective)


def watch():
    previous = {}
    client = None
    def delivery_loop():
        while True:
            try:
                summary = retry_pending(budget=2, respect_backoff=True)
                atomic_json(root() / "delivery.json", dict(summary, checked_ns=time.time_ns()))
            except OSError:
                pass
            time.sleep(1)

    threading.Thread(target=delivery_loop, daemon=True).start()
    while True:
        health = {"protocol_version": 2, "checked_ns": time.time_ns(), "runtime_connected": False}
        try:
            if client is None:
                client = RuntimeSocket(socket_path())
            health["threads"] = poll_runtime(client, previous, try_send=False)
            health["runtime_connected"] = True
        except (OSError, ValueError, EOFError, TimeoutError):
            if client:
                client.close()
            client = None
        health["delivery"] = read_json(root() / "delivery.json", {})
        atomic_json(root() / "health.json", health)
        time.sleep(1)
