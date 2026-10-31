#!/usr/bin/env python3
"""Offline regression tests for the chat transcript's roles and exact whitespace."""
import contextlib
import importlib.machinery
import importlib.util
import io
import json
import os
import tempfile
import unittest

loader = importlib.machinery.SourceFileLoader("transcript", os.path.join(os.path.dirname(__file__), "ai-todo-transcript"))
spec = importlib.util.spec_from_loader(loader.name, loader)
transcript = importlib.util.module_from_spec(spec)
loader.exec_module(transcript)


class TranscriptTests(unittest.TestCase):
    text = "  first  line\n\n    indented\tcode  \n\n"

    def read(self, reader, entries):
        with tempfile.NamedTemporaryFile(mode="w", suffix=".jsonl") as handle:
            for entry in entries:
                handle.write(json.dumps(entry) + "\n")
            handle.write('{"incomplete":')
            handle.flush()
            return list(reader(handle.name))

    def test_claude_keeps_roles_and_spacing_and_omits_tool_results(self):
        result = self.read(transcript.claude_lines, [
            {"type": "user", "message": {"content": self.text}},
            {"type": "assistant", "message": {"content": [
                {"type": "thinking", "thinking": "private"},
                {"type": "text", "text": self.text},
                {"type": "tool_use", "name": "Bash"}]}},
            {"type": "user", "message": {"content": [{"type": "tool_result", "content": "secret output"}]}},
        ])
        self.assertEqual(result, [{"role": "user", "text": self.text}, {"role": "assistant", "text": self.text}])

    def test_codex_keeps_text_without_duplicate_event_messages(self):
        result = self.read(transcript.codex_lines, [
            {"type": "response_item", "payload": {"type": "message", "role": "user", "content": [{"type": "input_text", "text": self.text}]}},
            {"type": "response_item", "payload": {"type": "message", "role": "assistant", "content": [{"type": "output_text", "text": self.text}]}},
            {"type": "event_msg", "payload": {"type": "agent_message", "message": self.text}},
            {"type": "response_item", "payload": {"type": "reasoning", "summary": "private"}},
        ])
        self.assertEqual(result, [{"role": "user", "text": self.text}, {"role": "assistant", "text": self.text}])

    def test_cursor_supports_nested_messages(self):
        result = self.read(transcript.cursor_lines, [
            {"role": "user", "content": self.text},
            {"message": {"role": "assistant", "content": [{"type": "text", "text": self.text}]}},
        ])
        self.assertEqual(result, [{"role": "user", "text": self.text}, {"role": "assistant", "text": self.text}])

    def read_activity(self, reader, entries):
        with tempfile.NamedTemporaryFile(mode="w", suffix=".jsonl") as handle:
            for entry in entries:
                handle.write(json.dumps(entry) + "\n")
            handle.write('{"incomplete":')
            handle.flush()
            return list(reader(handle.name, activity=True))

    def test_claude_activity_kinds_targets_and_order(self):
        time = "2026-10-31T10:00:00.000Z"
        result = self.read_activity(transcript.claude_lines, [
            {"type": "assistant", "timestamp": time, "message": {"content": [
                {"type": "text", "text": "Looking."},
                {"type": "tool_use", "name": "Read", "input": {"file_path": "/r/a.swift"}},
                {"type": "tool_use", "name": "Bash", "input": {"command": "npm test\nsecond line"}},
                {"type": "tool_use", "name": "Grep", "input": {"pattern": "redirect_uri"}},
                {"type": "tool_use", "name": "Edit", "input": {"file_path": "/r/b.swift"}},
                {"type": "tool_use", "name": "TodoWrite", "input": {}}]}},
        ])
        self.assertEqual([m["role"] for m in result], ["assistant"] + ["activity"] * 5)
        self.assertEqual([m.get("kind") for m in result[1:]], ["read", "run", "search", "edit", "other"])
        self.assertEqual([m.get("target") for m in result[1:]], ["/r/a.swift", "npm test", "redirect_uri", "/r/b.swift", "TodoWrite"])
        self.assertEqual([m["id"] for m in result], ["0.0", "0.1", "0.2", "0.3", "0.4", "0.5"])
        self.assertTrue(all(m["time"] == time for m in result))
        self.assertTrue(all(m["text"] == "" for m in result[1:]))

    def test_long_command_target_is_truncated(self):
        result = self.read_activity(transcript.claude_lines, [
            {"type": "assistant", "message": {"content": [{"type": "tool_use", "name": "Bash", "input": {"command": "x" * 5000}}]}},
        ])
        self.assertEqual(len(result[0]["target"]), 120)

    def test_tool_use_without_input_is_other_with_name(self):
        result = self.read_activity(transcript.claude_lines, [
            {"type": "assistant", "message": {"content": [{"type": "tool_use", "name": "Mystery"}]}},
        ])
        self.assertEqual((result[0]["kind"], result[0]["target"], result[0]["name"]), ("other", "Mystery", "Mystery"))

    def test_codex_function_calls_become_activity(self):
        result = self.read_activity(transcript.codex_lines, [
            {"type": "response_item", "payload": {"type": "function_call", "name": "shell", "arguments": '{"command":["bash","-lc","rg foo"]}'}},
            {"type": "response_item", "payload": {"type": "function_call", "name": "exec_command", "arguments": '{"cmd":"npm test"}'}},
            {"type": "response_item", "payload": {"type": "custom_tool_call", "name": "apply_patch", "input": "*** Begin Patch\n*** Update File: src/a.ts\n@@\n-a\n+b\n*** End Patch"}},
        ])
        self.assertEqual([m["kind"] for m in result], ["run", "run", "edit"])
        self.assertEqual([m["target"] for m in result], ["rg foo", "npm test", "src/a.ts"])

    def test_codex_code_mode_exec_calls_become_activity(self):
        # codex-cli 0.166 runs tools from JavaScript through one "exec" custom tool.
        result = self.read_activity(transcript.codex_lines, [
            {"type": "response_item", "payload": {"type": "custom_tool_call", "name": "exec",
                "input": 'text(await tools.exec_command({cmd:"npm test -- \\"auth\\"",sandbox_permissions:"require_escalated"}));'}},
            {"type": "response_item", "payload": {"type": "custom_tool_call", "name": "exec",
                "input": 'text(await tools.apply_patch("*** Begin Patch\\n*** Update File: /r/.gitignore\\n@@\\n+x\\n*** End Patch"));'}},
            {"type": "response_item", "payload": {"type": "custom_tool_call", "name": "exec",
                "input": 'text(await tools.exec_command({cmd:"apply_patch <<\'PATCH\'\\n*** Begin Patch\\n*** Add File: b.txt\\n+hi\\n*** End Patch\\nPATCH"}));'}},
            {"type": "response_item", "payload": {"type": "custom_tool_call", "name": "exec",
                "input": 'text(await tools.web__run({search_query:[{q:"hilton availability api"}]}));'}},
            {"type": "response_item", "payload": {"type": "custom_tool_call", "name": "exec",
                "input": 'text(await tools.write_stdin({session_id:3,chars:""}));'}},
        ])
        self.assertEqual([m["kind"] for m in result], ["run", "edit", "edit", "search", "other"])
        self.assertEqual([m["target"] for m in result], ['npm test -- "auth"', "/r/.gitignore", "b.txt", "hilton availability api", "write_stdin"])

    def test_json_without_activity_is_unchanged(self):
        with tempfile.TemporaryDirectory() as home:
            project = os.path.join(home, "p")
            os.makedirs(project)
            with open(os.path.join(project, "sid.jsonl"), "w") as handle:
                handle.write(json.dumps({"type": "user", "message": {"content": "hi"}}) + "\n")
                handle.write(json.dumps({"type": "assistant", "message": {"content": [
                    {"type": "text", "text": "yo"}, {"type": "tool_use", "name": "Bash", "input": {"command": "ls"}}]}}) + "\n")
            old = transcript.CLAUDE_PROJECTS
            transcript.CLAUDE_PROJECTS = home
            try:
                out = io.StringIO()
                with contextlib.redirect_stdout(out):
                    self.assertEqual(transcript.main(["claude", "sid", "--json"]), 0)
                plain = json.loads(out.getvalue())
                out = io.StringIO()
                with contextlib.redirect_stdout(out):
                    self.assertEqual(transcript.main(["claude", "sid", "--json", "--activity"]), 0)
                rich = json.loads(out.getvalue())
                with contextlib.redirect_stderr(io.StringIO()):
                    self.assertEqual(transcript.main(["claude", "sid", "--json", "--bogus"]), 64)
            finally:
                transcript.CLAUDE_PROJECTS = old
        self.assertEqual(plain, [{"role": "user", "text": "hi", "id": "0"}, {"role": "assistant", "text": "yo", "id": "1"}])
        self.assertEqual([m["role"] for m in rich], ["user", "assistant", "activity"])

    def test_ids_are_stable_when_lines_are_appended(self):
        with tempfile.NamedTemporaryFile(mode="w", suffix=".jsonl") as handle:
            handle.write(json.dumps({"type": "user", "message": {"content": "a"}}) + "\n")
            handle.write(json.dumps({"type": "assistant", "message": {"content": [{"type": "tool_use", "name": "Bash", "input": {"command": "ls"}}]}}) + "\n")
            handle.flush()
            first = list(transcript.claude_lines(handle.name, activity=True))
            handle.write(json.dumps({"type": "assistant", "message": {"content": [{"type": "text", "text": "done"}]}}) + "\n")
            handle.flush()
            second = list(transcript.claude_lines(handle.name, activity=True))
        self.assertEqual(second[:len(first)], first)
        self.assertEqual(len(second), len(first) + 1)


if __name__ == "__main__":
    unittest.main()
