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
import unittest.mock

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

    def test_after_returns_only_later_lines(self):
        with tempfile.TemporaryDirectory() as home:
            project = os.path.join(home, "p")
            os.makedirs(project)
            with open(os.path.join(project, "sid.jsonl"), "w") as handle:
                for text in ("one", "two", "three"):
                    handle.write(json.dumps({"type": "user", "message": {"content": text}}) + "\n")
            old = transcript.CLAUDE_PROJECTS
            transcript.CLAUDE_PROJECTS = home
            try:
                out = io.StringIO()
                with contextlib.redirect_stdout(out):
                    self.assertEqual(transcript.main(["claude", "sid", "--json", "--activity", "--after", "0"]), 0)
                later = json.loads(out.getvalue())
                with contextlib.redirect_stderr(io.StringIO()):
                    self.assertEqual(transcript.main(["claude", "sid", "--json", "--activity", "--after", "x"]), 64)
            finally:
                transcript.CLAUDE_PROJECTS = old
        self.assertEqual([m["text"] for m in later], ["two", "three"])
        self.assertEqual([m["id"] for m in later], ["1.0", "2.0"])

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


NOW = 1_800_000_000.0


def stamp(seconds):
    return transcript.iso_of(seconds)


def write_jsonl(path, rows, mtime=None):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as handle:
        for row in rows:
            handle.write(json.dumps(row) + "\n")
    if mtime is not None:
        os.utime(path, (mtime, mtime))


def agent_call(use_id, description, at, **extra):
    return {"type": "assistant", "timestamp": stamp(at), "message": {"content": [
        {"type": "tool_use", "id": use_id, "name": "Agent",
         "input": dict({"description": description, "subagent_type": "general-purpose", "prompt": "Do " + description}, **extra)}]}}


def agent_result(use_id, outcome, at, is_error=False, text="ok"):
    part = {"type": "tool_result", "tool_use_id": use_id, "content": [{"type": "text", "text": text}]}
    if is_error:
        part["is_error"] = True
    return {"type": "user", "timestamp": stamp(at), "toolUseResult": outcome, "message": {"content": [part]}}


def notice(agent, use_id, status, at, summary="", result="", usage=""):
    return {"type": "queue-operation", "operation": "enqueue", "timestamp": stamp(at), "content":
            "<task-notification>\n<task-id>%s</task-id>\n<tool-use-id>%s</tool-use-id>\n<status>%s</status>\n"
            "<summary>%s</summary>\n<result>%s</result>\n%s</task-notification>" % (agent, use_id, status, summary, result, usage)}


def handback(agent, report, at):
    body = "\n".join("  " + line for line in report.splitlines())
    return {"type": "queue-operation", "operation": "enqueue", "timestamp": stamp(at), "content":
            '<agent-message from="%s">\n[Subagent hand-back] Frame text. The report follows:\n%s\n</agent-message>' % (agent, body)}


