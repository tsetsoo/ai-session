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


if __name__ == "__main__":
    unittest.main()
