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

    def test_backend_is_replaced_after_an_update_only_when_idle_and_ours(self):
        decide = status.backend_decision
        self.assertEqual(decide(False, False, True, False), "keep", "nothing changed")
        # A newer Codex: replace an idle, verified backend; otherwise open on the old one.
        self.assertEqual(decide(False, True, False, True), "replace")
        self.assertEqual(decide(False, True, True, False), "keep", "a turn is running")
        self.assertEqual(decide(False, True, False, False), "keep", "not provably ours")
        # Changed settings still need a new backend, as before.
        self.assertEqual(decide(True, False, False, True), "replace")
        self.assertEqual(decide(True, True, False, True), "replace")
        with self.assertRaisesRegex(ValueError, "turn is active"):
            decide(True, True, True, False)
        with self.assertRaisesRegex(ValueError, "could not verify"):
            decide(True, False, False, False)

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
        with patch.object(status, "find_claude", return_value="/claude"), patch.object(status, "run_group") as command:
            command.return_value = subprocess.CompletedProcess([], 0, json.dumps(rows), "")
            self.assertEqual(status.ClaudeRuntime().states(), {"full-id": ("idle", None)})
            self.assertEqual(command.call_args.args[0], ["/claude", "agents", "--json", "--all"])

    def test_timed_out_command_takes_its_children_with_it(self):
        # `claude agents` starts keychain lookups; killing only claude left them running.
        marker = self.home / "grandchild.pid"
        script = f"sleep 30 & echo $! > {marker}; wait"
        with self.assertRaises(subprocess.TimeoutExpired):
            status.run_group(["/bin/sh", "-c", script], timeout=0.5)
        grandchild = int(marker.read_text())
        for _ in range(20):
            try:
                os.kill(grandchild, 0)
            except ProcessLookupError:
                break
            time.sleep(0.05)
        else:
            os.kill(grandchild, 9)
            self.fail("the timed-out command's child was left running")

    def test_run_group_returns_output_and_exit_code(self):
        result = status.run_group(["/bin/sh", "-c", "echo out; exit 3"], timeout=5)
        self.assertEqual((result.returncode, result.stdout), (3, "out\n"))

    def claude_rows(self, rows):
        with patch.object(status, "find_claude", return_value="/claude"), patch.object(status, "run_group") as command:
            command.return_value = subprocess.CompletedProcess([], 0, json.dumps(rows), "")
            runtime = status.ClaudeRuntime()
            return runtime.states(), runtime.listed

    def test_claude_duplicate_rows_keep_the_copy_started_last(self):
        # --all keeps a finished background copy beside the terminal that resumed it.
        states, _ = self.claude_rows([
            {"sessionId": "old-bg", "state": "blocked", "kind": "background", "startedAt": 100},
            {"sessionId": "old-bg", "status": "idle", "kind": "interactive", "startedAt": 200},
            {"sessionId": "new-bg", "status": "idle", "kind": "interactive", "startedAt": 100},
            {"sessionId": "new-bg", "state": "blocked", "kind": "background", "startedAt": 200}])
        self.assertEqual(states["old-bg"], ("idle", None))
        self.assertEqual(states["new-bg"][0], "waiting")

    def test_claude_unreadable_status_is_listed_but_not_reported(self):
        states, listed = self.claude_rows([{"sessionId": "a", "status": "compacting"}])
        self.assertEqual(states, {})
        self.assertEqual(listed, {"a"})

    class Listing:
        """A Claude runtime stand-in: `value` is what it reports, `extra` is listed but unreadable."""
        def __init__(self, value, extra=("other",)):
            self.value, self.extra = value, set(extra)
        def states(self):
            self.listed = set(self.value) | self.extra
            return dict(self.value)

    def poll_at(self, client, previous, now, seconds, tool="claude"):
        with patch.object(status.time, "time_ns", return_value=now + int(seconds * 1_000_000_000)):
            status.poll_runtime(client, previous, tool=tool)

    def test_vanished_claude_conversation_is_settled_once_confirmed(self):
        client, previous, now = self.Listing({"a": ("busy", None), "b": ("idle", None)}), {}, time.time_ns()
        self.poll_at(client, previous, now, 0)
        self.assertEqual(self.requests[-1]["status"], "busy")
        client.value = {}
        self.poll_at(client, previous, now, 1)
        self.assertEqual(self.requests[-1]["status"], "busy", "one missing poll is not proof the process ended")
        sent = len(self.requests)
        self.poll_at(client, previous, now, 5)
        self.assertEqual([r["status"] for r in self.requests[sent:] if r["session_id"] == "a"], ["idle"])
        self.assertFalse([r for r in self.requests[sent:] if r["session_id"] == "b"], "an idle conversation needs no report")
        self.poll_at(client, previous, now, 9)
        self.assertEqual(len(self.requests), sent + 1)
        self.assertEqual(previous, {})

    def test_vanished_claude_conversation_that_returns_is_not_settled(self):
        client, previous, now = self.Listing({"a": ("busy", None)}), {}, time.time_ns()
        self.poll_at(client, previous, now, 0)
        client.value = {}
        self.poll_at(client, previous, now, 1)
        client.value = {"a": ("busy", None)}
        self.poll_at(client, previous, now, 5)
        self.assertNotIn("idle", [r["status"] for r in self.requests])

    def test_claude_listed_with_unreadable_status_is_not_settled(self):
        client, previous, now = self.Listing({"a": ("busy", None)}), {}, time.time_ns()
        self.poll_at(client, previous, now, 0)
        client.value, client.extra = {}, {"a"}
        for step in (1, 5, 9):
            self.poll_at(client, previous, now, step)
        self.assertNotIn("idle", [r["status"] for r in self.requests])

    def test_empty_claude_listing_settles_nothing(self):
        client, previous, now = self.Listing({"a": ("busy", None)}), {}, time.time_ns()
        self.poll_at(client, previous, now, 0)
        client.value, client.extra = {}, set()
        for step in (1, 5, 9):
            self.poll_at(client, previous, now, step)
        self.assertNotIn("idle", [r["status"] for r in self.requests], "Claude restarting lists nobody for a moment")

    def test_hook_report_after_vanishing_is_not_overwritten(self):
        client, previous, now = self.Listing({"a": ("busy", None)}), {}, time.time_ns()
        self.poll_at(client, previous, now, 0)
        client.value = {}
        self.poll_at(client, previous, now, 1)
        status.publish({"session_id": "a", "tool": "claude", "status": "waiting", "message": "Claude needs approval"},
                       now + 2_000_000_000)
        self.poll_at(client, previous, now, 5)
        self.assertEqual(self.requests[-1]["status"], "waiting")
        self.assertEqual(status.read_json(status.root() / "claude.a.json")["body"]["status"], "waiting")

    def test_unloaded_codex_thread_is_never_settled(self):
        client, previous, now = self.Listing({"a": ("busy", None)}), {}, time.time_ns()
        self.poll_at(client, previous, now, 0, tool="codex")
        client.value = {}
        for step in (1, 5, 9):
            self.poll_at(client, previous, now, step, tool="codex")
        self.assertNotIn("idle", [r["status"] for r in self.requests], "another Codex runtime may own it")

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

    def claude_completion_fixture(self, tasks=()):
        self.claude_sid = "87e18b12-badf-4b18-ae34-0ea53567be87"
        (status.root() / ("claude." + self.claude_sid + ".json")).unlink(missing_ok=True)
        self.claude_now = time.time_ns()
        self.claude_transcript = self.home / (self.claude_sid + ".jsonl")
        self.claude_transcript.touch()
        client = self.Listing({self.claude_sid: ("busy", None)})
        client.instances = {self.claude_sid: {"kind": "interactive", "pid": 42, "startedAt": 100}}
        previous = {}
        self.poll_at(client, previous, self.claude_now, 0)
        self.claude_hook("UserPromptSubmit", "busy", 1)
        self.poll_at(client, previous, self.claude_now, 1.5)
        self.claude_hook("Stop", "idle", 2, background_tasks=list(tasks),
                         transcript_path=str(self.claude_transcript))
        return client, previous

    def claude_hook(self, event, state, seconds, **metadata):
        observed = self.claude_now + int(seconds * 1_000_000_000)
        with patch.object(status.time, "time_ns", return_value=observed):
            status.publish({"session_id": self.claude_sid, "tool": "claude", "status": state,
                            "_hook_event": event, "_claude": metadata}, observed)

    def claude_transcript_row(self, seconds=3, **extra):
        from datetime import datetime, timezone
        stamp = datetime.fromtimestamp(self.claude_now / 1e9 + seconds, timezone.utc).isoformat()
        row = {"type": "system", "subtype": "stop_hook_summary", "sessionId": self.claude_sid,
               "isSidechain": False, "timestamp": stamp, "preventedContinuation": False,
               "hookErrors": [], "hookAdditionalContext": [], **extra}
        with self.claude_transcript.open("a") as handle:
            handle.write(json.dumps(row) + "\n")

    def test_completed_main_turn_settles_despite_persistent_runtime_busy_and_shell(self):
        client, previous = self.claude_completion_fixture([{"id": "vite", "type": "shell"}])
        self.assertEqual(self.requests[-1]["status"], "busy", "Stop must finish successfully first")
        self.claude_transcript_row()
        for seconds in (4, 35, 70):
            self.poll_at(client, previous, self.claude_now, seconds)
            self.assertEqual(self.requests[-1]["status"], "idle")
        self.assertEqual(client.value[self.claude_sid][0], "busy", "the upstream runtime is unchanged")
        previous.clear()  # Service restart retains the completion fence on disk.
        self.poll_at(client, previous, self.claude_now, 100)
        self.assertEqual(self.requests[-1]["status"], "idle")
        self.assertEqual(self.requests[-1]["turn_started_ns"], self.claude_now + 1_000_000_000)
        self.assertFalse(any(k.startswith("_") for k in self.requests[-1]))

    def test_new_prompt_and_main_tool_continuation_retire_completion(self):
        for event in ("UserPromptSubmit", "PreToolUse"):
            with self.subTest(event=event):
                client, previous = self.claude_completion_fixture()
                self.claude_transcript_row()
                self.poll_at(client, previous, self.claude_now, 4)
                # A heartbeat overtakes a hook started earlier; it must still become busy.
                self.poll_at(client, previous, self.claude_now, 40)
                self.claude_hook(event, "busy", 39)
                self.assertEqual(self.requests[-1]["status"], "busy")
                self.poll_at(client, previous, self.claude_now, 80)
                self.assertEqual(self.requests[-1]["status"], "busy")

    def test_late_stop_cannot_settle_a_new_turn(self):
        client, previous = self.claude_completion_fixture()
        self.claude_transcript_row()
        self.claude_hook("UserPromptSubmit", "busy", 5)
        self.claude_hook("Stop", "idle", 2, background_tasks=[], transcript_path=str(self.claude_transcript))
        self.poll_at(client, previous, self.claude_now, 40)
        self.assertEqual(self.requests[-1]["status"], "busy")

    def test_background_agents_keep_working_until_the_last_one_finishes(self):
        tasks = [{"id": "a", "type": "subagent"}, {"id": "b", "type": "subagent"}, {"id": "vite", "type": "shell"}]
        client, previous = self.claude_completion_fixture(tasks)
        self.claude_transcript_row()
        self.poll_at(client, previous, self.claude_now, 4)
        self.assertEqual(self.requests[-1]["status"], "busy")
        self.claude_hook("SubagentStop", "busy", 5, agent_id="a", background_tasks=tasks[1:])
        self.poll_at(client, previous, self.claude_now, 6)
        self.assertEqual(self.requests[-1]["status"], "busy")
        # The stopping agent may still be in the registry while its hook executes.
        self.claude_hook("SubagentStop", "busy", 7, agent_id="b", background_tasks=tasks[1:])
        self.poll_at(client, previous, self.claude_now, 8)
        self.assertEqual(self.requests[-1]["status"], "idle")
        self.claude_hook("SubagentStart", "busy", 9, agent_id="c")
        self.poll_at(client, previous, self.claude_now, 10)
        self.assertEqual(self.requests[-1]["status"], "busy")

    def test_parent_runtime_idle_does_not_finish_active_background_agents(self):
        client, previous = self.claude_completion_fixture([{"id": "a", "type": "subagent"}])
        self.claude_transcript_row()
        client.value[self.claude_sid] = ("idle", None)
        self.poll_at(client, previous, self.claude_now, 4)
        self.poll_at(client, previous, self.claude_now, 6)
        self.assertEqual(self.requests[-1]["status"], "busy")

    def test_runtime_approval_survives_stop_and_parallel_agent_completion(self):
        client, previous = self.claude_completion_fixture([{"id": "a", "type": "subagent"}])
        self.claude_transcript_row()
        client.value[self.claude_sid] = ("waiting", "Claude needs approval")
        self.poll_at(client, previous, self.claude_now, 4)
        self.claude_hook("SubagentStop", "busy", 5, agent_id="a", background_tasks=[])
        self.assertEqual(self.requests[-1]["status"], "waiting")
        self.poll_at(client, previous, self.claude_now, 40)
        self.assertEqual(self.requests[-1]["status"], "waiting")
        # Answering the approval resumes main work and discards the completion.
        client.value[self.claude_sid] = ("busy", None)
        self.claude_hook("PostToolUse", "busy", 41)
        self.poll_at(client, previous, self.claude_now, 42)
        self.assertEqual(self.requests[-1]["status"], "busy")

    def test_delayed_main_stop_keeps_a_later_agent_completion(self):
        client, previous = self.claude_completion_fixture([{"id": "agent", "type": "subagent"}])
        # Publish a later agent result first, before the main Stop reaches the lock.
        self.claude_hook("SubagentStop", "busy", 4, agent_id="agent", background_tasks=[])
        self.claude_hook("Stop", "idle", 3, background_tasks=[{"id": "agent", "type": "subagent"}],
                         transcript_path=str(self.claude_transcript))
        self.claude_transcript_row(3.5)
        self.poll_at(client, previous, self.claude_now, 5)
        self.assertEqual(self.requests[-1]["status"], "idle")

    def test_permission_hook_beats_stale_busy_and_unrelated_tool_completion(self):
        client, previous = self.claude_completion_fixture([{"id": "agent", "type": "subagent"}])
        self.claude_transcript_row()
        self.claude_hook("PermissionRequest", "waiting", 3.5, agent_id="agent", prompt_id="approval", waiting=True)
        self.assertEqual(self.requests[-1]["status"], "waiting")
        self.poll_at(client, previous, self.claude_now, 4)
        self.claude_hook("PostToolUse", "busy", 5, agent_id="agent", prompt_id="different-tool")
        self.assertEqual(self.requests[-1]["status"], "waiting")
        self.claude_hook("SubagentStop", "busy", 6, agent_id="other-agent", background_tasks=[])
        self.poll_at(client, previous, self.claude_now, 40)
        self.assertEqual(self.requests[-1]["status"], "waiting")
        self.claude_hook("PostToolUse", "busy", 41, agent_id="agent", prompt_id="approval")
        self.assertNotEqual(self.requests[-1]["status"], "waiting")

    def test_runtime_approval_answer_without_tool_hook_requires_new_completion(self):
        client, previous = self.claude_completion_fixture()
        self.claude_transcript_row()
        client.value[self.claude_sid] = ("waiting", "Claude needs approval")
        self.poll_at(client, previous, self.claude_now, 4)
        client.value[self.claude_sid] = ("busy", None)
        self.poll_at(client, previous, self.claude_now, 5)
        self.assertEqual(self.requests[-1]["status"], "busy")

    def test_denied_permission_clears_when_runtime_confirms_idle(self):
        client, previous = self.claude_completion_fixture()
        self.claude_hook("PermissionRequest", "waiting", 3, prompt_id="approval", waiting=True)
        client.value[self.claude_sid] = ("waiting", "Claude needs approval")
        self.poll_at(client, previous, self.claude_now, 4)
        client.value[self.claude_sid] = ("idle", None)
        self.poll_at(client, previous, self.claude_now, 5)
        self.poll_at(client, previous, self.claude_now, 7)
        self.assertEqual(self.requests[-1]["status"], "idle")

    def test_blocked_failed_or_unconfirmed_stop_never_settles_runtime_busy(self):
        for summary in (None, {"preventedContinuation": True}, {"hookErrors": ["blocked"]},
                        {"hookAdditionalContext": ["keep working"]}):
            with self.subTest(summary=summary):
                client, previous = self.claude_completion_fixture()
                if summary is not None:
                    self.claude_transcript_row(**summary)
                self.poll_at(client, previous, self.claude_now, 40)
                self.assertEqual(self.requests[-1]["status"], "busy")

    def test_unknown_task_registry_and_non_shell_work_remain_busy(self):
        for tasks in (None, [None], [{"type": "new-task-kind"}], [{"type": "MCP task"}]):
            with self.subTest(tasks=tasks):
                client, previous = self.claude_completion_fixture()
                self.claude_hook("Stop", "idle", 2.5, background_tasks=tasks, transcript_path=str(self.claude_transcript))
                self.claude_transcript_row()
                self.poll_at(client, previous, self.claude_now, 40)
                self.assertEqual(self.requests[-1]["status"], "busy")

    def test_new_runtime_instance_and_background_job_are_never_settled_by_old_stop(self):
        for change in ({"pid": 43}, {"startedAt": 200}, {"kind": "background"}):
            with self.subTest(change=change):
                client, previous = self.claude_completion_fixture()
                self.claude_transcript_row()
                client.instances[self.claude_sid] = dict(client.instances[self.claude_sid], **change)
                self.poll_at(client, previous, self.claude_now, 40)
                self.assertEqual(self.requests[-1]["status"], "busy")

    def test_a_replacement_runtime_does_not_inherit_an_old_permission_prompt(self):
        client, previous = self.claude_completion_fixture()
        self.claude_hook("PermissionRequest", "waiting", 3, prompt_id="approval", waiting=True)
        self.poll_at(client, previous, self.claude_now, 4)
        self.assertEqual(self.requests[-1]["status"], "waiting")
        client.instances[self.claude_sid] = dict(client.instances[self.claude_sid], pid=999)
        self.poll_at(client, previous, self.claude_now, 5)
        self.assertEqual(self.requests[-1]["status"], "busy")

    def test_transcript_activity_after_successful_stop_invalidates_it_without_hook(self):
        client, previous = self.claude_completion_fixture()
        self.claude_transcript_row()
        self.poll_at(client, previous, self.claude_now, 4)
        self.assertEqual(self.requests[-1]["status"], "idle")
        self.claude_transcript_row(5, type="assistant", subtype=None)
        self.poll_at(client, previous, self.claude_now, 40)
        self.assertEqual(self.requests[-1]["status"], "busy")

    def test_completion_evidence_is_local_and_survives_offline_delivery(self):
        client, previous = self.claude_completion_fixture([{"id": "vite", "type": "shell", "command": "secret", "description": "secret"}])
        self.claude_transcript_row()
        self.http_status = 503
        self.poll_at(client, previous, self.claude_now, 4)
        record = status.read_json(status.root() / ("claude." + self.claude_sid + ".json"))
        self.assertNotIn("secret", json.dumps(record))
        self.assertTrue(record["pending"])
        self.assertNotIn("transcript_path", json.dumps(record["body"]))
        self.http_status = 204
        status.retry_pending()
        self.assertEqual(self.requests[-1]["status"], "idle")

    def test_real_claude_hook_keeps_agent_approval_until_its_own_tool_finishes(self):
        sid = "87e18b12-badf-4b18-ae34-0ea53567be87"
        hook = str(Path(__file__).with_name("ai-todo-hook"))
        env = dict(os.environ, AI_TODO_HOOK_SYNC="1", AI_TODO_TMUX_SESSION="other",
                   AI_TODO_MEMORY_BIN=str(self.home / "no-memory-helper"))
        def call(event, state, tool_id):
            subprocess.run([hook, state], input=json.dumps({"session_id": sid, "hook_event_name": event,
                           "agent_id": "agent", "tool_use_id": tool_id, "tool_name": "Bash"}),
                           env=env, capture_output=True, text=True, check=True)
            return self.requests[-1]["status"]
        self.assertEqual(call("PermissionRequest", "waiting", "approval"), "waiting")
        self.assertEqual(call("PostToolUse", "tool", "other-tool"), "waiting")
        self.assertEqual(call("PostToolUse", "tool", "approval"), "busy")

    def test_unknown_claude_wait_reason_shape_does_not_crash_monitor(self):
        self.assertEqual(status.claude_status({"status": "waiting", "waitingFor": {"new": "shape"}}),
                         ("waiting", "Claude needs your attention"))

    def test_invalid_event_timestamp_is_rejected_before_queueing(self):
        for value in (-1, 2**63):
            with self.assertRaises(ValueError):
                status.publish(self.body("busy"), value)

    # --- Usage-limit pauses ---------------------------------------------------------

    def sofia(self, *args):
        from datetime import datetime
        from zoneinfo import ZoneInfo
        return datetime(*args, tzinfo=ZoneInfo("Europe/Sofia"))

    def test_limit_reset_times_from_real_messages(self):
        now = self.sofia(2026, 10, 16, 19, 20)  # A Friday
        cases = {
            "You've hit your session limit · resets 12:40am (Europe/Sofia)": "2026-10-16T21:40:00Z",
            "You've hit your session limit · resets 6:50pm (Europe/Sofia)": "2026-10-17T15:50:00Z",
            "You've hit your weekly limit · resets Mon 12:00am (Europe/Sofia)": "2026-10-18T21:00:00Z",
            "You've hit your limit · resets 1:40pm (America/New_York)": "2026-10-16T17:40:00Z",
            "You’ve hit your usage limit. Upgrade to Pro (https://chatgpt.com/explore/pro), visit "
            "https://chatgpt.com/settings/usage to purchase more credits or try again at Nov 5th, 2026 1:47 AM.":
                None,  # local time: checked below
            "Claude AI usage limit reached|1793836048": "2026-11-04T23:47:28Z",
        }
        for text, expected in cases.items():
            reset = status.limit_reset_time(text, now)
            self.assertIsNotNone(reset, text)
            if expected:
                self.assertEqual(status._utc_iso(reset), expected, text)
        codex = status.limit_reset_time("try again at Nov 5th, 2026 1:47 AM.", now)
        self.assertEqual((codex.year, codex.month, codex.day, codex.hour, codex.minute), (2026, 11, 5, 1, 47))
        self.assertIsNone(status.limit_reset_time("API Error: Rate limit reached", now))
        self.assertEqual(status.limit_kind("You've hit your weekly limit · resets 1am"), "weekly")
        self.assertEqual(status.limit_kind("5-hour limit reached ∙ resets 8pm"), "session")
        self.assertEqual(status.limit_kind("API Error: Rate limit reached"), "limit")

    def run_claude_hook(self, payload, state="waiting"):
        hook = str(Path(__file__).with_name("ai-todo-hook"))
        env = dict(os.environ, AI_TODO_HOOK_SYNC="1", AI_TODO_TMUX_SESSION="other",
                   AI_TODO_MEMORY_BIN=str(self.home / "no-memory-helper"))
        subprocess.run([hook, state], input=json.dumps(payload), env=env, capture_output=True, text=True, check=True)
        return self.requests[-1]

    def test_claude_usage_limit_is_a_quiet_pause_not_an_error(self):
        sid = "5a1c0b5e-0000-4000-8000-00000000c1a0"
        sent = self.run_claude_hook({
            "session_id": sid, "hook_event_name": "StopFailure", "error": "rate_limit",
            "last_assistant_message": "You've hit your session limit · resets 12:40am (Europe/Sofia)"})
        self.assertEqual(sent["status"], "idle")
        self.assertEqual(sent["paused"]["kind"], "session")
        self.assertRegex(sent["paused"]["resets_at"], r"^\d{4}-\d\d-\d\dT2[12]:40:00Z$")
        self.assertEqual(sent["message"], "Session limit reached")
        self.assertNotIn("_limit", sent)
        # Any other API error still needs you.
        other = self.run_claude_hook({"session_id": sid, "hook_event_name": "StopFailure", "error": "server_error"})
        self.assertEqual(other["status"], "waiting")
        self.assertNotIn("paused", other)

    def test_claude_usage_limit_text_comes_from_the_transcript_when_the_hook_has_none(self):
        sid = "5a1c0b5e-0000-4000-8000-00000000c1a1"
        transcript = self.home / "t.jsonl"
        rows = [
            {"type": "user", "message": {"role": "user", "content": "go"}},
            {"type": "assistant", "error": "rate_limit", "isApiErrorMessage": True, "message": {
                "role": "assistant", "content": [{"type": "text", "text": "You've hit your weekly limit · resets 1am (Europe/Sofia)"}]}},
            {"type": "system", "subtype": "turn_duration"},
        ]
        transcript.write_text("".join(json.dumps(r) + "\n" for r in rows))
        sent = self.run_claude_hook({
            "session_id": sid, "hook_event_name": "StopFailure", "error": "rate_limit",
            "last_assistant_message": "API Error: Rate limit reached", "transcript_path": str(transcript)})
        self.assertEqual((sent["status"], sent["paused"]["kind"]), ("idle", "weekly"))
        self.assertRegex(sent["paused"]["resets_at"], r"T2[23]:00:00Z$")
        # A plain rate limit with no reset anywhere is still a pause, of unknown length.
        transcript.write_text(json.dumps({"type": "user", "message": {"content": "later"}}) + "\n")
        sent = self.run_claude_hook({
            "session_id": sid, "hook_event_name": "StopFailure", "error": "rate_limit",
            "last_assistant_message": "API Error: Rate limit reached", "transcript_path": str(transcript)})
        self.assertEqual(sent["paused"], {"kind": "limit"})
        self.assertEqual(sent["message"], "Usage limit reached")

    def codex_rollout(self, sid, *rows):
        folder = self.home / ".codex/sessions/2026/11/04"
        folder.mkdir(parents=True, exist_ok=True)
        path = folder / ("rollout-2026-11-04T11-51-07-" + sid + ".jsonl")
        path.write_text("".join(json.dumps({"type": "event_msg", "payload": r}) + "\n" for r in rows))
        return path

    def test_codex_usage_limit_pause_uses_the_exhausted_window(self):
        sid = "01a1a5f8-2c43-7a41-9833-5ae1e4f32a22"
        limits = {"limit_id": "codex", "primary": {"used_percent": 100.0, "window_minutes": 300, "resets_at": 1793836048},
                  "secondary": {"used_percent": 19.0, "window_minutes": 10080, "resets_at": 1794404625}}
        error = {"message": "You’ve hit your usage limit. ... try again at Nov 5th, 2026 1:47 AM.",
                 "codex_error_info": "usage_limit_exceeded"}
        self.codex_rollout(sid, {"type": "task_started"}, {"type": "token_count", "rate_limits": limits},
                           {"type": "token_count", "rate_limits": {"limit_id": "premium", "primary": None}},
                           {"type": "task_complete", "error": error})
        status.publish({"tool": "codex", "session_id": sid, "status": "idle", "_hook_event": "Stop"}, 100)
        sent = self.requests[-1]
        self.assertEqual(sent["paused"], {"kind": "session", "resets_at": "2026-11-04T23:47:28Z"})
        self.assertEqual(sent["message"], "Session limit reached")
        # The next turn ran normally: no pause.
        self.codex_rollout(sid, {"type": "task_started"}, {"type": "task_complete", "last_agent_message": "done"})
        status.publish({"tool": "codex", "session_id": sid, "status": "busy", "_hook_event": "UserPromptSubmit"}, 200)
        status.publish({"tool": "codex", "session_id": sid, "status": "idle", "_hook_event": "Stop"}, 300)
        self.assertNotIn("paused", self.requests[-1])

    def test_a_pause_is_never_copied_into_a_later_report(self):
        sid = "5a1c0b5e-0000-4000-8000-00000000c1a2"
        status.publish({"tool": "claude", "session_id": sid, "status": "idle", "_hook_event": "StopFailure",
                        "_limit": {"message": "You've hit your session limit · resets 2am (Europe/Sofia)"}}, 100)
        self.assertIn("paused", self.requests[-1])
        status.publish({"tool": "claude", "session_id": sid, "status": "idle", "paused": {"kind": "weekly"}}, 200,
                       source="runtime")
        self.assertNotIn("paused", self.requests[-1])


if __name__ == "__main__":
    unittest.main()
