#!/usr/bin/env python3
"""Offline launch-settings regressions: fake transcripts and rollouts in a temporary home."""
import contextlib
import io
import json
import os
from pathlib import Path
import tempfile
import time
import unittest
from unittest.mock import patch

import ai_todo_launch as launch

SID = "0f3a9c21-1d4a-4e7b-8c55-2f0e8a1b7d90"


class LaunchTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.home = Path(self.temp.name)
        self.environment = patch.dict(os.environ, {
            "HOME": str(self.home), "AI_TODO_LAUNCH_DIR": str(self.home / "launch"),
            "CLAUDE_CONFIG_DIR": str(self.home / ".claude"), "CODEX_HOME": str(self.home / ".codex")})
        self.environment.start()

    def tearDown(self):
        self.environment.stop()
        self.temp.cleanup()

    def claude(self, *entries, project="-p", sid=SID):
        path = self.home / ".claude" / "projects" / project / (sid + ".jsonl")
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("".join(json.dumps(e) + "\n" for e in entries) + "not json\n")
        return path

    def codex(self, *turns, sid=SID):
        path = self.home / ".codex" / "sessions" / "2026" / "11" / "06" / ("rollout-2026-11-06T10-00-00-%s.jsonl" % sid)
        path.parent.mkdir(parents=True, exist_ok=True)
        lines = [{"type": "session_meta", "payload": {"id": sid}}]
        for model, effort, sandbox in turns:
            lines.append({"type": "turn_context", "payload": {"model": model, "effort": effort, "sandbox_policy": sandbox}})
        path.write_text("".join(json.dumps(l) + "\n" for l in lines))

    @staticmethod
    def assistant(model, sidechain=False):
        return {"type": "assistant", "isSidechain": sidechain, "message": {"model": model, "role": "assistant"}}

    @staticmethod
    def user(mode):
        return {"type": "user", "permissionMode": mode, "message": {"role": "user", "content": "x"}}

    # Claude

    def test_claude_without_a_transcript_uses_what_it_started_with(self):
        self.assertEqual(launch.resume_args("claude", SID), [])
        launch.save("claude", SID, model="claude-haiku-5-5", auto_approve=True)
        self.assertEqual(launch.resume_args("claude", SID),
                         ["--permission-mode", "auto", "--model", "claude-haiku-5-5"])

    def test_claude_latest_mode_and_model_win(self):
        launch.save("claude", SID, model="claude-haiku-5-5", auto_approve=True)
        self.claude(self.user("auto"), self.assistant("claude-haiku-5-5"), self.user("acceptEdits"),
                    self.assistant("claude-sonnet-5-5", sidechain=True), self.assistant("<synthetic>"),
                    self.assistant("claude-opus-5-5"))
        self.assertEqual(launch.resume_args("claude", SID),
                         ["--permission-mode", "acceptEdits", "--model", "claude-opus-5-5"])

    def test_claude_default_model_and_manual_mode_need_no_flags(self):
        self.claude(self.user("manual"), self.assistant("claude-opus-5-5"), self.assistant("claude-opus-5-5"))
        self.assertEqual(launch.resume_args("claude", SID), [])

    def test_claude_a_model_switch_is_kept_without_a_saved_model(self):
        self.claude(self.user("default"), self.assistant("claude-opus-5-5"), self.assistant("claude-opus-5-5[1m]"))
        self.assertEqual(launch.resume_args("claude", SID), ["--model", "claude-opus-5-5[1m]"])

    def test_claude_bypass_is_never_put_back(self):
        launch.save("claude", SID, auto_approve=True)
        self.claude(self.user("bypassPermissions"), self.assistant("claude-opus-5-5"))
        self.assertEqual(launch.resume_args("claude", SID), [], "a recorded mode, just not one to restore")

    def test_claude_reads_the_newest_copy(self):
        old = self.claude(self.user("plan"), self.assistant("a"), project="-old")
        os.utime(old, (time.time() - 100, time.time() - 100))
        self.claude(self.user("auto"), self.assistant("a"), project="-new")
        self.assertEqual(launch.resume_args("claude", SID), ["--permission-mode", "auto"])

    # Codex

    def test_codex_network_and_model_switch(self):
        write = {"type": "workspace-write", "network_access": True}
        self.codex(("gpt-6.1-sol", "medium", write), ("codex-auto-review", "low", {"type": "read-only"}),
                   ("gpt-6.1-sol", "high", write))
        self.assertEqual(launch.resume_args("codex", SID),
                         ["-c", "sandbox_workspace_write.network_access=true",
                          "-m", "gpt-6.1-sol", "-c", 'model_reasoning_effort="high"'])

    def test_codex_unchanged_default_gets_nothing_and_no_network_stays_off(self):
        launch.save("codex", SID, auto_approve=True)
        no_net = {"type": "workspace-write", "network_access": False}
        self.codex(("gpt-6.1-sol", "medium", no_net), ("gpt-6.1-sol", "medium", no_net))
        self.assertEqual(launch.resume_args("codex", SID), [], "the transcript says no network: that wins")

    def test_codex_saved_settings_without_a_rollout(self):
        launch.save("codex", SID, model="gpt-6.1-mini", auto_approve=True)
        self.assertEqual(launch.resume_args("codex", SID),
                         ["-c", "sandbox_workspace_write.network_access=true", "-m", "gpt-6.1-mini"])

    def test_cursor_gets_nothing(self):
        launch.save("cursor", SID, model="x", auto_approve=True)
        self.assertEqual(launch.resume_args("cursor", SID), [])

    def test_chrome_is_kept_and_shown(self):
        launch.update("claude", SID, chrome=True)
        self.assertEqual(launch.resume_args("claude", SID), ["--chrome"])
        launch.save("claude", SID, auto_approve=True)  # a later save keeps the choice
        self.assertEqual(launch.resume_args("claude", SID), ["--permission-mode", "auto", "--chrome"])
        launch.update("claude", SID, chrome=False)
        self.assertEqual(launch.settings("claude", SID),
                         {"chrome": False, "model": None, "permission_mode": "auto", "network": False,
                          "search": None, "args": ["--permission-mode", "auto", "--no-chrome"]})
        launch.update("claude", SID, chrome=None)
        self.assertEqual(launch.resume_args("claude", SID), ["--permission-mode", "auto"])
        with self.assertRaises(ValueError):
            launch.update("claude", SID, chrome="yes")
        self.assertEqual(launch.create_args("claude", SID), [])
        launch.update("claude", SID, chrome=True)
        self.assertEqual(launch.create_args("claude", SID), ["--chrome"], "a start with no transcript keeps it too")
        self.assertEqual(launch.create_args("codex", SID), [])

    def test_codex_web_search_is_kept_and_shown(self):
        launch.update("codex", SID, search=True)
        self.assertEqual(launch.resume_args("codex", SID), ["--search"])
        self.assertTrue(launch.settings("codex", SID)["search"])
        launch.save("codex", SID, model="gpt-6.1-mini")  # a later save keeps the choice
        self.assertIn("--search", launch.resume_args("codex", SID))
        launch.update("codex", SID, search=False)
        self.assertNotIn("--search", launch.resume_args("codex", SID))
        self.assertFalse(launch.settings("codex", SID)["search"])
        with self.assertRaises(ValueError):
            launch.update("codex", SID, search="yes")
        launch.update("claude", SID, search=True)
        self.assertNotIn("--search", launch.resume_args("claude", SID), "Claude has no --search")

    # Records and CLI

    def test_save_checks_its_input_and_prunes_old_records(self):
        with self.assertRaises(ValueError):
            launch.save("claude", "../../etc", model="x")
        with self.assertRaises(ValueError):
            launch.save("claude", SID, model="bad model; rm")
        with self.assertRaises(ValueError):
            launch.save("gemini", SID)
        launch.save("claude", "old-one")
        old = launch.record_path("claude", "old-one")
        os.utime(old, (0, 0))
        launch.save("claude", SID)
        self.assertFalse(old.exists())
        self.assertEqual(oct(launch.record_path("claude", SID).stat().st_mode & 0o777), "0o600")

    def test_cli(self):
        self.assertEqual(launch.main(["save", "codex", SID, "--model", "gpt-6.1-mini", "--auto-approve"]), 0)
        self.assertEqual(launch.load("codex", SID)["model"], "gpt-6.1-mini")
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertEqual(launch.main(["resume-args", "codex", SID]), 0)
        self.assertEqual(out.getvalue().splitlines(),
                         [launch.HEADER, "-c", "sandbox_workspace_write.network_access=true", "-m", "gpt-6.1-mini"])
        self.assertEqual(launch.main(["save", "codex", SID, "--bogus"]), 64)
        self.assertEqual(launch.main(["nothing"]), 64)
        with self.assertRaises(ValueError):
            launch.main(["resume-args", "codex", "bad id"])


if __name__ == "__main__":
    unittest.main()