class DelegationTests(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.TemporaryDirectory()
        self.addCleanup(self.home.cleanup)
        self.projects = os.path.join(self.home.name, "claude")
        self.sessions = os.path.join(self.home.name, "codex")
        for name, value in (("CLAUDE_PROJECTS", self.projects), ("CODEX_SESSIONS", self.sessions)):
            old = getattr(transcript, name)
            setattr(transcript, name, value)
            self.addCleanup(setattr, transcript, name, old)
        self.parent = os.path.join(self.projects, "proj", "sid.jsonl")
        self.agents = os.path.join(self.projects, "proj", "sid", "subagents")

    def agent(self, ident, meta, rows, mtime):
        os.makedirs(self.agents, exist_ok=True)
        with open(os.path.join(self.agents, "agent-%s.meta.json" % ident), "w") as handle:
            json.dump(meta, handle)
        write_jsonl(os.path.join(self.agents, "agent-%s.jsonl" % ident), rows, mtime)

    def workers(self, tool="claude", sid="sid"):
        out = io.StringIO()
        with contextlib.redirect_stdout(out), unittest.mock.patch("time.time", return_value=NOW):
            self.assertEqual(transcript.main([tool, sid, "--subagents"]), 0)
        return {worker["id"]: worker for worker in json.loads(out.getvalue())}

    def sub_rows(self, task, last, at):
        return [{"type": "user", "timestamp": stamp(at), "isSidechain": True, "message": {"content": task}}, last]

    def end_turn(self, text, at):
        return {"type": "assistant", "timestamp": stamp(at), "isSidechain": True,
                "message": {"stop_reason": "end_turn", "content": [{"type": "text", "text": text}]}}

    def test_claude_background_agent_handed_back_with_totals(self):
        write_jsonl(self.parent, [
            agent_call("tu1", "Review branch", NOW - 900, run_in_background=True),
            agent_result("tu1", {"status": "async_launched", "agentId": "a1", "description": "Review branch",
                                 "resolvedModel": "claude-opus-5-5", "isAsync": True}, NOW - 899),
            handback("a1", "Found 2 bugs.\n\n  - indented item", NOW - 300),
            notice("a1", "tu1", "completed", NOW - 300, 'Agent "Review branch" finished',
                   "This agent's report was delivered to you as a message",
                   "<usage><subagent_tokens>6000</subagent_tokens><tool_uses>16</tool_uses><duration_ms>600000</duration_ms></usage>"),
        ])
        self.agent("a1", {"agentType": "general-purpose", "description": "Review branch", "toolUseId": "tu1",
                          "requestShape": "background", "finished": True},
                   self.sub_rows("Do Review branch", self.end_turn("Found 2 bugs.", NOW - 301), NOW - 899), NOW - 301)
        worker = self.workers()["a1"]
        self.assertEqual((worker["state"], worker["evidence"]), ("done", "handed back its report"))
        self.assertEqual(worker["result"], "Found 2 bugs.\n\n  - indented item")
        self.assertEqual((worker["tokens"], worker["toolCount"], worker["durationMs"]), (6000, 16, 600000))
        self.assertEqual((worker["title"], worker["kind"], worker["model"], worker["background"]),
                         ("Review branch", "general-purpose", "claude-opus-5-5", True))
        self.assertEqual(worker["task"], "Do Review branch")

    def test_claude_states_without_a_report(self):
        write_jsonl(self.parent, [agent_call("tu%d" % n, "job %d" % n, NOW - 2000) for n in range(1, 4)])
        running = {"type": "assistant", "timestamp": stamp(NOW - 5), "isSidechain": True,
                   "message": {"stop_reason": "tool_use", "content": [{"type": "tool_use", "name": "Bash", "input": {}}]}}
        self.agent("a1", {"description": "job 1", "toolUseId": "tu1", "requestShape": "foreground"},
                   self.sub_rows("t", running, NOW - 60), NOW - 5)
        self.agent("a2", {"description": "job 2", "toolUseId": "tu2", "requestShape": "background"},
                   self.sub_rows("t", dict(running, timestamp=stamp(NOW - 3600)), NOW - 4000), NOW - 3600)
        # Older Claude Code writes no "finished": a last message that ended the turn means done.
        self.agent("a3", {"description": "job 3", "toolUseId": "tu3"},
                   self.sub_rows("t", self.end_turn("All set.", NOW - 3600), NOW - 4000), NOW - 3600)
        workers = self.workers()
        self.assertEqual(set(workers), {"a1", "a2", "a3"})
        self.assertEqual(workers["a1"]["state"], "working")
        self.assertIn("last write 5 s ago", workers["a1"]["evidence"])
        self.assertEqual(workers["a2"]["state"], "stale")
        self.assertEqual(workers["a2"]["lastSeenAt"], stamp(NOW - 3600))
        self.assertEqual((workers["a3"]["state"], workers["a3"]["result"]), ("done", "All set."))
        self.assertTrue(workers["a3"]["evidence"].startswith("inferred"))

    def test_claude_failures_give_the_reason_not_a_mid_work_line(self):
        write_jsonl(self.parent, [
            agent_call("tu1", "stalls", NOW - 2000),
            agent_result("tu1", {"status": "async_launched", "agentId": "a1"}, NOW - 1999),
            notice("a1", "tu1", "failed", NOW - 1000, 'Agent "stalls" failed: Agent stalled: no progress for 600s',
                   "Now I'll write the test first."),
            agent_call("tu2", "no worktree", NOW - 900),
            agent_result("tu2", "Error: Cannot create agent worktree", NOW - 899, is_error=True,
                         text="Cannot create agent worktree: not in a git repository"),
            agent_call("tu3", "killed", NOW - 800),
            agent_result("tu3", {"status": "async_launched", "agentId": "a3"}, NOW - 799),
            notice("a3", "tu3", "killed", NOW - 700),
        ])
        self.agent("a1", {"description": "stalls", "toolUseId": "tu1"},
                   self.sub_rows("t", self.end_turn("Now I'll write the test first.", NOW - 1001), NOW - 1999), NOW - 1001)
        workers = self.workers()
        self.assertEqual((workers["a1"]["state"], workers["a1"]["evidence"], workers["a1"]["result"]),
                         ("failed", "Agent stalled: no progress for 600s", None))
        self.assertEqual(workers["tu2"]["state"], "failed")
        self.assertIn("not in a git repository", workers["tu2"]["evidence"])
        self.assertEqual((workers["a3"]["state"], workers["a3"]["evidence"]), ("failed", "stopped"))

    def test_claude_agent_resumed_after_its_report_is_working_again(self):
        write_jsonl(self.parent, [
            agent_call("tu1", "review", NOW - 2000),
            agent_result("tu1", {"status": "async_launched", "agentId": "a1"}, NOW - 1999),
            handback("a1", "First report.", NOW - 600),
        ])
        self.agent("a1", {"description": "review", "toolUseId": "tu1", "finished": True},
                   self.sub_rows("t", self.end_turn("First report.", NOW - 20), NOW - 1999), NOW - 20)
        worker = self.workers()["a1"]
        self.assertEqual(worker["state"], "working")
        self.assertTrue(worker["evidence"].startswith("resumed after its last report"))

    def test_claude_worker_transcript_and_unsafe_ids(self):
        write_jsonl(self.parent, [{"type": "user", "message": {"content": "hi"}}])
        self.agent("a1", {}, self.sub_rows("Do it", self.end_turn("Done it", NOW), NOW), NOW)
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertEqual(transcript.main(["claude", "sid/a1", "--json"]), 0)
        self.assertEqual([m["text"] for m in json.loads(out.getvalue())], ["Do it", "Done it"])
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(transcript.main(["claude", "sid/../sid", "--json"]), 94)
            self.assertEqual(transcript.main(["claude", "sid/missing", "--json"]), 94)
            self.assertEqual(transcript.main(["cursor", "sid", "--subagents"]), 64)

    def codex_message(self, role, text, at):
        return {"timestamp": stamp(at), "type": "response_item",
                "payload": {"type": "message", "role": role, "content": [{"type": "input_text", "text": text}]}}

    def codex_event(self, kind, at, **payload):
        return {"timestamp": stamp(at), "type": "event_msg", "payload": dict(payload, type=kind)}

    def test_codex_child_skips_the_copied_parent_history(self):
        parent_id, child_id = "0000-parent", "0000-child"
        write_jsonl(os.path.join(self.sessions, "2026", "11", "06", "rollout-x-%s.jsonl" % parent_id), [
            {"timestamp": stamp(NOW - 5000), "type": "session_meta", "payload": {"id": parent_id, "source": "cli"}}])
        inherited = [self.codex_message("user", "parent question", NOW - 4000),
                     self.codex_event("task_complete", NOW - 3999, last_agent_message="parent answer")]
        spawn = {"thread_spawn": {"parent_thread_id": parent_id, "depth": 1, "agent_path": "/root/probe", "agent_nickname": "Kuhn"}}
        write_jsonl(os.path.join(self.sessions, "2026", "11", "06", "rollout-y-%s.jsonl" % child_id), [
            {"timestamp": stamp(NOW - 3000), "type": "session_meta", "payload": {"id": child_id, "source": {"subagent": spawn}}},
            *inherited,
            self.codex_message("developer", "You are now a newly spawned child agent. The preceding conversation is inherited.", NOW - 3000),
            self.codex_event("task_started", NOW - 3000),
            {"timestamp": stamp(NOW - 2990), "type": "turn_context", "payload": {"model": "gpt-6.1-sol"}},
            {"timestamp": stamp(NOW - 2980), "type": "response_item", "payload": {"type": "function_call", "name": "exec_command", "arguments": "{\"cmd\": \"ls\"}"}},
            self.codex_message("assistant", "first task done", NOW - 2000),
            self.codex_event("task_complete", NOW - 2000, last_agent_message="first task done"),
            self.codex_event("task_started", NOW - 1500),
            self.codex_event("task_complete", NOW - 1000, last_agent_message=None, error={"message": "You've hit your usage limit."}),
        ], NOW - 1000)
        # Not a child of this parent: a guardian reviewer.
        write_jsonl(os.path.join(self.sessions, "2026", "11", "06", "rollout-z-0000-guard.jsonl"), [
            {"timestamp": stamp(NOW - 3000), "type": "session_meta", "payload": {"id": "0000-guard", "source": {"subagent": {"other": "guardian"}}}}])
        workers = self.workers("codex", parent_id)
        self.assertEqual(list(workers), [child_id])
        worker = workers[child_id]
        self.assertEqual((worker["title"], worker["kind"], worker["model"]), ("probe", "Kuhn", "gpt-6.1-sol"))
        self.assertEqual((worker["state"], worker["evidence"], worker["result"]), ("failed", "You've hit your usage limit.", None))
        self.assertEqual((worker["startedAt"], worker["durationMs"], worker["toolCount"]), (stamp(NOW - 3000), 2_000_000, 1))
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertEqual(transcript.main(["codex", parent_id + "/" + child_id, "--json"]), 0)
        self.assertEqual([m["text"] for m in json.loads(out.getvalue())], ["first task done"])
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(transcript.main(["codex", "0000-other/" + child_id, "--json"]), 94)


if __name__ == "__main__":
    unittest.main()
