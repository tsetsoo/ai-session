"""`ai-todo-status doctor`: what this computer runs, read without changing anything.

The app shows it on a computer's Health page (over SSH), and `ai-todo-status report` sends
the same JSON to the hub so the app has a last-known copy when the computer is offline.

Nothing here starts, stops, logs in or updates anything (`update` only says how it would be
updated; ai_todo_upgrade.py runs it when the user asks). Accounts are reported as logged
in or not and how; e-mail addresses and organisations are left out on purpose.

Installed vs. running: a conversation keeps the binary it started with. `ps` shows the
symlink it was started through (~/.local/bin/claude, …/current/bin/codex), so the running
version comes from the process's executable (/proc/PID/exe, or the first `txt` of lsof),
which still names the version folder after an update deleted it.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request

import ai_todo_status as status

DOCTOR_VERSION = 4
VERSION = re.compile(r"\d+(?:\.\d+)+(?:-[0-9A-Za-z][0-9A-Za-z.]*)?")
# Version folders the installers keep side by side; the first group is the version.
PATH_VERSIONS = [
    re.compile(r"/claude/versions/([^/]+?)(?: \(deleted\))?$"),
    re.compile(r"/app-server-daemon/releases/(\d[^/]*?)-(?:aarch64|x86_64|arm64)[^/]*/"),
    re.compile(r"/cursor-agent/versions/([^/]+)/"),
    re.compile(r"/Cellar/[^/]+/([^/]+)/"),
    re.compile(r"/Caskroom/[^/]+/([^/]+)/"),
]
SERVICE_FILES = ("runtime.json", "health.json", "delivery.json", "claude-runtime.json", "claude-health.json")
IN_FLIGHT_NS = 60_000_000_000
TOOL_NAMES = {"claude": "claude", "codex": "codex", "agent": "cursor", "cursor-agent": "cursor"}


def install_method(path):
    """How the binary at resolved `path` was installed: which updater owns it."""
    if not path:
        return None
    if "/.codex/packages/app-server-daemon/" in path:
        return "managed"
    if "/.local/share/claude/" in path or "/.local/share/cursor-agent/versions/" in path:
        return "native"
    if "/Cellar/" in path or "/Caskroom/" in path or path.startswith(("/opt/homebrew/", "/home/linuxbrew/")):
        return "homebrew"
    if "/node_modules/" in path or "/.nvm/" in path:
        return "npm"
    if ".app/Contents/" in path:
        return "app"
    return "other"


def update_plan(tool, binary, resolved, method):
    """How `tool` at `binary` (resolved to `resolved`) is updated: {"runs": bool, "argv": [...],
    "command": "..."}. `runs` is True only for the updaters this app runs itself (the CLI's
    own, for the installs it owns); for the rest `command` is what the user can run there."""
    home = str(Path.home())
    # As typed in a shell there: ~ stays unquoted so it still expands.
    shown = "~/" + shlex.quote(binary[len(home) + 1:]) if binary.startswith(home + "/") else shlex.quote(binary)
    if method == "native" and tool in ("claude", "cursor"):
        argv = [binary, "update"]
    elif method == "managed" and tool == "codex":
        # The managed package's own updater. It restarts Codex's shared server when that's
        # running; todo conversations have their own backends (terminal()).
        argv = [binary, "app-server", "daemon", "update", "--yes"]
    else:
        argv = None
    if argv:
        return {"runs": True, "argv": argv, "command": " ".join([shown] + [shlex.quote(a) for a in argv[1:]])}
    brew = re.search(r"/(Caskroom|Cellar)/([^/]+)/", resolved or "")
    package = {"claude": "@anthropic-ai/claude-code", "codex": "@openai/codex"}.get(tool)
    if "/node_modules/" in (resolved or ""):
        # npm, also under Homebrew's node (install_method says homebrew for /opt/homebrew/lib/…).
        command = "npm install -g %s@latest" % package if package else shown + " update"
    elif brew:
        command = "brew upgrade " + ("--cask " if brew.group(1) == "Caskroom" else "") + brew.group(2)
    elif method == "app":
        command = None  # updated with its app
    else:
        command = shown + " update"
    return {"runs": False, "argv": None, "command": command}


def package_version(path):
    """The version in the nearest package.json under node_modules (npm installs)."""
    if "/node_modules/" not in path:
        return None
    directory = Path(path).parent
    while "node_modules" in directory.parts:
        manifest = directory / "package.json"
        if manifest.is_file():
            try:
                version = json.loads(manifest.read_text()).get("version")
            except (OSError, ValueError):
                return None
            return version if isinstance(version, str) else None
        directory = directory.parent
    return None


def path_version(path):
    """A version read from where the binary lives, without running it (it may be deleted)."""
    if not path:
        return None
    for pattern in PATH_VERSIONS:
        match = pattern.search(path)
        if match:
            return match.group(1)
    return package_version(path)


def run_text(args, timeout=10, env=None):
    """(exit code, stdout + stderr), or (None, "") when it couldn't run or timed out."""
    try:
        result = status.run_group(args, timeout=timeout, env=env)
    except (OSError, subprocess.TimeoutExpired):
        return None, ""
    return result.returncode, (result.stdout or "") + (result.stderr or "")


