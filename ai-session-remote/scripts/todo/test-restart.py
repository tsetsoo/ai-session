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

    def test_a_session_without_a_cli_it_recognises_is_unknown(self):
        """No CLI found in the pane (starting, wrapped): its state can't be read, so refused unless forced."""
        subprocess.run(["tmux", "-L", self.socket, "new-session", "-d", "-s", self.name, "--", "sleep", "60"], check=True)
        self.publish("idle")
        code, result = restart.restart(self.name, self.sid, "claude")
        self.assertEqual((code, result["result"], result["reason"]), (75, "refused", "unknown"), result)
        self.assertTrue(restart.session_exists(self.name))
        code, result = restart.restart(self.name, self.sid, "claude", force=True)
        self.assertEqual((code, result["result"]), (0, "stopped"))
        self.assertFalse(restart.session_exists(self.name))

    # Closing sessions whose todo is archived or deleted

    def hub(self, linked=("ai/claude/todo-elsewhere",), open_todos=()):
        return {"linked": set(linked), "open": set(open_todos)}

    def transcript(self, at):
        """The conversation's Claude transcript, last written at `at`."""
        path = self.home / ".claude/projects/-work" / (self.sid + ".jsonl")
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("{}\n")
        os.utime(path, (at, at))

    def test_close_unused_closes_only_old_idle_unlinked_sessions(self):
        self.start()  # self.name: not linked, idle
        self.publish("idle")
        self.transcript(time.time())
        linked = "ai/claude/todo-linked01"
        self.start(linked)
        attached = "ai/claude/todo-attach01"
        self.start(attached)
        later = time.time() + restart.UNUSED_IDLE_S + 60
        sessions = restart.session_info()
        self.assertTrue(sessions[self.name]["activity"] > time.time() - 60, "a new session's activity is now")
        sessions[attached]["attached"] = True
        with patch.object(restart, "session_info", return_value=sessions):
            # Recently active: kept.
            result = restart.close_unused(self.hub([linked]), now=time.time())
            self.assertEqual(result["closed"], [])
            # Old enough: the unlinked idle one goes; linked and attached stay.
            result = restart.close_unused(self.hub([linked]), now=later, dry_run=True)
            self.assertEqual(result["closed"], [self.name], result)
            self.assertTrue(restart.session_exists(self.name), "a dry run stops nothing")
            result = restart.close_unused(self.hub([linked]), now=later)
        self.assertEqual(result["closed"], [self.name], result)
        self.assertFalse(restart.session_exists(self.name))
        self.assertTrue(restart.session_exists(linked))
        self.assertTrue(restart.session_exists(attached))

    def test_close_unused_keeps_one_where_a_turn_ran_lately(self):
        """Turns sent from the app don't move tmux's activity; the transcript shows them."""
        self.start()
        self.publish("idle")
        later = time.time() + restart.UNUSED_IDLE_S + 60
        self.transcript(later - 60)
        result = restart.close_unused(self.hub(), now=later)
        self.assertEqual((result["closed"], result["left"]), ([], []))
        self.assertTrue(restart.session_exists(self.name))

    def test_close_unused_never_forces(self):
        self.start()
        self.publish("busy")
        self.transcript(time.time())
        later = time.time() + restart.UNUSED_IDLE_S + 60
        result = restart.close_unused(self.hub(), now=later)
        self.assertEqual(result["closed"], [])
        self.assertEqual([(x["tmux"], x["reason"]) for x in result["left"]], [(self.name, "busy")])
        self.assertTrue(restart.session_exists(self.name))

    def test_close_unused_leaves_what_it_cannot_check(self):
        """A CLI started fresh has no id on its command line: its state can't be read."""
        name = "ai/claude/todo-fresh001"
        subprocess.run(["tmux", "-L", self.socket, "new-session", "-d", "-s", name, "--", str(self.bin / "claude")],
                       check=True)
        for _ in range(50):
            if restart.running_entry(name):
                break
            time.sleep(0.1)
        later = time.time() + restart.UNUSED_IDLE_S + 60
        result = restart.close_unused(self.hub(), now=later)
        self.assertEqual((result["closed"], result["left"]), ([], [{"tmux": name, "reason": "unknown"}]))
        self.assertTrue(restart.session_exists(name))

    def test_close_unused_keeps_an_open_todos_session(self):
        """A todo still listed whose conversation was replaced: its old session stays."""
        self.start()
        self.publish("idle")
        self.transcript(time.time())
        slug = self.name.split("todo-", 1)[1][:8]
        later = time.time() + restart.UNUSED_IDLE_S + 60
        result = restart.close_unused(self.hub(open_todos=[slug + "-0000-4000-8000-000000000000"]), now=later)
        self.assertEqual(result["left"], [{"tmux": self.name, "reason": "open todo"}])
        self.assertTrue(restart.session_exists(self.name))

    def test_close_unused_does_nothing_without_the_hub(self):
        self.start()
        self.publish("idle")
        with patch.object(restart, "hub_view", return_value=None):
            code, result = restart.close_unused_main([])
        self.assertEqual(code, 1)
        self.assertTrue(restart.session_exists(self.name))

    def test_hub_view_needs_this_computers_conversations(self):
        conversations = [{"tmux_name": "ai/claude/todo-a", "computer": {"id": "me"}},
                         {"tmux_name": "ai/claude/todo-b", "computer": {"id": "other"}},
                         {"tmux_name": None, "computer": {"id": "me"}}]
        todos = [{"id": "t1"}, {"id": "t2"}]

        def answers(conversations, todos):
            return lambda path, **_: {"/api/conversations": conversations, "/api/todos": todos}[path]
        me = {"TODO_COMPUTER_ID": "me"}
        with patch.object(restart, "hub_get", side_effect=answers(conversations, todos)), \
                patch.object(status, "hub_values", return_value=me):
            self.assertEqual(restart.hub_view(), {"linked": {"ai/claude/todo-a"}, "open": {"t1", "t2"}})
        with patch.object(restart, "hub_get", side_effect=answers(None, todos)), \
                patch.object(status, "hub_values", return_value=me):
            self.assertIsNone(restart.hub_view())
        with patch.object(restart, "hub_get", side_effect=answers(conversations, None)), \
                patch.object(status, "hub_values", return_value=me):
            self.assertIsNone(restart.hub_view(), "no todo list: an open todo couldn't be told apart")
        with patch.object(restart, "hub_get", side_effect=answers(conversations[1:], todos)), \
                patch.object(status, "hub_values", return_value=me):
            self.assertIsNone(restart.hub_view(), "none of ours listed: a reset hub or a wrong id")
        with patch.object(restart, "hub_get", side_effect=answers(conversations, todos)), \
                patch.object(status, "hub_values", return_value={}):
            self.assertIsNone(restart.hub_view(), "no computer id: can't tell which are ours")

    def test_bad_arguments(self):
        with self.assertRaises(ValueError):
            restart.restart("ai/codex/todo-x", self.sid, "claude")
        with self.assertRaises(ValueError):
            restart.restart(self.name, "bad id", "claude")
        self.assertEqual(restart.main([self.name, self.sid]), (64, None))
        self.assertEqual(restart.main([self.name, self.sid, "claude", "--mcp", "a"]), (64, None), "--mcp needs --reopen")
        self.assertEqual(restart.main([self.name, self.sid, "claude", "--chrome", "maybe"]), (64, None))
        self.assertEqual(restart.main([self.name, self.sid, "codex", "--search", "maybe"]), (64, None))
        self.assertEqual(restart.main([self.name, self.sid, "claude", "--worktree", "~/r", "b"]), (64, None),
                         "--worktree needs --reopen")
        self.assertEqual(restart.main([self.name, self.sid, "claude", "--reopen", "/w", "--worktree", "~/r"]), (64, None))

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

    def test_search_is_saved_for_codex_only(self):
        restart.launch.update("claude", self.sid, chrome=None)
        with patch.object(restart, "session_exists", return_value=False), \
                patch.object(status, "writer_conflict", return_value=None):
            code, result = restart.main(["ai/codex/todo-search1", self.sid, "codex", "--search", "on"])
        self.assertEqual((code, result["result"]), (0, "stopped"), result)
        self.assertIs(launch.load("codex", self.sid).get("search"), True)
        restart.main([self.name, self.sid, "claude", "--search", "on"])
        self.assertIsNone(launch.load("claude", self.sid).get("search"), "Claude has no web search choice")

    def test_reopen_remakes_its_worktree(self):
        """--worktree goes to ai-todo-open, which makes the worktree again if it was deleted."""
        self.start()
        self.publish("idle")
        log = self.fake_open()
        code, result = restart.main([self.name, self.sid, "claude", "--reopen", "~/wt/a", "--worktree", "~/repo", "ai/branch",
                                     "--mcp", ""])
        self.assertEqual(code, 0, result)
        self.assertEqual(log.read_text().splitlines()[-1],
                         "--detached --mcp  --worktree ~/repo ai/branch %s ~/wt/a %s claude" % (self.name, self.sid))

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


