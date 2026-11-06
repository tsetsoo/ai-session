#!/usr/bin/env python3
"""Offline restart regressions: a fake CLI (compiled, in a version folder) in a private tmux
server, a fake ai-todo-open, temporary status records. No real CLI, hub or conversation."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest
import uuid
from unittest.mock import patch

import ai_todo_launch as launch
import ai_todo_restart as restart
import ai_todo_status as status

FAKE_CLI = r"""
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
static void stop(int s) { (void)s; _exit(0); }
int main(int argc, char **argv) {
    if (argc > 1 && strcmp(argv[1], "--version") == 0) { puts(VERSION " (fake)"); return 0; }
    signal(SIGTERM, stop);
    for (;;) pause();
}
"""


@unittest.skipUnless(shutil.which("tmux") and shutil.which("cc"), "needs tmux and a C compiler")
class RestartTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = tempfile.TemporaryDirectory()
        source = Path(cls.build.name) / "cli.c"
        source.write_text(FAKE_CLI)
        cls.binaries = {}
        for version in ("2.1.300", "2.1.319"):
            out = Path(cls.build.name) / version
            subprocess.run(["cc", '-DVERSION="%s"' % version, "-o", str(out), str(source)], check=True)
            cls.binaries[version] = out

    @classmethod
    def tearDownClass(cls):
        cls.build.cleanup()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.home = Path(self.temp.name)
        self.socket = "restart-test-%d" % os.getpid()
        self.environment = patch.dict(os.environ, {
            "HOME": str(self.home), "AI_TODO_STATUS_DIR": str(self.home / "status"),
            "AI_TODO_LAUNCH_DIR": str(self.home / "launch"), "AI_TODO_TMUX_SOCKET": self.socket,
            "CLAUDE_CONFIG_DIR": str(self.home / ".claude"), "CODEX_HOME": str(self.home / ".codex")})
        self.environment.start()
        self.versions = self.home / ".local/share/claude/versions"
        self.versions.mkdir(parents=True)
        self.bin = self.home / ".local/bin"
        self.bin.mkdir(parents=True)
        self.install("2.1.300")
        os.environ["AI_TODO_CLAUDE_BIN"] = str(self.bin / "claude")
        self.sid = str(uuid.uuid4())
        self.name = "ai/claude/todo-restart1"

    def tearDown(self):
        subprocess.run(["tmux", "-L", self.socket, "kill-server"], capture_output=True)
        self.environment.stop()
        self.temp.cleanup()

    def install(self, version):
        """The native installer's layout: versions/<v> and ~/.local/bin/claude -> it."""
        target = self.versions / version
        if not target.exists():
            shutil.copy(self.binaries[version], target)
        link = self.bin / "claude"
        link.unlink(missing_ok=True)
        link.symlink_to(target)

    def start(self, name=None):
        name = name or self.name
        subprocess.run(["tmux", "-L", self.socket, "new-session", "-d", "-s", name, "--",
                        str(self.bin / "claude"), "--resume", self.sid], check=True)
        for _ in range(50):
            entry = restart.running_entry(name)
            if entry and entry.get("version"):
                return entry
            time.sleep(0.1)
        self.fail("the fake CLI didn't start")

    def publish(self, state, tasks=None):
        record = {"body": {"session_id": self.sid, "status": state, "tool": "claude"}, "pending": False}
        if tasks is not None:
            record["claude_turn"] = {"tasks": tasks}
        status.atomic_json(status.root() / ("claude.%s.json" % self.sid), record)

    def fake_open(self, exit_code=0):
        """An ai-todo-open that starts the session again with whatever ~/.local/bin/claude is."""
        log = self.home / "open.log"
        script = self.home / "fake-open"
        script.write_text("#!/bin/sh\necho \"$*\" >>%s\n[ %d = 0 ] || { echo broken. >&2; exit %d; }\n"
                          "while [ \"$1\" != %s ]; do shift; done\n"
                          "tmux -L %s new-session -d -s \"$1\" -- %s --resume \"$3\"\necho resumed\n"
                          % (log, exit_code, exit_code, self.name, self.socket, self.bin / "claude"))
        script.chmod(0o755)
        os.environ["AI_TODO_OPEN_BIN"] = str(script)
        return log

    # State

    def test_state_is_the_cautious_one(self):
        self.assertEqual(restart.conversation_state("claude", self.sid), {"state": "unknown", "tasks": 0})
        self.publish("idle")
        self.assertEqual(restart.conversation_state("claude", self.sid)["state"], "idle")
        status.atomic_json(status.root() / "claude-runtime.json",
                           {"observed_ns": time.time_ns(), "threads": {self.sid: ["waiting", "Claude needs your answer"]}})
        self.assertEqual(restart.conversation_state("claude", self.sid)["state"], "waiting")
        status.atomic_json(status.root() / "claude-runtime.json",
                           {"observed_ns": time.time_ns() - 60 * 10**9, "threads": {self.sid: ["busy", None]}})
        self.assertEqual(restart.conversation_state("claude", self.sid)["state"], "idle", "a stale snapshot doesn't count")
        self.publish("idle", tasks=[{"id": "t1", "type": "local_agent"}])
        self.assertEqual(restart.conversation_state("claude", self.sid)["tasks"], 1)

    # Refusals

    def test_refuses_working_waiting_unknown_and_background(self):
        before = self.start()
        for state, tasks, reason in (("busy", None, "busy"), ("waiting", None, "waiting"),
                                     (None, None, "unknown"), ("idle", [{"id": "b", "type": "shell"}], "background")):
            if state:
                self.publish(state, tasks)
            else:
                (status.root() / ("claude.%s.json" % self.sid)).unlink(missing_ok=True)
            code, result = restart.restart(self.name, self.sid, "claude")
            self.assertEqual((code, result["result"], result["reason"]), (75, "refused", reason), result)
            self.assertTrue(restart.alive(before["pid"]), "a refused restart leaves it running")
        # --force is the user's "restart anyway" for working or waiting; background tasks still refuse.
        self.publish("idle", [{"id": "b", "type": "shell"}])
        self.assertEqual(restart.restart(self.name, self.sid, "claude", force=True)[1]["reason"], "background")
        self.publish("busy")
        code, result = restart.restart(self.name, self.sid, "claude", force=True)
        self.assertEqual((code, result["result"]), (0, "stopped"))

    def test_bad_arguments(self):
        with self.assertRaises(ValueError):
            restart.restart("ai/codex/todo-x", self.sid, "claude")
        with self.assertRaises(ValueError):
            restart.restart(self.name, "bad id", "claude")
        self.assertEqual(restart.main([self.name, self.sid]), (64, None))
        self.assertEqual(restart.main([self.name, self.sid, "claude", "--mcp", "a"]), (64, None), "--mcp needs --reopen")
        self.assertEqual(restart.main([self.name, self.sid, "claude", "--chrome", "maybe"]), (64, None))

    # Restarts

    def test_idle_restart_stops_then_the_app_reattaches(self):
        before = self.start()
        self.publish("idle")
        code, result = restart.restart(self.name, self.sid, "claude", chrome="on")
        self.assertEqual((code, result["result"], result["before"], result["stopped"]), (0, "stopped", "2.1.300", True))
        self.assertFalse(restart.alive(before["pid"]))
        self.assertFalse(restart.session_exists(self.name))
        self.assertEqual(launch.resume_args("claude", self.sid), ["--chrome"], "the next start gets Chrome")

    def test_reopen_runs_the_installed_version(self):
        self.start()
        self.publish("idle")
        self.install("2.1.319")  # an update landed; the running one is still 2.1.300
        log = self.fake_open()
        code, result = restart.main([self.name, self.sid, "claude", "--reopen", "~/work", "--mcp", "github,sentry"])
        self.assertEqual(code, 0, result)
        self.assertEqual((result["result"], result["before"], result["after"], result["installed"]),
                         ("restarted", "2.1.300", "2.1.319", "2.1.319"))
        self.assertEqual(log.read_text().split(), ["--detached", "--mcp", "github,sentry", self.name, "~/work", self.sid, "claude"])
        self.assertEqual(result["mode"], "resumed")

    def test_not_running_just_starts_it(self):
        self.fake_open()
        code, result = restart.restart(self.name, self.sid, "claude", cwd="~/work")
        self.assertEqual((code, result["result"], result["stopped"], result["before"]), (0, "restarted", False, None))

    def test_a_failed_start_says_it_is_saved(self):
        self.start()
        self.publish("idle")
        self.fake_open(exit_code=1)
        code, result = restart.restart(self.name, self.sid, "claude", cwd="~/work")
        self.assertEqual((code, result["result"], result["stage"]), (1, "failed", "reopen"))
        self.assertIn("It's saved", result["message"])
        self.assertIn("broken", result["message"])
        self.assertNotIn("..", result["message"])
        # 94 (nothing to resume): the helper's own reason, not "it's saved".
        self.fake_open(exit_code=94)
        code, result = restart.restart(self.name, self.sid, "claude", cwd="~/work")
        self.assertNotIn("It's saved", result["message"])

    def test_codex_waits_for_its_writer_lock(self):
        name = "ai/codex/todo-restart2"
        with patch.object(status, "writer_conflict", return_value="Codex conversation x is open in another Codex"), \
                patch.object(restart, "LOCK_WAIT_S", 0.3):
            code, result = restart.restart(name, self.sid, "codex")
        self.assertEqual((code, result["result"], result["stage"]), (1, "failed", "writer"))
        with patch.object(status, "writer_conflict", return_value=None):
            self.assertEqual(restart.restart(name, self.sid, "codex")[1]["result"], "stopped")


if __name__ == "__main__":
    unittest.main()
