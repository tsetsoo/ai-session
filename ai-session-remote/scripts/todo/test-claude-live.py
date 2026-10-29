#!/usr/bin/env python3
"""Opt-in native Claude status tests using the host's existing login/model.

Disposable session, loopback hub, isolated queue/settings, no project access. Tests
completion, approval, question, interruption, failed tools, outage and saved resume.
"""
import argparse
import json
import os
from pathlib import Path
import queue
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import ai_todo_status as status


def run():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output")
    options = parser.parse_args()
    cli = status.find_claude()
    sid = str(uuid.uuid4())
    result = {"claude": cli, "test_session": sid, "cases": [], "passed": False}
    scripts = Path(__file__).resolve().parent
    with tempfile.TemporaryDirectory(prefix="ai-claude-status-", dir="/tmp") as directory:
        work = Path(directory)
        records, http_status = [], [204]
        class Hub(BaseHTTPRequestHandler):
            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                if body.get("session_id") == sid:
                    records.append(dict(body, accepted=http_status[0] == 204, at=time.monotonic()))
                self.send_response(http_status[0])
                self.end_headers()
            def log_message(self, *args):
                pass
        hub = ThreadingHTTPServer(("127.0.0.1", 0), Hub)
        threading.Thread(target=hub.serve_forever, daemon=True).start()
        conf = work / "hub.conf"
        conf.write_text("TODO_HUB_URL='http://127.0.0.1:%s'\n" % hub.server_port)
        env = dict(os.environ, AI_TODO_HUB_CONF=str(conf), AI_TODO_STATUS_DIR=str(work / "queue"),
                   AI_TODO_MEMORY_BIN="/usr/bin/true", AI_TODO_MONITOR_TOOLS="claude",
                   PATH=str(Path(cli).parent) + os.pathsep + os.environ.get("PATH", ""))
        events = {"UserPromptSubmit": "busy", "PreToolUse": "tool", "PermissionRequest": "waiting",
                  "PostToolUse": "tool", "PostToolUseFailure": "tool", "Stop": "idle", "SessionEnd": "idle",
                  "StopFailure": "waiting", "Elicitation": "waiting", "ElicitationResult": "tool"}
        settings = {"hooks": {event: [{"hooks": [{"type": "command", "command":
                    shlex.quote(str(scripts / "ai-todo-hook")) + " " + state}]}] for event, state in events.items()}}
        user_settings = status.read_json(Path.home() / ".claude/settings.json", {})
        if user_settings.get("model"):
            settings["model"] = user_settings["model"]
        settings_path = work / "settings.json"
        settings_path.write_text(json.dumps(settings))
        log = open(work / "native.log", "w+")
        watcher = subprocess.Popen([sys.executable, str(scripts / "ai-todo-status"), "watch"],
                                   env=env, stdout=log, stderr=log, start_new_session=True)
        process = None
        messages = queue.Queue()

        def send(body):
            process.stdin.write(json.dumps(body) + "\n")
            process.stdin.flush()

        def launch(resume=False):
            nonlocal process, messages
            messages = queue.Queue()
            args = [cli, "-p", "--resume" if resume else "--session-id", sid,
                    "--setting-sources", "", "--settings", str(settings_path), "--strict-mcp-config",
                    "--mcp-config", '{"mcpServers":{}}', "--tools", "Bash,AskUserQuestion",
                    "--permission-mode", "manual", "--output-format", "stream-json",
                    "--input-format", "stream-json", "--verbose", "--permission-prompt-tool", "stdio"]
            process = subprocess.Popen(args, cwd=work, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                       stderr=log, text=True, start_new_session=True)
            def read_stream(stream, mailbox):
                for line in stream:
                    try:
                        mailbox.put(json.loads(line))
                    except ValueError:
                        pass
            threading.Thread(target=read_stream, args=(process.stdout, messages), daemon=True).start()

        def wait_status(wanted, start, seconds=8):
            deadline = time.monotonic() + seconds
            while time.monotonic() < deadline:
                accepted = [r for r in records[start:] if r["accepted"]]
                if accepted and accepted[-1]["status"] == wanted:
                    return True
                time.sleep(0.1)
            return False

        def exercise(name, prompt, command=None):
            start = len(records)
            if name == "offline_completion":
                http_status[0] = 503
            send({"type": "user", "session_id": sid, "parent_tool_use_id": None,
                  "message": {"role": "user", "content": prompt}})
            approval = question = interrupted = working_after_approval = False
            deadline = time.monotonic() + 150
            completed = False
            while time.monotonic() < deadline:
                try:
                    event = messages.get(timeout=0.3)
                except queue.Empty:
                    if process.poll() is not None:
                        raise RuntimeError("Claude exited during " + name)
                    continue
                if event.get("type") == "control_request":
                    request = event.get("request", {})
                    if request.get("subtype") != "can_use_tool":
                        raise RuntimeError("unexpected native control request")
                    tool, inputs = request.get("tool_name"), request.get("input", {})
                    if tool == "Bash" and command and inputs.get("command") == command:
                        approval = True
                        if not wait_status("waiting", start):
                            raise RuntimeError("monitor did not deliver the pending approval")
                        send({"type": "control_response", "response": {"subtype": "success", "request_id": event["request_id"],
                              "response": {"behavior": "allow", "updatedInput": inputs}}})
                        if name in ("approval", "interruption"):
                            working_after_approval = wait_status("busy", len(records), seconds=5)
                            if not working_after_approval:
                                raise RuntimeError("approved tool stayed waiting while it ran")
                        if name == "interruption":
                            send({"type": "control_request", "request_id": "test-interrupt",
                                  "request": {"subtype": "interrupt"}})
                            interrupted = True
                    elif tool == "AskUserQuestion" and name == "question":
                        questions = inputs.get("questions", [])
                        if len(questions) != 1 or questions[0].get("question") != "Continue the status test?":
                            raise RuntimeError("unexpected test question")
                        question = True
                        if not wait_status("waiting", start):
                            raise RuntimeError("monitor did not deliver the pending question")
                        inputs = dict(inputs, answers={"Continue the status test?": "Continue"})
                        send({"type": "control_response", "response": {"subtype": "success", "request_id": event["request_id"],
                              "response": {"behavior": "allow", "updatedInput": inputs}}})
                    else:
                        send({"type": "control_response", "response": {"subtype": "success", "request_id": event["request_id"],
                              "response": {"behavior": "deny", "message": "Outside this disposable test"}}})
                        raise RuntimeError("unexpected tool request in " + name)
                if event.get("type") == "result":
                    if event.get("is_error") and name != "interruption":
                        raise RuntimeError("native Claude turn failed in " + name)
                    completed = True
                    break
            persisted = False
            if name == "offline_completion":
                deadline = time.monotonic() + 5
                while time.monotonic() < deadline:
                    queued = status.read_json(work / "queue" / ("claude." + sid + ".json"), {})
                    if queued.get("pending") and queued.get("body", {}).get("status") == "idle":
                        persisted = True
                        break
                    time.sleep(0.1)
                http_status[0] = 204
            wait_status("idle", start, seconds=10)
            delivered = [r["status"] for r in records[start:] if r["accepted"]]
            passed = completed and delivered[-1:] == ["idle"] and ("busy" in delivered or name == "offline_completion")
            if name == "approval":
                passed &= approval and working_after_approval and "waiting" in delivered
            if name == "question":
                passed &= question and "waiting" in delivered
            if name == "interruption":
                passed &= interrupted
            if name == "offline_completion":
                passed &= persisted
            case = {"name": name, "passed": bool(passed), "delivered_states": delivered,
                    "approval_seen": approval, "question_seen": question, "interrupted": interrupted}
            result["cases"].append(case)
            if not passed:
                raise RuntimeError("status case failed: " + name)

        def stop_process(proc):
            if proc and proc.poll() is None:
                os.killpg(proc.pid, signal.SIGTERM)
                try:
                    proc.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(proc.pid, signal.SIGKILL)
                    proc.wait()
        try:
            launch()
            exercise("completion", "Run exactly `/bin/sleep 2` with Bash, then reply OK. Do not inspect or change files.", "/bin/sleep 2")
            exercise("approval", "Run exactly `/bin/sleep 6` with Bash, then reply OK. Do not inspect or change files.", "/bin/sleep 6")
            exercise("question", "Call AskUserQuestion with exactly one question: 'Continue the status test?' and options Continue and Stop. Wait for the answer, then reply OK. Do not use other tools.")
            exercise("interruption", "Run exactly `/bin/sleep 20` with Bash, then reply OK. Do not inspect or change files.", "/bin/sleep 20")
            exercise("tool_failure", "Run exactly `/usr/bin/false` with Bash once, then reply OK even though it failed. Do not retry, inspect or change files.", "/usr/bin/false")
            exercise("offline_completion", "Reply exactly OK without using any tools.")
            stop_process(process)
            launch(resume=True)
            exercise("saved_resume", "Reply exactly OK without using any tools.")
            result["passed"] = all(case["passed"] for case in result["cases"])
        except Exception as error:
            result["error"] = str(error)[:200]
        finally:
            stop_process(process)
            stop_process(watcher)
            hub.shutdown()
            hub.server_close()
            log.close()
            # Only this UUID's disposable files are removed; no user session is touched.
            claude_home = Path(os.environ.get("CLAUDE_CONFIG_DIR", str(Path.home() / ".claude")))
            for path in (claude_home / "projects").glob("*/" + sid + ".jsonl"):
                path.unlink(missing_ok=True)
            for folder in ("session-env", "tasks", "todos"):
                path = claude_home / folder / sid
                if path.is_dir():
                    shutil.rmtree(path)
            for suffix in ("", ".sent"):
                (Path.home() / ".ai-remote/hook-state" / (sid + suffix)).unlink(missing_ok=True)
    output = json.dumps(result, indent=2)
    print(output)
    if options.output:
        Path(options.output).write_text(output)
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(run())
