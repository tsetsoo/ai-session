#!/usr/bin/env python3
"""Opt-in native launcher regression: fresh/resumed TUI, MCP and inherited environment.

Uses the existing login/model for one disposable no-tools turn. All settings, tmux,
runtime, project files and test status records are isolated in a temporary home.
"""
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
import time

import ai_todo_status as status


def run():
    cli = status.find_codex()
    auth = status.codex_home() / "auth.json"
    config = (status.codex_home() / "config.toml").read_text()
    model = re.search(r'^model\s*=\s*"([^"]+)"', config, re.M)
    scripts = Path(__file__).resolve().parent
    with tempfile.TemporaryDirectory(prefix="ai-terminal-", dir="/tmp") as directory:
        work = Path(directory).resolve()
        home = work / "home"
        ch = home / ".codex"
        ch.mkdir(parents=True)
        (ch / "auth.json").symlink_to(auth)
        (ch / "config.toml").write_text((('model=' + json.dumps(model[1]) + '\n') if model else '') +
                                       '[projects.' + json.dumps(str(work)) + ']\ntrust_level="trusted"\n')
        binary = ch / "packages/app-server-daemon/current/bin/codex"
        binary.parent.mkdir(parents=True)
        binary.symlink_to(cli)
        mcp = home / ".ai-remote/mcp"
        mcp.mkdir(parents=True)
        (mcp / "env").write_text("STATUS_TEST_ENV=present\n")
        (work / "mcp.py").write_text('''import sys,json,os
from pathlib import Path
for line in sys.stdin:
    m=json.loads(line)
    if "id" not in m: continue
    if m["method"]=="initialize":
        if os.environ.get("STATUS_TEST_ENV")=="present": Path("mcp-env-ok").touch()
        r={"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"serverInfo":{"name":"status-probe","version":"1"}}
    else: r={"tools":[]}
    print(json.dumps({"jsonrpc":"2.0","id":m["id"],"result":r}),flush=True)
''')
        (mcp / "probe.json").write_text(json.dumps({"mcpServers": {"probe": {"command": sys.executable, "args": [str(work / "mcp.py")]}}}))
        conf = work / "hub.conf"
        conf.write_text("TODO_HUB_URL='http://127.0.0.1:1'\n")
        sock = "ai-terminal-" + str(os.getpid())
        env = dict(os.environ, HOME=str(home), CODEX_HOME=str(ch), AI_TODO_STATUS_DIR=str(home / ".ai-remote/status-state"),
                   AI_TODO_TMUX_SOCKET=sock, AI_TODO_OPEN_DETACH="1", AI_TODO_HUB_CONF=str(conf),
                   PATH=str(Path(cli).parent) + ":/opt/homebrew/bin:/usr/local/bin:" + os.environ.get("PATH", ""))
        env.pop("AI_TODO_CODEX_BIN", None)
        env.pop("AI_TODO_CODEX_SOCKET", None)
        control = None
        name = "ai/codex/todo-status-test"
        def tmux(*args):
            return subprocess.check_output(["tmux", "-L", sock, *args], env=env, text=True).strip()
        def open_terminal(sid):
            return subprocess.check_output([str(scripts / "ai-todo-open"), "--mcp", "probe", name, str(work), sid, "codex"],
                                           env=env, text=True, stderr=subprocess.PIPE, timeout=45).strip()
        try:
            created = open_terminal("-")
            assert created.startswith("created "), "fresh launcher did not return a thread ID"
            sid = created.split()[-1]
            registry = list((Path(env["AI_TODO_STATUS_DIR"]) / "r").glob("*.json"))
            assert len(registry) == 1
            control = status.RuntimeSocket(registry[0].with_suffix(".sock"), timeout=10)
            # A fresh TUI reserves an ID before it loads the thread; use one harmless turn.
            tmux("send-keys", "-t", name, "Reply OK without using tools.")
            time.sleep(0.3)
            tmux("send-keys", "-t", name, "Enter")
            deadline = time.monotonic() + 90
            busy = False
            while time.monotonic() < deadline:
                state = control.states().get(sid)
                busy |= bool(state and state[0] == "busy")
                if busy and state and state[0] == "idle":
                    break
                time.sleep(0.2)
            assert busy and control.states().get(sid, [None])[0] == "idle", "terminal turn failed"
            thread = control.call("thread/read", {"threadId": sid, "includeTurns": False})["thread"]
            assert Path(thread["cwd"]).resolve() == work, "wrong working folder"
            servers = control.call("mcpServerStatus/list", {"threadId": sid}).get("data", [])
            assert any(row.get("name") == "probe" for row in servers), "MCP selection was lost"
            assert (work / "mcp-env-ok").exists(), "MCP environment was lost"
            tui_pid = int(tmux("display-message", "-p", "-t", name, "#{pane_pid}"))
            tmux("kill-session", "-t", name)
            for _ in range(50):
                try:
                    os.kill(tui_pid, 0)
                except ProcessLookupError:
                    break
                time.sleep(0.1)
            else:
                os.kill(tui_pid, signal.SIGKILL)
            # Cold resume matters too: a reboot or runtime crash must not depend on an
            # already-loaded thread preserving its original permissions/MCP settings.
            control.close()
            control = None
            os.killpg(status.read_json(registry[0])["pid"], signal.SIGKILL)
            for _ in range(50):
                try:
                    probe = status.RuntimeSocket(registry[0].with_suffix(".sock"), timeout=0.2)
                    probe.close()
                except (OSError, ValueError, EOFError):
                    break
                time.sleep(0.1)
            assert open_terminal(sid) == "resumed"
            time.sleep(3)
            assert tmux("has-session", "-t", name) == "", "resume exited"
            assert tmux("display-message", "-p", "-t", name, "#{pane_dead}") == "0"
            control = status.RuntimeSocket(registry[0].with_suffix(".sock"), timeout=10)
            if sid not in control.states():
                print("Disposable cold-resume screen:", tmux("capture-pane", "-p", "-t", name, "-S", "-40"), flush=True)
                raise AssertionError("cold resume did not load the saved thread")
            print(json.dumps({"passed": True, "fresh": True, "resume": True, "cwd": True, "mcp": True, "mcp_environment": True}))
        finally:
            subprocess.run(["tmux", "-L", sock, "kill-server"], env=env, capture_output=True)
            if control:
                try:
                    for sid in control.call("thread/loaded/list", {}).get("data", []):
                        control.call("thread/archive", {"threadId": sid})
                except (OSError, ValueError):
                    pass
                control.close()
            for path in (Path(env["AI_TODO_STATUS_DIR"]) / "r").glob("*.json"):
                pid = status.read_json(path, {}).get("pid")
                if pid:
                    try:
                        os.killpg(pid, signal.SIGTERM)
                    except ProcessLookupError:
                        pass


if __name__ == "__main__":
    run()
