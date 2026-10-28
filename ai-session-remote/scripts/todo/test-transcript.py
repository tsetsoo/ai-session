#!/usr/bin/env python3
"""Offline regression tests for the chat transcript's roles and exact whitespace."""
import importlib.machinery
import importlib.util
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


if __name__ == "__main__":
    unittest.main()
