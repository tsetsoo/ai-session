#!/usr/bin/env python3
"""Offline doctor regressions: fake binaries and process tables, no real CLIs, tmux or hub."""
import json
import os
from pathlib import Path
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from unittest.mock import patch

import ai_todo_doctor as doctor
import ai_todo_status as status

HOME = "/Users/me"


class PathTests(unittest.TestCase):
    def test_install_method_and_version_from_each_layout(self):
        cases = [
            (HOME + "/.local/share/claude/versions/2.1.319", "native", "2.1.319"),
            (HOME + "/.local/share/claude/versions/2.1.310 (deleted)", "native", "2.1.310"),
            (HOME + "/.local/share/claude/ClaudeCode.app/Contents/MacOS/claude", "native", None),
            (HOME + "/.codex/packages/app-server-daemon/releases/0.167.0-aarch64-apple-darwin/bin/codex", "managed", "0.167.0"),
            (HOME + "/.codex/packages/app-server-daemon/releases/0.166.0-x86_64-unknown-linux-musl/bin/codex", "managed", "0.166.0"),
            (HOME + "/.local/share/cursor-agent/versions/2026.10.19-6bbf2c4/cursor-agent", "native", "2026.10.19-6bbf2c4"),
            (HOME + "/.local/share/cursor-agent/versions/2026.10.16-e3cb207/index.js", "native", "2026.10.16-e3cb207"),
            ("/opt/homebrew/Cellar/codex/0.160.0/bin/codex", "homebrew", "0.160.0"),
            ("/opt/homebrew/Caskroom/claude-code/2.1.300/claude", "homebrew", "2.1.300"),
            ("/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex", "app", None),
            ("/usr/bin/somewhere", "other", None),
        ]
        for path, method, version in cases:
            with self.subTest(path=path):
                self.assertEqual(doctor.install_method(path), method)
                self.assertEqual(doctor.path_version(path), version)
        self.assertIsNone(doctor.install_method(None))
        self.assertIsNone(doctor.path_version(None))

    def test_npm_version_comes_from_the_package(self):
        with tempfile.TemporaryDirectory() as temp:
            package = Path(temp) / ".nvm/versions/node/v20.12.0/lib/node_modules/@openai/codex"
            (package / "bin").mkdir(parents=True)
            (package / "package.json").write_text(json.dumps({"name": "@openai/codex", "version": "0.164.0"}))
            script = package / "bin" / "codex.js"
            script.write_text("")
            self.assertEqual(doctor.install_method(str(script)), "npm")
            self.assertEqual(doctor.path_version(str(script)), "0.164.0")


class ProcessTests(unittest.TestCase):
    def test_tool_and_session_from_argv(self):
        claude = [HOME + "/.local/bin/claude", "--resume", "sess-1", "--mcp-config", "x.json"]
        self.assertEqual((doctor.tool_of(claude), doctor.session_of("claude", claude)), ("claude", "sess-1"))
        fresh = ["claude", "--session-id", "sess-2"]
        self.assertEqual(doctor.session_of("claude", fresh), "sess-2")
        codex = ["/x/codex", "-c", "check_for_update_on_startup=false", "--remote", "unix:///s.sock", "--cd", "/w", "resume", "019f"]
        self.assertEqual((doctor.tool_of(codex), doctor.session_of("codex", codex)), ("codex", "019f"))
        self.assertIsNone(doctor.session_of("codex", ["/x/codex", "--approve-for-me"]))
        npm = ["node", HOME + "/.nvm/versions/node/v20/lib/node_modules/@openai/codex/bin/codex.js", "resume", "01a1"]
        self.assertEqual(doctor.tool_of(npm), "codex")
        npm_claude = ["/usr/local/bin/node", "/usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js"]
        self.assertEqual(doctor.tool_of(npm_claude), "claude")
        cursor = [HOME + "/.local/bin/cursor-agent", "--use-system-ca", HOME + "/.local/share/cursor-agent/versions/2026.10.19-6bbf2c4/index.js", "--resume", "c-1"]
        self.assertEqual((doctor.tool_of(cursor), doctor.session_of("cursor", cursor)), ("cursor", "c-1"))
        for other in [[], ["/bin/sh", "-c", "claude"], ["python3", "ai-todo-status", "terminal"], ["node", "server.js"]]:
            self.assertIsNone(doctor.tool_of(other), other)


class RunningTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.environment = patch.dict(os.environ, {"AI_TODO_STATUS_DIR": self.temp.name})
        self.environment.start()

    def tearDown(self):
        self.environment.stop()
        self.temp.cleanup()

    def test_each_session_reports_the_version_it_runs(self):
        claude_old = HOME + "/.local/share/claude/versions/2.1.310"
        claude_new = HOME + "/.local/share/claude/versions/2.1.319"
        codex_old = HOME + "/.codex/packages/app-server-daemon/releases/0.166.0-aarch64-apple-darwin/bin/codex"
        codex_new = HOME + "/.codex/packages/app-server-daemon/releases/0.167.0-aarch64-apple-darwin/bin/codex"
        table = {
            # ai/claude/todo-a: sh (ai-todo-open) -> sh -c (mcp env) -> claude -> an MCP server
            100: (1, ["/bin/sh", "/x/ai-todo-open"]),
            101: (100, ["/bin/sh", "-c", ". env; exec claude"]),
            102: (101, [HOME + "/.local/bin/claude", "--resume", "s-a", "--api-key", "SECRET"]),
            103: (102, ["node", "mcp-server.js"]),
            # ai/claude/todo-b: current
            200: (1, [HOME + "/.local/bin/claude", "--session-id", "s-b"]),
            # ai/codex/todo-c: TUI on the new version, its backend still the old one
            300: (1, ["/bin/sh", "/x/ai-todo-open"]),
            301: (300, [HOME + "/.codex/packages/app-server-daemon/current/bin/codex", "--remote", "unix:///r.sock", "resume", "t-c"]),
            310: (301, [HOME + "/.codex/packages/app-server-daemon/current/bin/codex", "app-server", "--listen", "unix:///r.sock"]),
            # a plain shell and an unknown executable
            400: (1, ["/bin/zsh"]),
            500: (1, [HOME + "/.local/bin/claude"]),
        }
        sessions = {"ai/claude/todo-a": [100], "ai/claude/todo-b": [200], "ai/codex/todo-c": [300],
                    "shell": [400], "ai/claude/todo-e": [500], "gone": [999]}
        record = status.terminal_socket("ai/codex/todo-c").with_suffix(".json")
        record.parent.mkdir(parents=True)
        record.write_text(json.dumps({"pid": 310}))
        exes = {102: claude_old, 200: claude_new, 301: codex_new, 310: codex_old,
                500: HOME + "/.local/share/claude/ClaudeCode.app/Contents/MacOS/claude"}
        found = doctor.running_report({"claude": "2.1.319", "codex": "0.167.0"}, table, sessions, exes)
        by_name = {entry["tmux"]: entry for entry in found}
        self.assertEqual(sorted(by_name), ["ai/claude/todo-a", "ai/claude/todo-b", "ai/claude/todo-e", "ai/codex/todo-c"])
        a = by_name["ai/claude/todo-a"]
        self.assertEqual((a["pid"], a["session_id"], a["version"], a["outdated"]), (102, "s-a", "2.1.310", True))
        self.assertNotIn("SECRET", json.dumps(found), "argv is never reported")
        b = by_name["ai/claude/todo-b"]
        self.assertEqual((b["version"], b["outdated"]), ("2.1.319", False))
        c = by_name["ai/codex/todo-c"]
        self.assertEqual((c["version"], c["backend_pid"], c["backend_version"], c["outdated"]), ("0.167.0", 310, "0.166.0", True))
        e = by_name["ai/claude/todo-e"]
        self.assertEqual((e["version"], e["outdated"]), (None, None), "an unknown version is not called outdated")

    def test_no_tmux_is_unknown_not_empty(self):
        self.assertIsNone(doctor.running_report({}, {}, None, {}))
        self.assertEqual(doctor.running_report({}, {}, {}, {}), [])

    def test_lsof_output_takes_each_process_first_txt(self):
        fake = Path(self.temp.name) / "lsof"
        fake.write_text("#!/bin/sh\nprintf 'p10\\nn/a/claude\\nn/usr/lib/dyld\\np11\\nn/b/codex\\n'\n")
        fake.chmod(0o755)
        with patch.dict(os.environ, {"AI_TODO_LSOF": str(fake)}), patch("os.path.isdir", lambda p: False if p == "/proc/self" else os.path.isdir(p)):
            self.assertEqual(doctor.executables([10, 11]), {10: "/a/claude", 11: "/b/codex"})
        self.assertEqual(doctor.executables([]), {})


class DeliveryAndHelperTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.environment = patch.dict(os.environ, {"AI_TODO_STATUS_DIR": str(self.root / "queue")})
        self.environment.start()

    def tearDown(self):
        self.environment.stop()
        self.temp.cleanup()

    def test_pending_records_are_split_by_meaning(self):
        now = time.time_ns()
        queue = status.root()
        queue.mkdir()

        def record(name, pending, error, age_s):
            body = {"session_id": name, "status": "idle", "event_timestamp_ns": now - age_s * 1_000_000_000}
            (queue / (name + ".json")).write_text(json.dumps({"pending": pending, "last_error": error, "body": body}))

        record("fresh", True, None, 5)
        record("unlinked", True, "HTTP 404", 7200)
        record("old-unsent", True, None, 600)
        record("refused", True, "HTTP 500", 90)
        record("done", False, None, 10)
        (queue / "health.json").write_text(json.dumps({"pending": True}))
        result = doctor.delivery_report(now)
        self.assertEqual((result["in_flight"], result["unlinked"], result["failing"]), (1, 1, 2))
        self.assertEqual(result["errors"], {"not sent": 1, "HTTP 500": 1})
        self.assertEqual(result["oldest_failing_s"], 600)

    def test_helpers_digest_tracks_the_files(self):
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        (bin_dir / "ai-todo-open").write_text("one")
        (bin_dir / "ai_todo_status.py").write_text("two")
        (bin_dir / "unrelated").write_text("x")
        plain = doctor.helpers_report(bin_dir)
        self.assertEqual((plain["commit"], plain["files"]), (None, 2))
        (bin_dir / "unrelated").write_text("changed")
        self.assertEqual(doctor.helpers_report(bin_dir)["digest"], plain["digest"])
        (bin_dir / "ai-todo-open").write_text("one, edited")
        self.assertNotEqual(doctor.helpers_report(bin_dir)["digest"], plain["digest"])
        (bin_dir / "helpers-version.json").write_text(json.dumps(
            {"commit": "abc123", "dirty": False, "installed_at": "2026-11-06T10:00:00Z", "files": ["ai-todo-open", "missing"]}))
        stamped = doctor.helpers_report(bin_dir)
        self.assertEqual((stamped["commit"], stamped["dirty"], stamped["files"]), ("abc123", False, 1))
        self.assertIsNone(doctor.helpers_report(self.root / "nothing")["digest"])


class ToolTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.bin = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def fake(self, name, script):
        path = self.bin / name
        path.write_text("#!/bin/sh\n" + script)
        path.chmod(0o755)
        return str(path)

    def test_auth_answers_without_account_details(self):
        claude = self.fake("claude", """[ "$1 $2" = "auth status" ] && cat <<'J'
{"loggedIn": true, "authMethod": "claude.ai", "email": "someone@example.com", "orgName": "Org",
 "loginExpiresAt": "2026-11-30T12:26:32.471Z"}
J
""")
        result = doctor.auth("claude", claude)
        self.assertEqual(result, {"logged_in": True, "method": "claude.ai", "expires_at": "2026-11-30T12:26:32.471Z"})
        codex = self.fake("codex", 'echo "Logged in using ChatGPT"\n')
        self.assertEqual(doctor.auth("codex", codex), {"logged_in": True, "method": "ChatGPT"})
        cursor = self.fake("agent", '[ "$AGENT_CLI_CREDENTIAL_STORE" = file ] && echo "Not logged in" || echo "Logged in as x@y.z"\n')
        self.assertEqual(doctor.auth("cursor", cursor), {"logged_in": False})
        cursor_in = self.fake("agent2", 'echo "✓ Logged in as someone@example.com"\n')
        self.assertEqual(doctor.auth("cursor", cursor_in), {"logged_in": True})
        broken = self.fake("broken", "exit 3\n")
        self.assertEqual(doctor.auth("claude", broken), {"logged_in": None})
        self.assertEqual(doctor.auth("codex", broken), {"logged_in": None})

    def test_version_falls_back_to_the_cli(self):
        binary = self.fake("claude", '[ "$1" = --version ] && echo "2.1.400 (Claude Code)"\n')
        with patch.object(doctor, "auth", return_value={"logged_in": None}):
            result = doctor.tool_report("claude", lambda: binary)
        self.assertEqual((result["installed"], result["version"], result["method"]), (True, "2.1.400", "other"))

        def missing():
            raise FileNotFoundError("No working Claude binary")
        self.assertEqual(doctor.tool_report("claude", missing), {"installed": False, "error": "No working Claude binary"})


class ReportTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.requests = []
        self.http_status = 200
        owner = self

        class Hub(BaseHTTPRequestHandler):
            def do_PUT(self):
                owner.requests.append((self.path, self.headers.get("Authorization"),
                                       json.loads(self.rfile.read(int(self.headers["Content-Length"])))))
                self.send_response(owner.http_status)
                self.end_headers()

            def log_message(self, *args):
                pass

        self.hub = ThreadingHTTPServer(("127.0.0.1", 0), Hub)
        self.thread = threading.Thread(target=self.hub.serve_forever, daemon=True)
        self.thread.start()
        self.conf = Path(self.temp.name) / "hub.conf"
        self.environment = patch.dict(os.environ, {"AI_TODO_HUB_CONF": str(self.conf)})
        self.environment.start()
        os.environ.pop("TODO_COMPUTER_ID", None)

    def tearDown(self):
        self.environment.stop()
        self.hub.shutdown()
        self.hub.server_close()
        self.thread.join()
        self.temp.cleanup()

    def write_conf(self, computer="mac 1"):
        self.conf.write_text("TODO_HUB_URL='http://127.0.0.1:%d'\nTODO_API_TOKEN='not-a-real-token'\n%s"
                             % (self.hub.server_port, "TODO_COMPUTER_ID='%s'\n" % computer if computer else ""))

    def test_report_puts_the_doctor_json(self):
        self.write_conf()
        with patch.object(doctor, "doctor", return_value={"doctor_version": 3, "tools": {}}):
            self.assertEqual(doctor.report(), 0)
            self.http_status = 404
            self.assertEqual(doctor.report(), 3, "an older hub (or unknown computer) is its own code")
            self.http_status = 500
            self.assertEqual(doctor.report(), 1)
        path, authorization, body = self.requests[0]
        self.assertEqual(path, "/api/computers/mac%201/health")
        self.assertEqual(authorization, "Bearer not-a-real-token")
        self.assertEqual(body, {"doctor_version": 3, "tools": {}})

    def test_report_needs_a_computer_id(self):
        self.write_conf(computer=None)
        with patch.object(doctor, "doctor", return_value={}):
            with self.assertRaises(ValueError):
                doctor.report()
        self.assertEqual(self.requests, [])


if __name__ == "__main__":
    unittest.main()