def tool_env(binary):
    return dict(os.environ, PATH=str(Path(binary).parent) + os.pathsep + os.environ.get("PATH", ""))


def find_cursor():
    candidates = [os.environ.get("AI_TODO_AGENT_BIN"), shutil.which("agent"), shutil.which("cursor-agent"),
                  str(Path.home() / ".local/bin/agent"), str(Path.home() / ".local/bin/cursor-agent")]
    for candidate in dict.fromkeys(candidates):
        if candidate and os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    raise FileNotFoundError("No Cursor agent binary")


def auth(tool, binary):
    """{"logged_in": True/False/None, "method": ...}; None means the check gave no answer."""
    env = tool_env(binary)
    if tool == "claude":
        code, text = run_text([binary, "auth", "status"], env=env)
        try:
            value = json.loads(text[text.index("{"):]) if "{" in text else {}
        except ValueError:
            value = {}
        if not isinstance(value.get("loggedIn"), bool):
            return {"logged_in": None}
        result = {"logged_in": value["loggedIn"], "method": value.get("authMethod")}
        if isinstance(value.get("loginExpiresAt"), str):
            result["expires_at"] = value["loginExpiresAt"]
        return result
    if tool == "codex":
        code, text = run_text([binary, "login", "status"], env=env)
    else:
        # Every launch uses the file store (ai-todo-open): the keychain one says logged out over SSH.
        env["AGENT_CLI_CREDENTIAL_STORE"] = "file"
        code, text = run_text([binary, "status"], env=env)
    if "Not logged in" in text:
        return {"logged_in": False}
    match = re.search(r"Logged in (?:using|with) (\w+)", text)
    if match:
        return {"logged_in": True, "method": match.group(1)}
    if "Logged in" in text:
        return {"logged_in": True}
    return {"logged_in": None}


def binary_version(binary, resolved):
    """Its version from where it lives, else from `--version`; None when neither says."""
    version = path_version(resolved)
    if version is None:
        code, text = run_text([binary, "--version"], env=tool_env(binary))
        match = VERSION.search(text) if code == 0 else None
        version = match.group(0) if match else None
    return version


def daemon_report(binary):
    """Codex's shared server as the managed `binary` reports it: {"status", "version"}, or None."""
    code, text = run_text([binary, "app-server", "daemon", "version"], env=tool_env(binary))
    try:
        daemon = json.loads(text) if code == 0 else {}
    except ValueError:
        daemon = {}
    if not isinstance(daemon, dict) or not daemon:
        return None
    return {"status": daemon.get("status"), "version": daemon.get("appServerVersion")}