class TakeoverTests(unittest.TestCase):
    sid = "01a1a6bf-e5af-7360-a4fe-271996e66d90"
    name = "ai/codex/todo-takeover"
    identity = "Wed Nov 11 12:00:00 2026 /tmp/codex app-server --listen unix:///tmp/other.sock"
    lock_screen = ("This conversation is open in another app\n"
                   "Close it there and press R to continue here.\n"
                   "r retry   f fork   ←/esc command center   ⌃c/q exit   ⌃t transcript\n")

    def test_backend_detection_ignores_unbalanced_quotes_in_ps_config_values(self):
        self.assertTrue(restart.codex_backend(self.identity + ' -c name="unfinished'))
        self.assertFalse(restart.codex_backend(self.identity.replace('codex app-server', 'codex exec')))

    def test_free_conversation_does_not_stop_any_process(self):
        with patch.object(restart, "writer_locked", return_value=False), \
                patch.object(restart, "session_exists", return_value=False), \
                patch.object(status, "file_holders") as holders, patch.object(os, "kill") as kill:
            code, result = restart.takeover(self.name, self.sid)
        self.assertEqual((code, result["result"]), (0, "taken_over"))
        holders.assert_not_called()
        kill.assert_not_called()

    def test_unknown_owner_is_not_killed(self):
        with patch.object(restart, "writer_locked", return_value=True), \
                patch.object(status, "file_holders", return_value=[123]), \
                patch.object(restart, "process_identity", return_value="Wed Nov 11 12:00:00 2026 /tmp/editor"), \
                patch.object(os, "kill") as kill:
            code, result = restart.takeover(self.name, self.sid)
        self.assertEqual((code, result["result"]), (1, "failed"))
        kill.assert_not_called()

    def test_recycled_pid_is_not_killed(self):
        with patch.object(restart, "writer_locked", return_value=True), \
                patch.object(status, "file_holders", return_value=[123]), \
                patch.object(restart, "process_identity", side_effect=[self.identity, self.identity.replace("12:00", "13:00")]), \
                patch.object(os, "kill") as kill:
            code, result = restart.takeover(self.name, self.sid)
        self.assertEqual(code, 1)
        kill.assert_not_called()

    def test_confirmed_owner_stops_and_retry_is_only_sent_to_lock_screen(self):
        for screen, expected_sends in [(self.lock_screen, 1), ("Ask Codex to do anything", 0),
                                       (self.lock_screen + "Ask Codex to do anything\n", 0)]:
            calls = []
            def run(argv, **kwargs):
                calls.append(argv)
                output = screen if "capture-pane" in argv and not any("send-keys" in call for call in calls) else "Ask Codex to do anything"
                return subprocess.CompletedProcess(argv, 0, output, "")
            with patch.object(restart, "writer_locked", side_effect=[True, True, False]), \
                    patch.object(status, "file_holders", return_value=[123]), \
                    patch.object(restart, "process_identity", return_value=self.identity), \
                    patch.object(restart, "alive", return_value=False), \
                    patch.object(restart, "session_exists", return_value=True), \
                    patch.object(restart, "tmux_args", return_value=["tmux"]), \
                    patch.object(subprocess, "run", side_effect=run), patch.object(os, "kill") as kill:
                code, result = restart.takeover(self.name, self.sid)
            self.assertEqual(code, 0)
            kill.assert_called_once_with(123, restart.signal.SIGTERM)
            self.assertEqual(sum("send-keys" in argv for argv in calls), expected_sends)

    def test_terminal_read_failure_after_retry_is_not_success(self):
        outputs = [subprocess.CompletedProcess([], 0, self.lock_screen, ""),
                   subprocess.CompletedProcess([], 0, "", ""),
                   subprocess.CompletedProcess([], 1, "", "no session")]
        with patch.object(restart, "writer_locked", return_value=False), \
                patch.object(restart, "session_exists", return_value=True), \
                patch.object(restart, "tmux_args", return_value=["tmux"]), \
                patch.object(subprocess, "run", side_effect=outputs):
            code, result = restart.takeover(self.name, self.sid)
        self.assertEqual((code, result["result"]), (1, "failed"))

    def test_replaced_lock_inode_does_not_stop_old_owner(self):
        with patch.object(restart, "lock_identity", side_effect=[(1, 10), (1, 11)]), \
                patch.object(restart, "writer_locked", return_value=True), \
                patch.object(status, "file_holders", return_value=[123]), \
                patch.object(restart, "process_identity", return_value=self.identity), \
                patch.object(os, "kill") as kill:
            code, result = restart.takeover(self.name, self.sid)
        self.assertEqual(code, 1)
        kill.assert_not_called()

    def test_current_terminals_backend_is_not_stopped(self):
        own = status.terminal_socket(self.name)
        identity = self.identity.rsplit(" unix://", 1)[0] + " unix://" + str(own)
        with patch.object(restart, "writer_locked", return_value=True), \
                patch.object(status, "file_holders", return_value=[123]), \
                patch.object(restart, "process_identity", return_value=identity), \
                patch.object(restart, "running_entry", return_value={"pid": 456}), \
                patch.object(subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "456\n", "")), \
                patch.object(restart, "session_exists", return_value=False), patch.object(os, "kill") as kill:
            code, result = restart.takeover(self.name, self.sid)
        self.assertEqual((code, result["result"]), (0, "taken_over"))
        kill.assert_not_called()

    def test_real_lock_probe_keeps_inode(self):
        import fcntl
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "thread.lock"
            with path.open("w") as holder:
                fcntl.flock(holder, fcntl.LOCK_EX)
                inode = path.stat().st_ino
                self.assertTrue(restart.writer_locked(path))
                self.assertEqual(path.stat().st_ino, inode)
            self.assertFalse(restart.writer_locked(path))

    @unittest.skipUnless(shutil.which("cc") and shutil.which("lsof"), "needs compiler and lsof")
    def test_takeover_releases_a_real_backend_lock_without_deleting_history(self):
        with tempfile.TemporaryDirectory() as folder:
            home = Path(folder)
            locks = home / "thread-writer-locks"
            locks.mkdir()
            lock = locks / (self.sid + ".lock")
            source, binary = home / "fake.c", home / "codex"
            source.write_text('#include <sys/file.h>\n#include <fcntl.h>\n#include <unistd.h>\n'
                              'int main(int argc,char **argv) { int fd=open(argv[2],O_CREAT|O_RDWR,0600);'
                              'if(fd<0 || flock(fd,LOCK_EX)) return 1; for(;;) pause(); }\n')
            subprocess.run(["cc", str(source), "-o", str(binary)], check=True, capture_output=True)
            history = home / "saved-history.jsonl"
            history.write_text("saved conversation\n")
            process = subprocess.Popen([str(binary), "app-server", str(lock)])
            try:
                deadline = time.monotonic() + 5
                while not restart.writer_locked(lock) and time.monotonic() < deadline:
                    time.sleep(0.02)
                self.assertTrue(restart.writer_locked(lock))
                inode = lock.stat().st_ino
                with patch.object(status, "codex_home", return_value=home), \
                        patch.object(restart, "session_exists", return_value=False):
                    code, result = restart.takeover(self.name, self.sid)
                self.assertEqual((code, result["result"]), (0, "taken_over"))
                self.assertEqual(result["stopped_pids"], [process.pid])
                self.assertFalse(restart.writer_locked(lock))
                self.assertEqual(lock.stat().st_ino, inode)
                self.assertEqual(history.read_text(), "saved conversation\n")
            finally:
                if process.poll() is None:
                    process.terminate()
                process.wait(timeout=5)


if __name__ == "__main__":
    unittest.main()
