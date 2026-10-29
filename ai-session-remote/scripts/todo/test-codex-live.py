#!/usr/bin/env python3
"""Explicit, opt-in native Codex status test (uses the host's existing Codex login/model).

Runs disposable turns against an isolated app-server and a loopback test hub. No user
projects, live conversations, hook definitions, permissions, or tokens are changed.
Usage: python3 test-codex-live.py [--output RESULT.json]
"""
import argparse
import json
import os
from pathlib import Path
import re
import select
import shlex
import shutil
import signal
import subprocess
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import ai_todo_status as status


def run():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output")
    options = parser.parse_args()
    cli = status.find_codex()
    result = {"codex": cli, "cases": [], "passed": False}
    with tempfile.TemporaryDirectory(prefix="ai-codex-status-", dir="/tmp") as directory:
        work = Path(directory)
        records = []
        http_status = [204]

        class Hub(BaseHTTPRequestHandler):
            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                queued = status.read_json(work / "queue" / (body.get("session_id", "") + ".json"), {})
                records.append({"at": time.monotonic(), "origin": queued.get("source", "hook"), "accepted": http_status[0] == 204, **body})
                self.send_response(http_status[0])
                self.end_headers()

            def log_message(self, *args):
                pass

        hub = ThreadingHTTPServer(("127.0.0.1", 0), Hub)
        serving = threading.Thread(target=hub.serve_forever, daemon=True)
        serving.start()
        conf = work / "hub.conf"
        conf.write_text("TODO_HUB_URL='http://127.0.0.1:%s'\n" % hub.server_port)
        env = os.environ.copy()
        env.update(AI_TODO_HUB_CONF=str(conf), AI_TODO_STATUS_DIR=str(work / "queue"), AI_TODO_CODEX_SOCKET=str(work / "runtime.sock"), AI_TODO_MONITOR_TOOLS="codex")
        env["PATH"] = str(Path(cli).parent) + os.pathsep + env.get("PATH", "")
        model = None
        config_path = status.codex_home() / "config.toml"
        if config_path.exists():
            match = re.search(r'^model\s*=\s*"([^"]+)"', config_path.read_text(), re.M)
            model = match.group(1) if match else None
        log = open(work / "runtime.log", "w+")
        process = subprocess.Popen([cli, "app-server", "-c", "notify=[]", "--listen", "unix://" + str(work / "runtime.sock")], env=env, stdin=subprocess.DEVNULL, stdout=log, stderr=log, start_new_session=True)
        watcher = subprocess.Popen([os.sys.executable, str(Path(__file__).with_name("ai-todo-status")), "watch"], env=env,
                                   stdin=subprocess.DEVNULL, stdout=log, stderr=log, start_new_session=True)
        control = observer = None
        sid = turn_id = None
        environment_patch = {key: os.environ.get(key) for key in ["AI_TODO_STATUS_DIR", "AI_TODO_HUB_CONF"]}
        os.environ.update(AI_TODO_STATUS_DIR=str(work / "queue"), AI_TODO_HUB_CONF=str(conf))
        try:
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline:
                if process.poll() is not None:
                    raise RuntimeError("native app-server exited before initialization")
                try:
                    control = status.RuntimeSocket(work / "runtime.sock", timeout=10, experimental=True)
                    break
                except (OSError, ValueError, EOFError):
                    time.sleep(0.2)
            if control is None:
                raise RuntimeError("native runtime did not become ready")
            observer = status.RuntimeSocket(work / "runtime.sock", timeout=10)
            configured = control.call("hooks/list", {"cwds": [str(work)]})
            ours = [h for entry in configured.get("data", []) for h in entry.get("hooks", []) if "ai-todo-hook" in h.get("command", "")]
            result["trusted_status_hooks"] = sum(h.get("trustStatus") == "trusted" for h in ours)
            params = {"cwd": str(work), "approvalPolicy": "never", "sandbox": "workspace-write"}
            if model:
                params["model"] = model
            started = control.call("thread/start", params)
            sid = started["thread"]["id"]
            model = model or started.get("model")
            result["test_thread"] = sid

            def wait_for_delivery(value, start, seconds=7):
                deadline = time.monotonic() + seconds
                while time.monotonic() < deadline:
                    accepted = [r for r in records[start:] if r.get("session_id") == sid and r["accepted"]]
                    if accepted and accepted[-1]["status"] == value:
                        return True
                    time.sleep(0.1)
                return False

            def exercise(name, prompt, approval="never", interrupt=False):
                nonlocal turn_id
                start = len(records)
                if name == "offline_completion":
                    http_status[0] = 503
                turn_params = {"threadId": sid, "approvalPolicy": approval,
                               "input": [{"type": "text", "text": prompt}]}
                if name == "question":
                    turn_params["collaborationMode"] = {"mode": "plan", "settings": {"model": model}}
                begin = control.call("turn/start", turn_params)
                turn_id = begin["turn"]["id"]
                observed = []
                approval_seen = False
                question_seen = False
                interrupted = False
                completed = False
                command_started = False
                deadline = time.monotonic() + 150
                while time.monotonic() < deadline:
                    states = observer.states()
                    current = states.get(sid)
                    if current and (not observed or observed[-1] != current[0]):
                        observed.append(current[0])
                    if interrupt and command_started and not interrupted:
                        wait_for_delivery("busy", start)
                        control.call("turn/interrupt", {"threadId": sid, "turnId": turn_id})
                        interrupted = True
                        # The interrupt response can race the completed notification.
                        continue
                    ready, _, _ = select.select([control.socket], [], [], 0.15)
                    if not ready:
                        if interrupted and current and current[0] == "idle":
                            completed = True
                            break
                        continue
                    event = control.receive()
                    method = event.get("method", "")
                    values = event.get("params", {})
                    if "id" in event and method:
                        if method == "item/commandExecution/requestApproval":
                            # Approve only this test's harmless file marker command.
                            command = values.get("command", "")
                            if isinstance(command, list):
                                command = shlex.join(command)
                            expected = "printf approved > " + str(work / "status-approved-marker") + "; sleep 2"
                            for _ in range(4):
                                words = shlex.split(command)
                                if len(words) == 3 and Path(words[0]).name in ("sh", "zsh", "bash") and words[1] in ("-c", "-lc"):
                                    command = words[2]
                                else:
                                    break
                            if name != "approval" or command != expected:
                                raise RuntimeError("unexpected approval request in live test")
                            approval_seen = True
                            waiting = observer.states().get(sid)
                            if not waiting or waiting[0] != "waiting":
                                raise RuntimeError("runtime did not report waiting on approval")
                            observed.append("waiting")
                            if not wait_for_delivery("waiting", start):
                                raise RuntimeError("monitor did not deliver the pending approval")
                            control.send({"id": event["id"], "result": {"decision": "accept"}})
                        elif method == "item/tool/requestUserInput" and name == "question":
                            question_seen = True
                            current = observer.states().get(sid)
                            if not current or current[0] != "waiting":
                                raise RuntimeError("runtime did not report waiting for user input")
                            observed.append("waiting")
                            if not wait_for_delivery("waiting", start):
                                raise RuntimeError("monitor did not deliver the pending question")
                            answers = {question["id"]: {"answers": ["Continue"]} for question in values.get("questions", [])}
                            control.send({"id": event["id"], "result": {"answers": answers}})
                        else:
                            raise RuntimeError("unexpected client request: " + method)
                    if method == "item/started" and values.get("item", {}).get("type") == "commandExecution":
                        command_started = True
                    if method == "turn/completed" and values.get("turn", {}).get("id") == turn_id:
                        if values["turn"].get("status") == "failed":
                            raise RuntimeError("native test turn failed")
                        completed = True
                        break
                offline_persisted = False
                if name == "offline_completion":
                    deadline = time.monotonic() + 5
                    while time.monotonic() < deadline:
                        queued = status.read_json(work / "queue" / (sid + ".json"), {})
                        if queued.get("pending") and queued.get("body", {}).get("status") == "idle":
                            offline_persisted = True
                            break
                        time.sleep(0.1)
                    http_status[0] = 204
                wait_for_delivery("idle", start, seconds=10)
                delivered = [r["status"] for r in records[start:] if r.get("session_id") == sid and r["accepted"]]
                case = {"name": name, "completed": completed, "runtime_states": observed,
                        "delivered_states": delivered, "hook_busy_seen": any(r["origin"] == "hook" and r["status"] == "busy" for r in records[start:]),
                        "approval_seen": approval_seen, "question_seen": question_seen, "interrupted": interrupted}
                case["passed"] = completed and "busy" in delivered and delivered[-1:] == ["idle"]
                if name == "approval":
                    case["passed"] = case["passed"] and approval_seen and "waiting" in delivered
                if interrupt:
                    case["passed"] = case["passed"] and interrupted
                if name == "question":
                    case["passed"] = case["passed"] and question_seen and "waiting" in delivered
                if name == "offline_completion":
                    case["offline_event_persisted"] = offline_persisted
                    case["passed"] = completed and offline_persisted and delivered[-1:] == ["idle"]
                result["cases"].append(case)
                turn_id = None
                if not case["passed"]:
                    raise RuntimeError(name + " status assertions failed")

            exercise("completion", "Status integration test. Run exactly `/bin/sh -c 'printf status-probe; sleep 1'` with the shell tool, then reply OK. Do not inspect files or change anything.")
            exercise("approval", "Status integration test. Run `/bin/sh -c 'printf approved > " + str(work / "status-approved-marker") + "; sleep 2'` with the shell tool, then reply OK. This is an explicitly authorized disposable file. Do not inspect other files.", approval="untrusted")
            exercise("interruption", "Status integration test. Run `/bin/sleep 20` using the shell tool, then reply OK. Do not inspect or modify files.", interrupt=True)
            exercise("question", "Status integration test. Call request_user_input with one question: 'Continue the status test?' and options 'Continue' and 'Stop'. Wait for the tool answer, then reply OK. Do not inspect files or use shell tools.")
            exercise("offline_completion", "Status integration test. Reply exactly OK without using tools, asking questions, inspecting files or changing anything.")
            result["passed"] = all(case["passed"] for case in result["cases"]) and result["trusted_status_hooks"] >= 7
        except Exception as error:
            result["error"] = str(error)[:300]
        finally:
            if control and sid:
                try:
                    if turn_id:
                        control.call("turn/interrupt", {"threadId": sid, "turnId": turn_id})
                    control.call("thread/archive", {"threadId": sid})
                except (OSError, ValueError, EOFError, TimeoutError):
                    pass
            for client in (control, observer):
                if client:
                    client.close()
            try:
                os.killpg(watcher.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            watcher.wait(timeout=15)
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            process.wait(timeout=15)
            log.close()
            hub.shutdown()
            hub.server_close()
            for key, value in environment_patch.items():
                if value is None:
                    os.environ.pop(key, None)
                else:
                    os.environ[key] = value
            # Only this test thread's compatibility state is removed, never a real session's.
            if sid:
                for suffix in ("", ".sent"):
                    (Path.home() / ".ai-remote/hook-state" / ("codex-" + sid + suffix)).unlink(missing_ok=True)
    output = json.dumps(result, indent=2)
    print(output)
    if options.output:
        Path(options.output).write_text(output)
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(run())
