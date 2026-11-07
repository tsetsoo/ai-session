"""`ai-todo-status upgrade TOOL`: install the latest Claude, Codex or Cursor CLI on this
computer, the way it was installed. Only on the user's request (the app's Health page).

    upgrade claude|codex|cursor

It runs the CLI's own updater for the installs it owns (doctor.update_plan): `claude update`
and `agent update` for the native installers, `codex app-server daemon update --yes` for
Codex's managed package, which also moves Codex's shared server to the new version (todo
conversations have their own backends). Anything else (npm, Homebrew, an app bundle) is
not run: the result says so and carries the command to run there.

Nothing running changes: a conversation keeps the version it started with until it's
restarted. No login is needed or touched.

Prints one JSON object: {"tool", "method", "before", "after", "result", "message",
"command"}, plus "daemon" (the shared server's version) for managed Codex; result one of
updated | current | unsupported | failed. Exit 0, or 1 failed.
"""
import fcntl
import os
import re
import signal
import subprocess
import tempfile

import ai_todo_doctor as doctor
import ai_todo_status as status

UPDATE_TIMEOUT_S = 300
FINDERS = {"claude": lambda: status.find_claude(), "codex": lambda: status.find_codex(),
           "cursor": lambda: doctor.find_cursor()}


def installed(tool):
    """(binary, resolved, version, method) as a new conversation would start it, or None."""
    try:
        binary = FINDERS[tool]()
    except FileNotFoundError:
        return None
    resolved = os.path.realpath(binary)
    return binary, resolved, doctor.binary_version(binary, resolved), doctor.install_method(resolved)


def run_updater(argv, env, timeout):
    """(exit code or None on a timeout, combined output). No terminal and no stdin: an
    updater that asks a question gets end of input. Output goes to a file, not a pipe: Codex's
    updater may start the shared server, which would hold a pipe open after the updater ends.
    Only the updater is waited for; on a timeout (300 s) its process group is killed, which
    would include a shared server it started itself (Codex's writes its own daemon log)."""
    with tempfile.TemporaryFile() as output:
        process = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=output, stderr=subprocess.STDOUT,
                                   env=env, start_new_session=True)
        try:
            code = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except (ProcessLookupError, PermissionError):
                pass
            process.wait()
            code = None
        output.seek(0)
        # Bytes: a progress bar cut off mid-character mustn't stop the JSON answer.
        return code, output.read().decode("utf-8", "replace")


def last_lines(text, limit=300):
    """The end of an updater's output, without colour codes or spinner lines, for a message."""
    text = re.sub(r"\x1b\[[0-9;?]*[A-Za-z]|\x1b\][^\x07]*\x07", "", text)
    lines = [line.strip() for line in text.replace("\r", "\n").splitlines() if line.strip()]
    # Download bars (`#####  97.8%`) and spinners say nothing once it's done.
    lines = [line for line in lines if re.search(r"[A-Za-z]{2}", line)]
    tail = " ".join(lines[-3:])
    return tail if len(tail) <= limit else "…" + tail[-(limit - 1):]


def upgrade(tool, timeout=None):
    """The module's docstring; returns (exit code, result)."""
    if tool not in FINDERS:
        raise ValueError("unknown tool")
    found = installed(tool)
    result = {"tool": tool, "method": None, "before": None, "after": None, "command": None}
    if found is None:
        return 1, dict(result, result="failed", message="It isn't installed on this computer.")
    binary, resolved, version, method = found
    plan = doctor.update_plan(tool, binary, resolved, method)
    result.update(method=method, before=version, after=version, command=plan["command"])
    if not plan["runs"]:
        message = ("Update it there with: %s" % plan["command"]) if plan["command"] else \
            "It comes with an app; update that app."
        return 0, dict(result, result="unsupported", message=message)
    limit = UPDATE_TIMEOUT_S if timeout is None else timeout
    try:
        lock_path = status.root() / ("upgrade-%s.lock" % tool)
        lock_path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        with open(lock_path, "a") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                return 1, dict(result, result="failed", message="An update of it is already running.")
            # Read under the lock: an update that just finished has already moved it.
            before = doctor.binary_version(binary, os.path.realpath(binary))
            result.update(before=before, after=before)
            # The installers warn, and Claude's may not finish, when their bin folder isn't on PATH.
            code, output = run_updater(plan["argv"], doctor.tool_env(binary), limit)
    except OSError as error:
        return 1, dict(result, result="failed", message="The update couldn't start: %s." % error)
    now = installed(tool)
    after = now[2] if now else None
    result["after"] = after
    if tool == "codex" and now and now[3] == "managed":
        # The shared server's version after the update (the updater restarts it if it ran).
        daemon = doctor.daemon_report(now[0])
        if daemon and daemon.get("version"):
            result["daemon"] = daemon["version"]
    detail = last_lines(output)
    if code is None or code != 0:
        # Failed even when it switched versions part way: the install may be incomplete.
        why = ("The update didn't finish in %d s." % limit) if code is None else ("The updater exited with %d." % code)
        if after and after != before:
            why += " It now starts %s; check that it works." % after
        return 1, dict(result, result="failed", message=" ".join(filter(None, [why, detail])))
    if after and before and after != before:
        return 0, dict(result, result="updated", message=detail or "Updated.")
    if after is None:
        return 1, dict(result, result="failed", message=" ".join(filter(None, ["Its version can't be read after the update.", detail])))
    if before is None:
        # It was unreadable before, so whether this changed it can't be told: it ran fine.
        return 0, dict(result, result="updated", message=detail or "Updated.")
    return 0, dict(result, result="current", message=detail or "It's already the latest version.")


def main(args):
    if len(args) != 1 or args[0] not in FINDERS:
        return 64, None
    return upgrade(args[0])
