#!/usr/bin/env python3
"""Offline status regressions: no accounts, real homes or production hub requests."""
import concurrent.futures
import json
import os
from pathlib import Path
import tempfile
import subprocess
import sys
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from unittest.mock import patch

import ai_todo_status as status


class StatusTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.home = Path(self.temp.name)
        self.environment = patch.dict(os.environ, {"HOME": str(self.home), "AI_TODO_STATUS_DIR": str(self.home / "queue")})
        self.environment.start()
        self.requests = []
        self.http_status = 204
        owner = self

        class Hub(BaseHTTPRequestHandler):
            def do_POST(self):
                owner.requests.append(json.loads(self.rfile.read(int(self.headers["Content-Length"]))))
                self.send_response(owner.http_status)
                self.end_headers()

            def log_message(self, *args):
                pass

        self.hub = ThreadingHTTPServer(("127.0.0.1", 0), Hub)
        self.thread = threading.Thread(target=self.hub.serve_forever, daemon=True)
        self.thread.start()
        conf = self.home / "hub.conf"
        conf.write_text("TODO_HUB_URL='http://127.0.0.1:%s'\nTODO_API_TOKEN='not-a-real-token'\n" % self.hub.server_port)
        os.environ["AI_TODO_HUB_CONF"] = str(conf)

    def tearDown(self):
        self.hub.shutdown()
        self.hub.server_close()
        self.thread.join()
        self.environment.stop()
        self.temp.cleanup()

    def body(self, state, sid="thread-1"):
        return {"session_id": sid, "status": state, "attended": False}

    def record(self, sid="thread-1"):
        return status.read_json(status.root() / (sid + ".json"))

    def test_runtime_distinguishes_work_approval_question_and_disconnected(self):
        self.assertEqual(status.runtime_status({"type": "active", "activeFlags": []}), ("busy", None))
        self.assertEqual(status.runtime_status({"type": "active", "activeFlags": ["waitingOnApproval"]})[0], "waiting")
        self.assertEqual(status.runtime_status({"type": "active", "activeFlags": ["waitingOnUserInput"]})[0], "waiting")
        self.assertEqual(status.runtime_status({"type": "idle"}), ("idle", None))
        self.assertIsNone(status.runtime_status({"type": "notLoaded"}))

    def test_stale_hook_cannot_replace_newer_completion(self):
        status.publish(self.body("busy"), 100, try_send=False)
        status.publish(self.body("idle"), 300, try_send=False)
        status.publish(self.body("waiting"), 200)
        self.assertEqual(self.record()["body"]["status"], "idle")
        self.assertEqual(self.requests, [])
        status.retry_pending()
        self.assertEqual(self.requests[-1]["event_timestamp_ns"], 300)

    def test_failed_final_event_survives_until_an_independent_retry(self):
        self.http_status = 503
        self.assertFalse(status.publish(self.body("idle"), 100))
        self.assertTrue(self.record()["pending"])
        self.assertEqual(self.record()["last_error"], "HTTP 503")
        self.assertNotIn("not-a-real-token", json.dumps(self.record()))
        self.http_status = 204
        self.assertEqual(status.retry_pending(), {"delivered": 1, "pending": 0})
        self.assertFalse(self.record()["pending"])
        self.assertEqual((self.home / ".ai-remote/hook-state/codex-thread-1.sent").read_text().strip(), "idle")

    def test_newer_offline_event_coalesces_an_older_queued_prompt(self):
        self.http_status = 500
        status.publish(self.body("waiting"), 100)
        status.publish(self.body("busy"), 200)
        status.publish(self.body("idle"), 300)
        self.http_status = 204
        status.retry_pending()
        self.assertEqual(self.requests[-1]["status"], "idle")
        self.assertEqual(self.requests[-1]["event_timestamp_ns"], 300)

    def test_a_new_process_retries_an_event_left_by_an_exited_hook(self):
        self.http_status = 503
        helper = str(Path(__file__).with_name("ai-todo-status"))
        failed = subprocess.run([sys.executable, helper, "publish", "--time", "100"],
                                input=json.dumps(self.body("idle")), capture_output=True, text=True)
        self.assertEqual(failed.returncode, 1)
        self.http_status = 204
        retried = subprocess.run([sys.executable, helper, "retry"], capture_output=True, text=True, check=True)
        self.assertEqual(json.loads(retried.stdout), {"delivered": 1, "pending": 0})
        self.assertEqual(self.requests[-1]["status"], "idle")

    def test_runtime_clears_waiting_immediately_after_approval(self):
        observed = time.time_ns()
        status.atomic_json(status.root() / "runtime.json", {"observed_ns": observed, "threads": {"thread-1": ["busy", None]}})
        status.publish(self.body("waiting"), observed + 10)
        self.assertEqual(self.requests[-1]["status"], "busy")
        self.assertNotIn("message", self.requests[-1])

    def test_parallel_tool_completion_cannot_clear_another_pending_prompt(self):
        observed = time.time_ns()
        status.atomic_json(status.root() / "runtime.json", {"observed_ns": observed, "threads": {"thread-1": ["waiting", "Codex needs your answer"]}})
        status.publish(self.body("busy"), observed + 10)
        self.assertEqual(self.requests[-1]["status"], "waiting")
        self.assertEqual(self.requests[-1]["message"], "Codex needs your answer")

    def test_stale_runtime_snapshot_does_not_override_live_hooks(self):
        observed = time.time_ns() - 10_000_000_000
        status.atomic_json(status.root() / "runtime.json", {"observed_ns": observed, "threads": {"thread-1": ["waiting", "old"]}})
        status.publish(self.body("idle"))
        self.assertEqual(self.requests[-1]["status"], "idle")

    def test_concurrent_events_finish_with_the_latest_observation(self):
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            list(pool.map(lambda n: status.publish(self.body("busy" if n < 30 else "idle"), n, try_send=False), range(1, 31)))
        self.assertEqual(self.record()["body"]["event_timestamp_ns"], 30)
        self.assertEqual(self.record()["body"]["status"], "idle")

    def test_two_threads_have_independent_queues(self):
        status.publish(self.body("waiting", "a"), 100, try_send=False)
        status.publish(self.body("idle", "b"), 200, try_send=False)
        self.assertEqual(self.record("a")["body"]["status"], "waiting")
        self.assertEqual(self.record("b")["body"]["status"], "idle")

    def test_runtime_poll_reconciles_but_does_not_guess_an_unloaded_thread(self):
        class Client:
            def states(self):
                return {"a": ("busy", None), "b": ("waiting", "Codex needs approval")}

        previous = {}
        self.assertEqual(status.poll_runtime(Client(), previous), 2)
        self.assertEqual(status.read_json(status.root() / "runtime.json")["threads"]["b"][0], "waiting")
        self.assertEqual(len(self.requests), 2)
        status.poll_runtime(Client(), previous)
        self.assertEqual(len(self.requests), 2, "unchanged polling must not flood the hub")

    def test_recent_attendance_survives_runtime_heartbeats(self):
        body = dict(self.body("busy"), attended=True)
        status.publish(body, source="hook")
        status.publish(self.body("waiting"), source="runtime")
        self.assertTrue(self.requests[-1]["attended"])

    def test_turn_start_idle_gap_does_not_emit_a_false_completion(self):
        class Client:
            value = ("idle", None)
            def states(self):
                return {"a": self.value}

        client = Client()
        previous = {}
        status.poll_runtime(client, previous)
        self.assertEqual(self.requests, [])
        client.value = ("busy", None)
        status.poll_runtime(client, previous)
        self.assertEqual(self.requests[-1]["status"], "busy")
        client.value = ("idle", None)
        status.poll_runtime(client, previous)
        self.assertEqual(self.requests[-1]["status"], "busy")
        with patch.object(status.time, "time_ns", return_value=time.time_ns() + 2_000_000_000):
            status.poll_runtime(client, previous)
        self.assertEqual(self.requests[-1]["status"], "idle")

    def test_bad_session_id_does_not_write_outside_queue(self):
        with self.assertRaises(ValueError):
            status.publish(self.body("idle", "../../secrets"))

    def test_corrupt_outbox_records_do_not_stop_retries_for_other_threads(self):
        status.root().mkdir()
        (status.root() / "broken.json").write_text('{"pending":true}')
        (status.root() / "array.json").write_text('[]')
        status.publish(self.body("idle", "healthy"), 100, try_send=False)
        status.retry_pending()
        self.assertFalse(self.record("healthy")["pending"])
        self.assertEqual(self.record("broken")["last_error"], "InvalidOutboxRecord")

    def test_documented_prefixed_thread_ids_are_supported(self):
        status.publish(self.body("idle", "thr_123"), 100)
        self.assertEqual(self.requests[-1]["session_id"], "thr_123")

    def test_nvm_fallback_skips_a_broken_codex_shim(self):
        broken = self.home / "broken-codex"
        broken.write_text("#!/bin/sh\nexit 1\n")
        broken.chmod(0o755)
        good = self.home / ".nvm/versions/node/v99/bin/codex"
        good.parent.mkdir(parents=True)
        good.write_text("#!/bin/sh\necho codex-cli-test\n")
        good.chmod(0o755)
        with patch.dict(os.environ, {"AI_TODO_CODEX_BIN": str(broken)}), patch.object(status.shutil, "which", return_value=None):
            self.assertEqual(status.find_codex(), str(good))

    def test_remote_terminal_keeps_mcp_and_permissions_on_the_backend(self):
        backend, terminal = status.terminal_arguments(
            ["/codex", "-c", 'mcp_servers.probe.enabled=true', "--cd", "/project",
             "resume", "thread-1", "--approve-for-me"], "unix:///runtime.sock")
        self.assertIn('mcp_servers.probe.enabled=true', backend)
        self.assertIn('approvals_reviewer="auto_review"', backend)
        self.assertIn('sandbox_mode="workspace-write"', backend)
        self.assertNotIn("--approve-for-me", terminal)
        self.assertNotIn('mcp_servers.probe.enabled=true', terminal)
        self.assertEqual(terminal[-4:], ["--cd", "/project", "resume", "thread-1"])

    def test_monitor_combines_shared_and_per_terminal_runtimes(self):
        path = status.root() / "r/test.json"
        status.atomic_json(path, {"pid": 123})
        class Client:
            def __init__(self, endpoint):
                self.endpoint = endpoint
            def states(self):
                return {"own" if self.endpoint == path.with_suffix(".sock") else "shared": ("busy", None)}
            def close(self):
                pass
        with patch.object(status, "RuntimeSocket", Client):
            pool = status.RuntimePool()
            self.assertEqual(set(pool.states()), {"own", "shared"})
            pool.close()

    def test_monitor_closes_connections_when_backend_registry_is_removed(self):
        path = status.root() / "r/test.json"
        status.atomic_json(path, {"pid": 123})
        class Client:
            def __init__(self, endpoint):
                self.closed = False
            def states(self):
                return {}
            def close(self):
                self.closed = True
        with patch.object(status, "RuntimeSocket", Client):
            pool = status.RuntimePool()
            pool.states()
            removed = pool.clients[path.with_suffix(".sock")]
            path.unlink()
            pool.states()
            self.assertTrue(removed.closed)
            self.assertNotIn(path.with_suffix(".sock"), pool.clients)
            pool.close()

    def test_pruning_records_keeps_the_shared_lock_inode(self):
        now = time.time_ns()
        status.publish(self.body("idle"), now - status.PRUNE_SETTLED_NS - 10**9, try_send=False)
        path = status.root() / "thread-1.json"
        lock = path.with_suffix(".lock")
        inode = lock.stat().st_ino
        record = status.read_json(path)
        record["pending"] = False
        status.atomic_json(path, record)
        status.retry_pending()
        self.assertFalse(path.exists())
        self.assertTrue(lock.exists(), "waiting publishers must keep locking the same inode")
        self.assertEqual(lock.stat().st_ino, inode)
        status.publish(self.body("busy"), now, try_send=False)
        self.assertEqual(lock.stat().st_ino, inode)
        self.assertEqual(self.record()["body"]["status"], "busy")

    def test_one_unloaded_thread_does_not_hide_other_runtime_threads(self):
        client = object.__new__(status.RuntimeSocket)
        def call(method, params):
            if method == "thread/loaded/list":
                return {"data": ["gone", "working"]}
            if params["threadId"] == "gone":
                raise status.RuntimeRPCError("thread/read failed")
            return {"thread": {"status": {"type": "active", "activeFlags": []}}}
        client.call = call
        self.assertEqual(client.states(), {"working": ("busy", None)})

    def backend(self, name, argv_endpoint=True):
        """A process started like terminal()'s backends: own session, endpoint in its argv."""
        path = status.terminal_socket(name)
        path.parent.mkdir(parents=True, exist_ok=True)
        argv = [sys.executable, "-c", "import time; time.sleep(300)"] + (["--listen", "unix://" + str(path)] if argv_endpoint else [])
        process = subprocess.Popen(argv, start_new_session=True)
        self.addCleanup(lambda: (process.poll() is None and process.kill(), process.wait()))
        status.atomic_json(path.with_suffix(".json"), {"pid": process.pid, "digest": "d"})
        path.with_suffix(".log").write_text("log")
        return process, path

    def reap(self, sessions, states=None):
        class Client:
            def __init__(self, endpoint):
                self.endpoint = endpoint
            def states(self):
                return (states or {}).get(self.endpoint, {})
            def close(self):
                pass
        with patch.object(status, "tmux_sessions", lambda: sessions), patch.object(status, "RuntimeSocket", Client):
            return status.reap_backends()

    def test_reaper_stops_idle_backends_whose_tmux_session_has_gone(self):
        gone, gone_path = self.backend("ai/codex/todo-gone")
        kept, _ = self.backend("ai/codex/todo-open")
        busy, busy_path = self.backend("ai/codex/todo-busy")
        stranger, _ = self.backend("ai/codex/todo-stranger", argv_endpoint=False)
        stopped = self.reap({"ai/codex/todo-open", "other"}, {busy_path: {"t": ("busy", None)}, gone_path: {"u": ("idle", None)}})
        self.assertEqual(stopped, [gone.pid])
        self.assertIsNotNone(gone.wait(timeout=5))
        self.assertFalse(gone_path.with_suffix(".json").exists() or gone_path.with_suffix(".log").exists())
        # Its session is open, a turn is running, or the pid is not the one on that socket.
        self.assertTrue(all(p.poll() is None for p in (kept, busy, stranger)))
        self.assertTrue(busy_path.with_suffix(".json").exists())

    def test_reaper_does_nothing_without_an_answer_from_tmux_or_while_terminal_holds_the_lock(self):
        process, path = self.backend("ai/codex/todo-gone")
        self.assertEqual(self.reap(None), [])
        with open(path.with_suffix(".lock"), "a") as lock:
            status.fcntl.flock(lock, status.fcntl.LOCK_EX)
            self.assertEqual(self.reap(set()), [])
        self.assertIsNone(process.poll())
        self.assertEqual(self.reap(set()), [process.pid])

    def test_reaper_clears_the_record_of_a_backend_that_already_exited(self):
        process, path = self.backend("ai/codex/todo-dead")
        process.kill()
        process.wait()
        self.assertEqual(self.reap(set()), [])
        self.assertFalse(path.with_suffix(".json").exists())

    def test_terminal_saves_the_folder_as_trusted_once(self):
        class Client:
            def __init__(self, projects):
                self.projects, self.calls = projects, []
            def call(self, method, params):
                self.calls.append((method, params))
                return {"config": {"projects": self.projects}} if method == "config/read" else {}
        fresh = Client({"/other": {"trust_level": "trusted"}})
        status.trust_folder(fresh, "/work/a.b")
        self.assertEqual(fresh.calls[-1], ("config/value/write", {"keyPath": "projects", "mergeStrategy": "upsert",
                                                                 "value": {"/work/a.b": {"trust_level": "trusted"}}}))
        trusted = Client({"/work/a.b": {"trust_level": "trusted"}})
        status.trust_folder(trusted, "/work/a.b")
        self.assertEqual([method for method, _ in trusted.calls], ["config/read"])

    def test_unknown_conversation_is_retried_for_a_day_then_given_up(self):
        self.http_status = 404
        day = status.GIVE_UP_404_NS
        now = time.time_ns()
        for sid, observed in (("thread-old", now - day - 10**9), ("thread-new", now - day + 60 * 10**9)):
            self.assertFalse(status.publish(self.body("idle", sid), observed))
        self.requests.clear()
        status.retry_pending()
        self.assertEqual([r["session_id"] for r in self.requests], ["thread-new"])
        self.assertFalse(self.record("thread-old")["pending"])
        self.assertTrue(self.record("thread-new")["pending"])
        self.assertEqual(status.retry_pending()["pending"], 1)

    def test_settled_records_are_removed_after_a_week(self):
        week = status.PRUNE_SETTLED_NS
        now = time.time_ns()
        old, recent = status.root() / "thread-old.json", status.root() / "thread-recent.json"
        for path, age in ((old, week + 10**9), (recent, week - 60 * 10**9)):
            status.publish(self.body("idle", path.stem), now - age)
            record = status.read_json(path)
            record.update(delivered_ns=now - age, attempted_ns=now - age)
            status.atomic_json(path, record)
        self.assertFalse(self.record("thread-old")["pending"])
        status.retry_pending()
        self.assertFalse(old.exists())
        self.assertTrue(old.with_suffix(".lock").exists())
        self.assertTrue(recent.exists())

    def test_claude_and_codex_with_the_same_id_have_separate_outboxes(self):
        status.publish(self.body("busy"), 100, try_send=False)
        status.publish(dict(self.body("idle"), tool="claude"), 200, try_send=False)
        self.assertEqual(self.record()["body"]["tool"], "codex")
        claude = status.read_json(status.root() / "claude.thread-1.json")
        self.assertEqual(claude["body"]["tool"], "claude")
        self.assertEqual(status.retry_pending(), {"delivered": 2, "pending": 0})
        self.assertEqual({body["tool"] for body in self.requests}, {"claude", "codex"})

    def test_claude_legacy_hook_is_durable_and_ordered(self):
        self.http_status = 503
        status.publish({"claude_session_id": "thread-1", "status": "idle"}, 300)
        status.publish({"claude_session_id": "thread-1", "status": "waiting"}, 200)
        self.http_status = 204
        status.retry_pending()
        self.assertEqual(self.requests[-1]["status"], "idle")
        self.assertEqual(self.requests[-1]["event_timestamp_ns"], 300)
        self.assertEqual((self.home / ".ai-remote/hook-state/thread-1.sent").read_text().strip(), "idle")

    def test_claude_runtime_wins_over_an_incomplete_hook(self):
        observed = time.time_ns()
        status.atomic_json(status.root() / "claude-runtime.json", {
            "observed_ns": observed, "threads": {"thread-1": ["waiting", "Claude needs your answer"]}})
        status.publish(dict(self.body("busy"), tool="claude"), observed + 10)
        self.assertEqual(self.requests[-1]["status"], "waiting")
        self.assertEqual(self.requests[-1]["message"], "Claude needs your answer")
        self.assertFalse((status.root() / "runtime.json").exists())

    def test_claude_background_work_and_blocked_errors_are_distinct(self):
        self.assertEqual(status.claude_status({"status": "idle", "state": "working"}), ("busy", None))
        self.assertEqual(status.claude_status({"state": "blocked"})[0], "waiting")
        self.assertEqual(status.claude_status({"status": "waiting", "waitingFor": "permission prompt"}), ("waiting", "Claude needs approval"))
        self.assertEqual(status.claude_status({"status": "waiting", "waitingFor": "input needed"}), ("waiting", "Claude needs your answer"))
        self.assertEqual(status.claude_status({"state": "done"}), ("idle", None))
        self.assertEqual(status.claude_status({"state": "stopped"}), ("idle", None))
        self.assertEqual(status.claude_status({"state": "failed"})[0], "waiting")
        self.assertIsNone(status.claude_status({"status": "new-unknown-state"}))

    def test_claude_status_command_uses_full_ids_and_metadata_only(self):
        rows = [{"id": "short", "sessionId": "full-id", "state": "done", "name": "private text"},
                {"id": "not-a-full-id", "state": "working"}, {"sessionId": "../bad", "status": "busy"}]
        with patch.object(status, "find_claude", return_value="/claude"), patch.object(status.subprocess, "run") as command:
            command.return_value = subprocess.CompletedProcess([], 0, json.dumps(rows), "")
            self.assertEqual(status.ClaudeRuntime().states(), {"full-id": ("idle", None)})
            self.assertEqual(command.call_args.args[0], ["/claude", "agents", "--json", "--all"])

    def test_runtime_waiting_keeps_the_hooks_prompt_identity(self):
        legacy = self.home / ".ai-remote/hook-state/thread-1"
        legacy.parent.mkdir(parents=True)
        legacy.write_text("waiting 123.456\n")
        status.sync_legacy_state("thread-1", "waiting", tool="claude")
        self.assertEqual(legacy.read_text(), "waiting 123.456\n")
        status.sync_legacy_state("thread-1", "busy", tool="claude")
        self.assertEqual(legacy.read_text(), "busy\n")

    def test_idle_snapshot_cannot_hide_a_fast_new_turn(self):
        observed = time.time_ns()
        for tool in ("claude", "codex"):
            with self.subTest(tool=tool):
                filename = "claude-runtime.json" if tool == "claude" else "runtime.json"
                status.atomic_json(status.root() / filename, {"observed_ns": observed, "threads": {tool: ["idle", None]}})
                status.publish({"tool": tool, "session_id": tool, "status": "busy", "_hook_event": "UserPromptSubmit"}, observed + 10)
                self.assertEqual(self.requests[-1]["status"], "busy")
                self.assertNotIn("_hook_event", self.requests[-1])
                status.publish({"tool": tool, "session_id": tool, "status": "idle", "_hook_event": "Stop"}, observed + 20)
                self.assertEqual(self.requests[-1]["status"], "idle")
                self.assertEqual(self.requests[-1]["turn_started_ns"], observed + 10)

    def test_overtaking_heartbeat_does_not_erase_a_new_turn_identity(self):
        status.publish(self.body("idle"), 300, source="runtime")
        status.publish(dict(self.body("busy"), _hook_event="UserPromptSubmit"), 200)
        self.assertEqual(self.requests[-1]["status"], "idle")
        self.assertEqual(self.requests[-1]["event_timestamp_ns"], 300)
        self.assertEqual(self.requests[-1]["turn_started_ns"], 200)

    def test_offline_coalescing_and_heartbeats_retain_the_latest_turn(self):
        self.http_status = 503
        status.publish(dict(self.body("busy"), _hook_event="UserPromptSubmit"), 100)
        status.publish(dict(self.body("idle"), _hook_event="Stop"), 200)
        status.publish(self.body("idle"), 300, source="runtime")
        self.http_status = 204
        status.retry_pending()
        self.assertEqual(self.requests[-1]["status"], "idle")
        self.assertEqual(self.requests[-1]["turn_started_ns"], 100)

    def test_unknown_claude_wait_reason_shape_does_not_crash_monitor(self):
        self.assertEqual(status.claude_status({"status": "waiting", "waitingFor": {"new": "shape"}}),
                         ("waiting", "Claude needs your attention"))

    def test_invalid_event_timestamp_is_rejected_before_queueing(self):
        for value in (-1, 2**63):
            with self.assertRaises(ValueError):
                status.publish(self.body("busy"), value)


if __name__ == "__main__":
    unittest.main()
