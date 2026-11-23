#!/usr/bin/env python3
"""Antigravity ACP, quota and status regression tests without production credentials."""
import ast
import json
import time
import re
import signal
import struct
import termios
import threading
import urllib.parse
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch

import ai_todo_antigravity as agy
import ai_todo_restart as restart

SID = "055a398f-db14-4c5f-abbb-1bf03f8120a7"

FAKE = """#!/usr/bin/env python3
import json, sys
if sys.argv[1:] == ["acp"]:
    for line in sys.stdin:
        req = json.loads(line)
        method = req["method"]
        value = {"initialize": {"protocolVersion": 1}, "session/list": {"sessions": []},
                 "session/new": {"sessionId": "%s"}}[method]
        print(json.dumps({"jsonrpc": "2.0", "id": req["id"], "result": value}), flush=True)
elif "/usage" in sys.argv:
    print(json.dumps({"command": {"name": "usage", "data": {"groups": [
        {"name": "Gemini Models", "buckets": [
            {"window": "weekly", "remaining_fraction": 0.75, "reset_time": "2026-11-29T00:00:00Z"}]},
        {"name": "Claude and GPT models", "buckets": [
            {"window": "weekly", "remaining_fraction": 0.5}]}
    ]}}}))
""" % SID


class AntigravityTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.binary = self.root / "agy"
        self.binary.write_text(FAKE)
        self.binary.chmod(0o755)
        env = patch.dict(os.environ, {"AI_TODO_STATUS_DIR": self.temp.name})
        env.start()
        self.addCleanup(env.stop)

    def test_allocates_and_reuses_exact_session(self):
        self.assertTrue(agy.login_state(self.binary))
        self.assertEqual(agy.allocate(self.binary, "ai/antigravity/todo-test", self.temp.name), SID)
        self.binary.unlink()
        self.assertEqual(agy.allocate(self.binary, "ai/antigravity/todo-test", self.temp.name), SID)

    def test_quota_preserves_model_groups(self):
        self.assertEqual(agy.quota_windows(self.binary), [
            {"kind": "weekly", "used_percent": 25, "scope": "Gemini Models",
             "resets_at": "2026-11-29T00:00:00Z"},
            {"kind": "weekly", "used_percent": 50, "scope": "Claude and GPT models"},
        ])

    def test_readiness_and_restart_require_the_live_pane_and_exact_conversation(self):
        identity = "123:%4:567"
        with patch.dict(os.environ, {"TMUX_PANE": "%4"}), patch.object(agy, "pane_identity", return_value=identity):
            self.assertEqual(agy.main(["ready", SID, identity], lambda: self.binary), 1)
            agy.read_statusline(SID, {"conversation_id": SID, "agent_state": "initializing"})
            self.assertEqual(agy.main(["ready", SID, identity], lambda: self.binary), 1)
            agy.read_statusline(SID, {"conversation_id": SID, "agent_state": "idle"})
            self.assertEqual(agy.main(["ready", SID, identity], lambda: self.binary), 0)
            observed = agy.pane_state(SID, identity)["observed_ns"]
            self.assertEqual(agy.main(["ready", SID, identity, str(observed + 1)], lambda: self.binary), 1)
            self.assertEqual(agy.main(["ready", SID, identity, str(observed)], lambda: self.binary), 0)
            self.assertEqual(agy.main(["ready", SID, "123:%4:999"], lambda: self.binary), 1)
            self.assertEqual(agy.main(["ready", SID, "dead"], lambda: self.binary), 1)
            other = "055a398f-db14-4c5f-abbb-1bf03f8120a8"
            self.assertEqual(agy.main(["ready", other, identity], lambda: self.binary), 1)
            with patch.object(restart, "tmux_args", return_value=["tmux"]), patch.object(restart.time, "time_ns", return_value=2**63 - 1):
                self.assertEqual(restart.conversation_state("antigravity", SID, "ai/antigravity/todo-test"),
                                 {"state": "unknown", "tasks": 0})
            agy.read_statusline(SID, {"conversation_id": "another", "agent_state": "idle"})
            self.assertEqual(agy.main(["ready", SID, identity], lambda: self.binary), 2)

    def test_first_message_survives_retry_and_is_retired_on_explicit_input(self):
        with patch.dict(os.environ, {"HOME": self.temp.name}):
            agy.remember_prompt(SID, b"Try again\n")
            agy.remember_prompt(SID, b"Different text")
            self.assertEqual(agy.pending_prompt(SID).read_bytes(), b"Try again\n")
            transcript = (self.root / ".gemini/antigravity-cli/brain" / SID /
                          ".system_generated/logs/transcript.jsonl")
            transcript.parent.mkdir(parents=True)
            transcript.write_text(json.dumps({"type": "USER_INPUT", "source": "USER_EXPLICIT",
                                              "content": "<USER_REQUEST>\nTry again\n</USER_REQUEST>\n"
                                                         "<ADDITIONAL_METADATA>\ncontext\n</ADDITIONAL_METADATA>\n"
                                                         "<USER_SETTINGS_CHANGE>\nmode\n</USER_SETTINGS_CHANGE>"}) + "\n")
            self.assertIsNone(agy.pending_prompt(SID))
            agy.remember_prompt(SID, b"Try again")
            self.assertIsNone(agy.pending_prompt(SID))

    def test_uncertain_prompt_is_never_claimed_again(self):
        agy.remember_prompt(SID, b"Submit once\n")
        self.assertEqual(agy.claim_prompt(SID), "Submit once")
        # The CLI may have accepted it and then died before recording the prompt.
        self.assertIsNotNone(agy.pending_prompt(SID))
        agy.remember_prompt(SID, b"Submit once\n")
        self.assertIsNone(agy.claim_prompt(SID))

    def test_restart_requires_confirmation_even_after_a_fresh_idle_report(self):
        name = "ai/antigravity/todo-test"
        entry = {"tool": "antigravity", "session_id": SID, "version": "1.5.14"}
        with patch.object(restart, "session_exists", return_value=True), \
                patch.object(restart, "running_entry", return_value=entry), \
                patch.object(restart, "conversation_state", return_value={"state": "idle", "tasks": 0}), \
                patch.object(restart, "stop") as stop:
            code, result = restart.restart(name, SID, "antigravity")
            self.assertEqual((code, result["reason"]), (restart.REFUSED, "unknown"))
            stop.assert_not_called()
            code, result = restart.restart(name, SID, "antigravity", force=True)
            self.assertEqual((code, result["result"]), (0, "stopped"))
            stop.assert_called_once_with(name, entry)
        with patch.object(restart, "session_exists", return_value=True), \
                patch.object(restart, "running_entry", return_value=entry), \
                patch.object(restart, "conversation_state", return_value={"state": "mismatch", "tasks": 0}), \
                patch.object(restart, "stop") as stop:
            code, result = restart.restart(name, SID, "antigravity", force=True)
            self.assertEqual((code, result["reason"]), (restart.REFUSED, "mismatch"))
            stop.assert_not_called()

    def runner_definitions(self, names):
        # The runner is a shell wrapper around a Python program.
        source = Path(__file__).with_name("ai-todo-runner").read_text().split("<<'PY'\n", 1)[1].rsplit("\nPY", 1)[0]
        tree = ast.parse(source)
        definitions = ast.Module(body=[node for node in tree.body if getattr(node, "name", None) in names], type_ignores=[])
        runner = {"time": time, "os": os, "json": json, "re": re, "tempfile": tempfile,
                  "urllib": urllib, "STATE_DIR": self.temp.name, "log": Mock()}
        exec(compile(definitions, "ai-todo-runner", "exec"), runner)
        return runner

    def test_runner_retries_the_same_session_link_and_refuses_a_conflict(self):
        runner = self.runner_definitions({"HubError", "link_antigravity_session", "transient_hub_error"})
        hub = Mock()
        hub.request.side_effect = [runner["HubError"]("lost"), runner["HubError"]("unavailable", 503), None]
        with patch.object(time, "sleep"):
            runner["link_antigravity_session"](hub, "/conversation/session", SID)
        self.assertEqual(hub.request.call_count, 3)
        for call in hub.request.call_args_list:
            self.assertEqual(call.kwargs["body"], {"session_id": SID, "expected_session_id": ""})
        hub.reset_mock()
        hub.request.side_effect = runner["HubError"]("different UUID", 409)
        with self.assertRaises(runner["HubError"]):
            runner["link_antigravity_session"](hub, "/conversation/session", SID)
        self.assertEqual(hub.request.call_count, 1)

    def test_runner_outbox_replays_link_and_finish_after_the_hub_returns(self):
        runner = self.runner_definitions({
            "HubError", "queue_session_link", "retry_session_links", "queue_finish", "retry_finishes",
            "pending_updates", "ensure_state", "load_json", "save_json", "remove_pending",
            "touch_pending", "send_pending_finish", "transient_hub_error",
        })
        hub = Mock(url="http://original-hub")
        hub.request.side_effect = runner["HubError"]("offline")
        detail = "Antigravity launch needs reconciliation."
        runner["queue_session_link"](hub, "computer", "run", "/conversation/session", SID)
        runner["queue_finish"](hub, "computer", "run", "failed", detail)
        self.assertTrue((self.root / "finish-run.json").exists())
        self.assertTrue((self.root / "session-link-run.json").exists())
        unrelated = Mock(url="http://different-hub")
        runner["retry_session_links"](unrelated, "computer")
        runner["retry_finishes"](unrelated, "computer")
        unrelated.request.assert_not_called()
        hub.request.reset_mock(side_effect=True)
        runner["retry_session_links"](hub, "computer")
        runner["retry_finishes"](hub, "computer")
        calls = hub.request.call_args_list
        self.assertEqual([call.args[0] for call in calls], ["PUT", "POST"])
        self.assertEqual(calls[0].kwargs["body"]["session_id"], SID)
        self.assertEqual(calls[1].kwargs["body"], {"state": "failed", "result": detail})
        self.assertFalse((self.root / "finish-run.json").exists())
        self.assertFalse((self.root / "session-link-run.json").exists())

    def test_resize_is_restored_on_term_and_hangup(self):
        tty = self.root / "terminal"
        tty.touch()
        identity = "123:%4:567"
        original = struct.pack("HHHH", 24, 80, 0, 0)
        for signum in (signal.SIGTERM, signal.SIGHUP):
            with self.subTest(signal=signum):
                current = original
                sender = None

                def ioctl(_tty, operation, size):
                    nonlocal current, sender
                    if operation == termios.TIOCGWINSZ:
                        return current
                    current = size
                    if size != original:
                        sender = threading.Thread(target=os.kill, args=(os.getpid(), signum))
                        sender.start()
                    return size

                result = Mock(returncode=0, stdout=f"{identity} {tty} clearScrollbackOnResize")
                with patch.object(agy.subprocess, "run", return_value=result), \
                        patch.object(agy.fcntl, "ioctl", side_effect=ioctl):
                    started = time.monotonic()
                    self.assertFalse(agy.refresh_pane_locked(SID, "ai/antigravity/todo-test", identity, 3))
                    self.assertLess(time.monotonic() - started, 2)
                self.assertEqual(current, original)
                sender.join()

    def test_status_tracks_turns_without_account_data(self):
        path = self.root / ("antigravity." + SID + ".json")
        agy.read_statusline(SID, {"conversation_id": "wrong", "agent_state": "working"})
        self.assertFalse(path.exists())
        data = {"conversation_id": SID, "agent_state": "working", "email": "example@invalid"}
        agy.read_statusline(SID, data)
        busy = json.loads(path.read_text())["body"]
        self.assertEqual(busy["status"], "busy")
        self.assertNotIn("email", busy)
        agy.read_statusline(SID, dict(data, tool_confirmation_pending=True))
        self.assertEqual(json.loads(path.read_text())["body"]["status"], "waiting")
        agy.read_statusline(SID, dict(data, agent_state="idle"))
        idle = json.loads(path.read_text())["body"]
        self.assertEqual(idle["status"], "idle")
        self.assertEqual(idle["turn_started_ns"], busy["turn_started_ns"])


if __name__ == "__main__":
    unittest.main()