def tool_report(tool, finder):
    """One CLI as this computer would start it: where, which version, who updates it, auth."""
    try:
        binary = finder()
    except FileNotFoundError as error:
        return {"installed": False, "error": str(error)}
    resolved = os.path.realpath(binary)
    version = binary_version(binary, resolved)
    method = install_method(resolved)
    plan = update_plan(tool, binary, resolved, method)
    result = {"installed": True, "path": binary, "resolved": resolved, "version": version,
              "method": method, "auth": auth(tool, binary),
              "update": {"runs": plan["runs"], "command": plan["command"]}}
    if tool == "codex" and result["method"] == "managed":
        daemon = daemon_report(binary)
        if daemon:
            result["daemon"] = daemon
    return result


def helpers_report(bin_dir=None):
    """The installed helpers: install.sh's stamp, plus a digest of the files as they are now,
    so two computers (or a computer and a checkout) can be compared even without git."""
    bin_dir = Path(bin_dir or Path.home() / ".ai-remote" / "bin")
    stamp = status.read_json(bin_dir / "helpers-version.json", {}) or {}
    names = stamp.get("files") if isinstance(stamp.get("files"), list) else None
    if names is None:
        names = sorted(p.name for p in bin_dir.glob("ai[-_]todo*") if p.is_file())
    digest = hashlib.sha256()
    found = 0
    for name in sorted(n for n in names if isinstance(n, str) and "/" not in n):
        try:
            data = (bin_dir / name).read_bytes()
        except OSError:
            continue
        digest.update(name.encode() + b"\0" + hashlib.sha256(data).digest())
        found += 1
    return {"commit": stamp.get("commit"), "dirty": stamp.get("dirty"), "installed_at": stamp.get("installed_at"),
            "digest": digest.hexdigest()[:16] if found else None, "files": found}


