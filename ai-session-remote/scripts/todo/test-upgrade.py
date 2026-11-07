#!/usr/bin/env python3
"""Offline upgrade regressions: fake Claude, Codex and Cursor CLIs (shell scripts in the
version folders their installers use) in a temporary HOME. The fake updaters move the link to
the next version, do nothing, fail or hang, as each test asks. No real CLI is run."""
import fcntl
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import ai_todo_doctor as doctor
import ai_todo_upgrade as upgrade

# $FAKE_MODE: update (point $FAKE_LINK at $FAKE_NEXT), current, fail, slow, ask (reads stdin).
FAKE = r"""#!/bin/sh
case "$*" in
  --version) echo "@VERSION@ (fake)"; exit 0 ;;
  "app-server daemon version") echo '{"status":"running","appServerVersion":"'"$(cat "$FAKE_DAEMON" 2>/dev/null || echo @VERSION@)"'"}'; exit 0 ;;
esac
echo "$*" >> "$FAKE_LOG"
echo "PATH=$PATH" >> "$FAKE_LOG"
case "$FAKE_MODE" in
  update) printf '\033[32mChecking\033[0m\r#####   45.0%%\r########   100.0%%\rInstalling\nUpdated to the latest version\n'; ln -sfn "$FAKE_NEXT" "$FAKE_LINK"; [ -n "$FAKE_DAEMON" ] && echo @NEXT@ > "$FAKE_DAEMON"; exit 0 ;;
  current) echo "Already up to date"; exit 0 ;;
  fail) echo "network unreachable" >&2; exit 3 ;;
  slow) sleep 30 ;;
  ask) read answer; echo "got [$answer]"; exit 0 ;;
esac
"""


def fake(path, version, next_version=""):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(FAKE.replace("@NEXT@", next_version).replace("@VERSION@", version))
    path.chmod(0o755)
    return path


class UpgradeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.home = Path(self.temp.name)
        self.log = self.home / "updater.log"
        self.environment = patch.dict(os.environ, {
            "HOME": str(self.home), "AI_TODO_STATUS_DIR": str(self.home / "status"),
            "CODEX_HOME": str(self.home / ".codex"), "FAKE_LOG": str(self.log), "FAKE_MODE": "update"})
        self.environment.start()

    def tearDown(self):
        self.environment.stop()
        self.temp.cleanup()

    def claude_native(self):
        versions = self.home / ".local/share/claude/versions"
        fake(versions / "2.1.300", "2.1.300")
        fake(versions / "2.1.319", "2.1.319")
        link = self.home / ".local/bin/claude"
        link.parent.mkdir(parents=True)
        link.symlink_to(versions / "2.1.300")
        os.environ.update(AI_TODO_CLAUDE_BIN=str(link), FAKE_LINK=str(link), FAKE_NEXT=str(versions / "2.1.319"))
        return link

    def updater_calls(self):
        return [line for line in self.log.read_text().splitlines() if not line.startswith("PATH=")] \
            if self.log.exists() else []

    def test_claude_native_updates_and_reports_both_versions(self):
        link = self.claude_native()
        code, result = upgrade.upgrade("claude")
        self.assertEqual(code, 0)
        self.assertEqual((result["result"], result["method"], result["before"], result["after"]),
                         ("updated", "native", "2.1.300", "2.1.319"))
        self.assertEqual(result["command"], "~/.local/bin/claude update")
        self.assertEqual(self.updater_calls(), ["update"])
        self.assertEqual(result["message"], "Checking Installing Updated to the latest version")
        # Its own folder is on PATH (the native installer warns, and may stop, without it).
        self.assertIn("PATH=" + str(link.parent) + os.pathsep, self.log.read_text())

    def test_already_current(self):
        self.claude_native()
        os.environ["FAKE_MODE"] = "current"
        code, result = upgrade.upgrade("claude")
        self.assertEqual((code, result["result"], result["before"], result["after"]), (0, "current", "2.1.300", "2.1.300"))
        self.assertEqual(result["message"], "Already up to date")

    def test_failed_updater_says_why(self):
        self.claude_native()
        os.environ["FAKE_MODE"] = "fail"
        code, result = upgrade.upgrade("claude")
        self.assertEqual((code, result["result"], result["after"]), (1, "failed", "2.1.300"))
        self.assertEqual(result["message"], "The updater exited with 3. network unreachable")

    def test_failed_updater_that_switched_versions_is_still_failed(self):
        self.claude_native()
        os.environ["FAKE_MODE"] = "update"
        real = upgrade.run_updater
        with patch.object(upgrade, "run_updater", lambda *a: (real(*a)[0] + 2, "broke halfway")):
            code, result = upgrade.upgrade("claude")
        self.assertEqual((code, result["result"], result["after"]), (1, "failed", "2.1.319"))
        self.assertEqual(result["message"], "The updater exited with 2. It now starts 2.1.319; check that it works. broke halfway")

    def test_odd_bytes_in_output(self):
        script = self.home / "bytes"
        script.write_text("#!/bin/sh\nprintf 'Done \\342\\226'\n")
        script.chmod(0o755)
        code, output = upgrade.run_updater([str(script)], dict(os.environ), 5)
        self.assertEqual(code, 0)
        self.assertTrue(output.startswith("Done "), output)

    def test_shown_command_keeps_tilde_working_with_spaces(self):
        plan = doctor.update_plan("claude", str(self.home / "My Tools/claude"), "/x", "other")
        self.assertEqual(plan["command"], "~/'My Tools/claude' update")

    def test_hung_updater_is_ended(self):
        self.claude_native()
        os.environ["FAKE_MODE"] = "slow"
        code, result = upgrade.upgrade("claude", timeout=1)
        self.assertEqual((code, result["result"]), (1, "failed"))
        self.assertIn("didn't finish in 1 s", result["message"])

    def test_a_question_gets_end_of_input(self):
        self.claude_native()
        os.environ["FAKE_MODE"] = "ask"
        code, result = upgrade.upgrade("claude", timeout=5)
        self.assertEqual((code, result["result"], result["message"]), (0, "current", "got []"))

    def test_one_update_at_a_time(self):
        self.claude_native()
        lock_path = self.home / "status" / "upgrade-claude.lock"
        lock_path.parent.mkdir(parents=True)
        with open(lock_path, "a") as held:
            fcntl.flock(held, fcntl.LOCK_EX)
            code, result = upgrade.upgrade("claude")
        self.assertEqual((code, result["result"]), (1, "failed"))
        self.assertEqual(self.updater_calls(), [])

    def test_npm_install_is_not_run(self):
        package = self.home / "lib/node_modules/@anthropic-ai/claude-code"
        fake(package / "cli.js", "2.1.300")
        (package / "package.json").write_text(json.dumps({"version": "2.1.300"}))
        os.environ["AI_TODO_CLAUDE_BIN"] = str(package / "cli.js")
        code, result = upgrade.upgrade("claude")
        self.assertEqual((code, result["result"], result["method"], result["before"]), (0, "unsupported", "npm", "2.1.300"))
        self.assertEqual(result["command"], "npm install -g @anthropic-ai/claude-code@latest")
        self.assertIn(result["command"], result["message"])
        self.assertEqual(self.updater_calls(), [])

    def test_unreadable_version_before_is_not_called_current(self):
        self.claude_native()
        real = doctor.binary_version
        calls = []
        def version(binary, resolved):
            calls.append(resolved)
            return None if len(calls) <= 2 else real(binary, resolved)  # found, then under the lock
        with patch.object(doctor, "binary_version", version):
            code, result = upgrade.upgrade("claude")
        self.assertEqual((code, result["result"], result["before"], result["after"]), (0, "updated", None, "2.1.319"))

    def test_updater_that_leaves_a_child_holding_its_output(self):
        # Codex's updater can start the shared server, which keeps running after it exits.
        script = self.home / "spawner"
        script.write_text("#!/bin/sh\n(sleep 20 &)\necho started\n")
        script.chmod(0o755)
        started = __import__("time").monotonic()
        code, output = upgrade.run_updater([str(script)], dict(os.environ), 10)
        self.assertLess(__import__("time").monotonic() - started, 5)
        self.assertEqual((code, output.strip()), (0, "started"))

    def test_npm_under_homebrew_node(self):
        plan = doctor.update_plan("codex", "/opt/homebrew/bin/codex",
                                  "/opt/homebrew/lib/node_modules/@openai/codex/bin/codex.js", "homebrew")
        self.assertEqual((plan["runs"], plan["command"]), (False, "npm install -g @openai/codex@latest"))

    def test_homebrew_command_names_the_cask_or_formula(self):
        for kind, expected in (("Caskroom", "brew upgrade --cask codex"), ("Cellar", "brew upgrade codex")):
            plan = doctor.update_plan("codex", "/opt/homebrew/bin/codex", "/opt/homebrew/%s/codex/0.160.0/codex" % kind,
                                      "homebrew")
            self.assertEqual((plan["runs"], plan["command"]), (False, expected))
        plan = doctor.update_plan("codex", "/Applications/ChatGPT.app/x", "/Applications/ChatGPT.app/Contents/x", "app")
        self.assertEqual((plan["runs"], plan["command"]), (False, None))

    def test_codex_managed_moves_the_package_and_reports_its_server(self):
        releases = self.home / ".codex/packages/app-server-daemon/releases"
        daemon = self.home / "daemon-version"
        daemon.write_text("0.166.0")
        old = fake(releases / "0.166.0-aarch64-apple-darwin/bin/codex", "0.166.0", "0.167.0")
        new = fake(releases / "0.167.0-aarch64-apple-darwin/bin/codex", "0.167.0")
        current = self.home / ".codex/packages/app-server-daemon/current"
        current.symlink_to(old.parent.parent)
        os.environ.update(AI_TODO_CODEX_BIN=str(current / "bin/codex"), FAKE_LINK=str(current),
                          FAKE_NEXT=str(new.parent.parent), FAKE_DAEMON=str(daemon))
        code, result = upgrade.upgrade("codex")
        self.assertEqual((code, result["result"], result["method"], result["before"], result["after"]),
                         (0, "updated", "managed", "0.166.0", "0.167.0"))
        self.assertEqual(self.updater_calls(), ["app-server daemon update --yes"])
        self.assertEqual(result["daemon"], "0.167.0")

    def test_cursor_native(self):
        versions = self.home / ".local/share/cursor-agent/versions"
        fake(versions / "2026.10.14-aaa/cursor-agent", "2026.10.14")
        fake(versions / "2026.10.19-bbb/cursor-agent", "2026.10.19")
        link = self.home / ".local/bin/agent"
        link.parent.mkdir(parents=True)
        link.symlink_to(versions / "2026.10.14-aaa/cursor-agent")
        os.environ.update(AI_TODO_AGENT_BIN=str(link), FAKE_LINK=str(link),
                          FAKE_NEXT=str(versions / "2026.10.19-bbb/cursor-agent"))
        code, result = upgrade.upgrade("cursor")
        self.assertEqual((code, result["result"], result["before"], result["after"]),
                         (0, "updated", "2026.10.14-aaa", "2026.10.19-bbb"))
        self.assertEqual(result["command"], "~/.local/bin/agent update")

    def test_not_installed(self):
        with patch.dict(upgrade.FINDERS, {"cursor": lambda: (_ for _ in ()).throw(FileNotFoundError("none"))}):
            code, result = upgrade.upgrade("cursor")
        self.assertEqual((code, result["result"]), (1, "failed"))

    def test_doctor_reports_how_it_would_update(self):
        self.claude_native()
        with patch.object(doctor, "auth", return_value={"logged_in": False}):
            report = doctor.tool_report("claude", lambda: os.environ["AI_TODO_CLAUDE_BIN"])
        self.assertEqual(report["update"], {"runs": True, "command": "~/.local/bin/claude update"})
        self.assertEqual(self.updater_calls(), [])

    def test_command_line(self):
        script = Path(__file__).with_name("ai-todo-status")
        self.claude_native()
        bad = subprocess.run([sys.executable, str(script), "upgrade", "gemini"], capture_output=True, text=True)
        self.assertEqual(bad.returncode, 64)
        done = subprocess.run([sys.executable, str(script), "upgrade", "claude"], capture_output=True, text=True)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(json.loads(done.stdout)["result"], "updated")


if __name__ == "__main__":
    unittest.main()