def delivery_report(now_ns=None):
    """The status outbox by what it means. A 404 is the hub not knowing that conversation (one
    not linked to a todo; dropped after a day). A fresh record is just being sent. Only the
    rest is a delivery problem."""
    now_ns = now_ns or time.time_ns()
    result = {"in_flight": 0, "unlinked": 0, "failing": 0, "oldest_failing_s": None, "errors": {}}
    for path in status.root().glob("*.json"):
        if path.name in SERVICE_FILES:
            continue
        record = status.read_json(path, {})
        if not record or not record.get("pending"):
            continue
        body = record.get("body") if isinstance(record.get("body"), dict) else {}
        error = record.get("last_error")
        age = now_ns - (body.get("event_timestamp_ns") or record.get("attempted_ns") or now_ns)
        if error == "HTTP 404":
            result["unlinked"] += 1
        elif error is None and age < IN_FLIGHT_NS:
            result["in_flight"] += 1
        else:
            result["failing"] += 1
            key = error or "not sent"
            result["errors"][key] = result["errors"].get(key, 0) + 1
            seconds = max(0, age // 1_000_000_000)
            result["oldest_failing_s"] = max(result["oldest_failing_s"] or 0, seconds)
    return result


def executables(pids):
    """{pid: executable path} for the running `pids` that could be read."""
    pids = sorted({pid for pid in pids if isinstance(pid, int) and pid > 0})
    if not pids:
        return {}
    if os.path.isdir("/proc/self"):
        found = {}
        for pid in pids:
            try:
                found[pid] = os.readlink("/proc/%d/exe" % pid).removesuffix(" (deleted)")
            except OSError:
                continue
        return found
    try:
        listed = subprocess.run([os.environ.get("AI_TODO_LSOF", "lsof"), "-a", "-d", "txt", "-Fpn", "-p",
                                 ",".join(map(str, pids))], capture_output=True, text=True, timeout=10).stdout
    except (OSError, subprocess.TimeoutExpired):
        return {}
    # Per process: p<pid>, then n<path> per txt; the first is the program (the rest are libraries).
    found, current = {}, None
    for line in listed.splitlines():
        if line.startswith("p") and line[1:].isdigit():
            current = int(line[1:])
        elif line.startswith("n") and current is not None and current not in found:
            found[current] = line[1:]
    return found


def processes():
    """{pid: (ppid, argv)} for every process, from one `ps`."""
    try:
        listed = subprocess.run(["ps", "-axo", "pid=,ppid=,command="], capture_output=True, text=True, timeout=10).stdout
    except (OSError, subprocess.TimeoutExpired):
        return {}
    table = {}
    for line in listed.splitlines():
        parts = line.split(None, 2)
        if len(parts) < 2 or not parts[0].isdigit() or not parts[1].isdigit():
            continue
        try:
            argv = shlex.split(parts[2]) if len(parts) == 3 else []
        except ValueError:
            argv = parts[2].split() if len(parts) == 3 else []
        table[int(parts[0])] = (int(parts[1]), argv)
    return table


def tool_of(argv):
    """The CLI an argv runs (claude, codex or cursor), or None. Covers npm's `node …/cli.js`.
    Only argv[0] and argv[1] are looked at; nothing from argv is reported (it can hold keys)."""
    if not argv:
        return None
    first = os.path.basename(argv[0])
    if first in TOOL_NAMES:
        return TOOL_NAMES[first]
    if first.startswith("node") and len(argv) > 1:
        script = argv[1]
        if "/@anthropic-ai/claude-code/" in script:
            return "claude"
        if "/@openai/codex/" in script:
            return "codex"
        return TOOL_NAMES.get(os.path.basename(script))
    return None


def session_of(tool, argv):
    """The conversation id in a launch argv, when it names one."""
    for flag in ("--resume", "--session-id", "-r"):
        if flag in argv[:-1]:
            return argv[argv.index(flag) + 1]
    if tool == "codex" and "resume" in argv[:-1]:
        candidate = argv[argv.index("resume") + 1]
        if not candidate.startswith("-"):
            return candidate
    return None


def panes():
    """{tmux session name: [pane pids]}, or None when tmux can't be asked."""
    tmux = next((c for c in [shutil.which("tmux"), "/opt/homebrew/bin/tmux", "/usr/local/bin/tmux",
                             "/home/linuxbrew/.linuxbrew/bin/tmux"] if c and os.path.isfile(c)), None)
    if not tmux:
        return None
    socket_name = os.environ.get("AI_TODO_TMUX_SOCKET")
    try:
        listed = subprocess.run([tmux] + (["-L", socket_name] if socket_name else [])
                                + ["list-panes", "-a", "-F", "#{session_name}\t#{pane_pid}"],
                                capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if listed.returncode:
        return {} if "no server running" in listed.stderr or "error connecting" in listed.stderr else None
    result = {}
    for line in listed.stdout.splitlines():
        name, _, pid = line.rpartition("\t")
        if name and pid.isdigit():
            result.setdefault(name, []).append(int(pid))
    return result


ASK = object()  # running_report: look it up (None is an answer: tmux couldn't be asked)


def running_report(installed, table=ASK, sessions=ASK, exes=ASK):
    """The agent CLIs running in tmux sessions, each with the version it actually runs.

    `installed` is {tool: version} as a new start would get it. `outdated` is True when the
    running copy is not that version, None when either is unknown. A Codex conversation has
    two processes: the TUI in the pane and the backend terminal() started for that session.
    """
    table = processes() if table is ASK else table
    sessions = panes() if sessions is ASK else sessions
    if sessions is None:
        return None
    children = {}
    for pid, (ppid, _) in table.items():
        children.setdefault(ppid, []).append(pid)
    found = []
    for name, roots in sorted(sessions.items()):
        stack, seen = list(roots), set()
        while stack:
            pid = stack.pop(0)
            if pid in seen or pid not in table:
                continue
            seen.add(pid)
            tool = tool_of(table[pid][1])
            if tool:
                found.append({"tmux": name, "tool": tool, "pid": pid,
                              "session_id": session_of(tool, table[pid][1])})
                break  # the tool's own children (MCP servers, shells) aren't conversations
            stack.extend(sorted(children.get(pid, [])))
    for entry in found:
        if entry["tool"] == "codex":
            record = status.read_json(status.terminal_socket(entry["tmux"]).with_suffix(".json"), {})
            pid = record.get("pid")
            if isinstance(pid, int) and pid in table:
                entry["backend_pid"] = pid
    if exes is ASK:
        exes = executables([e["pid"] for e in found] + [e["backend_pid"] for e in found if "backend_pid" in e])
    for entry in found:
        argv = table[entry["pid"]][1]
        path = exes.get(entry["pid"])
        # npm: the executable is node; the version is the package's that argv[1] belongs to.
        if path and os.path.basename(path).startswith("node") and len(argv) > 1:
            path = os.path.realpath(argv[1])
        entry["path"] = path
        entry["version"] = path_version(path)
        versions = [entry["version"]]
        if "backend_pid" in entry:
            entry["backend_version"] = path_version(exes.get(entry["backend_pid"]))
            versions.append(entry["backend_version"])
        want = installed.get(entry["tool"])
        entry["outdated"] = None if not want or None in versions else any(v != want for v in versions)
    return found


def doctor():
    """Everything above plus the status service checks `ai-todo-status doctor` always had."""
    now = time.time_ns()
    service = status.read_json(status.root() / "health.json", {})
    result = {"doctor_version": DOCTOR_VERSION, "protocol_version": 2, "checked_ns": now,
              "hostname": os.uname().nodename, "codex": None, "runtime_connected": False,
              "status_service": service, "service_running": 0 <= now - service.get("checked_ns", 0) < 8_000_000_000}
    tools = {"claude": tool_report("claude", status.find_claude), "codex": tool_report("codex", status.find_codex),
             "cursor": tool_report("cursor", find_cursor)}
    result["tools"] = tools
    if tools["codex"].get("installed"):
        result["codex"] = tools["codex"]["path"]
    else:
        result["codex_error"] = tools["codex"].get("error")
    try:
        pool = status.RuntimePool()
        try:
            result["runtime_threads"] = len(pool.states())
            result["runtime_connected"] = True
            result["runtime_count"] = len(pool.clients)
            hooks = next(iter(pool.clients.values())).call("hooks/list", {"cwds": [str(Path.home())]})
            result["hooks"] = [{k: hook.get(k) for k in ["eventName", "enabled", "trustStatus"]}
                               for entry in hooks.get("data", []) for hook in entry.get("hooks", [])
                               if "ai-todo-hook" in hook.get("command", "")]
        finally:
            pool.close()
    except (OSError, ValueError, EOFError, TimeoutError) as error:
        result["runtime_error"] = type(error).__name__
    claude_health = status.read_json(status.root() / "claude-health.json", {})
    result["claude_service"] = dict(claude_health, fresh=0 <= now - claude_health.get("checked_ns", 0) < 12_000_000_000)
    if tools["claude"].get("installed"):
        try:
            claude = status.ClaudeRuntime()
            result["claude"] = {"binary": claude.cli, "threads": len(claude.states()), "connected": True}
        except (OSError, ValueError, subprocess.TimeoutExpired) as error:
            result["claude"] = {"connected": False, "error": type(error).__name__}
    else:
        result["claude"] = {"connected": False, "error": "NotInstalled"}
    deliveries = delivery_report(now)
    result["deliveries"] = deliveries
    # Kept for older readers: every record still marked pending, whatever the reason.
    result["pending"] = deliveries["in_flight"] + deliveries["unlinked"] + deliveries["failing"]
    result["helpers"] = helpers_report()
    result["running"] = running_report({tool: value.get("version") for tool, value in tools.items()})
    return result


def report(timeout=10):
    """PUT doctor() to the hub as this computer's health. 0 sent, 1 failed, 3 the hub has no
    such route or computer (an older hub, or TODO_COMPUTER_ID not registered there)."""
    url, token = status.configuration()
    computer = os.environ.get("TODO_COMPUTER_ID") or status.hub_values().get("TODO_COMPUTER_ID")
    if not computer:
        raise ValueError("TODO_COMPUTER_ID is missing")
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = "Bearer " + token
    request = urllib.request.Request(url + "/api/computers/%s/health" % urllib.parse.quote(computer, safe=""),
                                     data=json.dumps(doctor()).encode(), headers=headers, method="PUT")
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return 0 if 200 <= response.status < 300 else 1
    except urllib.error.HTTPError as error:
        return 3 if error.code == 404 else 1
    except (OSError, urllib.error.URLError):
        return 1
