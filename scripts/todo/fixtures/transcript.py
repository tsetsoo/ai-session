#!/usr/bin/env python3
"""Append Claude / Codex transcript turns for test-todo-scripts.sh.

  transcript.py claude|codex FILE CWD SESSION_ID STEP...

Steps (applied in order):
  --turn PROMPT ANSWER   a complete turn: prompt, an edit tool call, its result, the answer
  --open PROMPT          a turn still running: prompt, tool call and result, no end of turn
  --finish ANSWER        ends the running turn with ANSWER
  --partial PROMPT       a complete turn whose last line is half-written (no trailing newline);
                         the rest of it is kept in FILE.rest
  --rest                 finishes the half-written line from FILE.rest (and ends the turn)

Also importable: append(tool, path, cwd, sid, steps) with steps as [(kind, *args)].
Timestamps start at 2026-10-16T08:00:00Z and advance 10 s per line.
"""
import json
import os
import sys

BASE = 1792137600  # 2026-10-16T08:00:00Z


def _ts(n):
    import time
    return time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime(BASE + 10 * n))


class Writer:
    def __init__(self, tool, path, cwd, sid):
        self.tool, self.path, self.cwd, self.sid = tool, path, cwd, sid
        self.n = 0
        if os.path.exists(path):
            with open(path, "rb") as f:
                self.n = f.read().count(b"\n")
        self.lines = []
        self.rest = None
        if tool == "codex" and self.n == 0:
            self.add({"type": "session_meta", "payload": {"id": sid, "cwd": cwd, "source": "cli",
                                                          "originator": "codex_cli_rs"}})
            self.add({"type": "turn_context", "payload": {"cwd": cwd, "model": "gpt-5.5-codex"}})

    def add(self, entry, partial=False):
        k = self.n + len(self.lines)
        if self.tool == "claude":
            entry = dict({"uuid": "%s-%04d" % (self.sid[:8], k), "sessionId": self.sid, "cwd": self.cwd,
                          "timestamp": _ts(k)}, **entry)
        else:
            entry = dict({"timestamp": _ts(k)}, **entry)
        line = json.dumps(entry, ensure_ascii=False)
        if partial:
            self.rest = line[len(line) // 2:] + "\n"
            line = line[: len(line) // 2]
        self.lines.append(line + ("" if partial else "\n"))

    # --- Claude ---------------------------------------------------------------

    def claude_open(self, prompt):
        k = self.n + len(self.lines)
        self.add({"type": "user", "message": {"role": "user", "content": prompt}})
        mid = "msg_%s_%d" % (self.sid[:4], k)
        msg = {"id": mid, "role": "assistant", "model": "claude-opus-5-5", "stop_reason": "tool_use",
               "usage": {"input_tokens": 10, "output_tokens": 20, "cache_read_input_tokens": 100,
                         "cache_creation_input_tokens": 5}}
        self.add({"type": "assistant", "message": dict(msg, content=[{"type": "thinking", "thinking": "SECRET-THOUGHT"}])})
        self.add({"type": "assistant", "message": dict(msg, content=[{
            "type": "tool_use", "id": "t%d" % k, "name": "Edit",
            "input": {"file_path": os.path.join(self.cwd, "src", "f%d.py" % k), "old_string": "a", "new_string": "b"}}])})
        self.add({"type": "user", "message": {"role": "user", "content": [
            {"type": "tool_result", "tool_use_id": "t%d" % k, "content": "TOOL-OUTPUT-OK"}]}})

    def claude_finish(self, answer, partial=False):
        k = self.n + len(self.lines)
        self.add({"type": "assistant", "message": {
            "id": "msg_%s_%d" % (self.sid[:4], k), "role": "assistant", "model": "claude-opus-5-5",
            "stop_reason": "end_turn", "usage": {"input_tokens": 1, "output_tokens": 2},
            "content": [{"type": "text", "text": answer}]}}, partial=partial)
        self.add_turn_end(partial)

    def add_turn_end(self, partial):
        if partial:
            self.rest += json.dumps(dict({"type": "system", "subtype": "turn_duration", "durationMs": 1000},
                                         uuid="%s-rest" % self.sid[:8], sessionId=self.sid, cwd=self.cwd)) + "\n"
        else:
            self.add({"type": "system", "subtype": "turn_duration", "durationMs": 1000})

    # --- Codex ----------------------------------------------------------------

    def codex_open(self, prompt):
        self.add({"type": "event_msg", "payload": {"type": "task_started"}})
        self.add({"type": "response_item", "payload": {"type": "message", "role": "user",
                                                       "content": [{"type": "input_text", "text": prompt}]}})
        self.add({"type": "response_item", "payload": {"type": "reasoning", "summary": [{"type": "summary_text", "text": "SECRET-THOUGHT"}]}})
        self.add({"type": "response_item", "payload": {
            "type": "function_call", "name": "shell", "call_id": "c%d" % self.n,
            "arguments": json.dumps({"command": ["bash", "-lc", "cargo test -p todo-server"]})}})
        self.add({"type": "response_item", "payload": {
            "type": "function_call_output", "call_id": "c%d" % self.n,
            "output": json.dumps({"output": "TOOL-OUTPUT-OK", "metadata": {"exit_code": 0}})}})

    def codex_finish(self, answer, partial=False):
        self.add({"type": "response_item", "payload": {"type": "message", "role": "assistant",
                                                       "content": [{"type": "output_text", "text": answer}]}})
        self.add({"type": "event_msg", "payload": {"type": "token_count", "info": {"total_token_usage": {
            "input_tokens": 100, "cached_input_tokens": 50, "output_tokens": 10}}}})
        self.add({"type": "event_msg", "payload": {"type": "task_complete", "last_agent_message": answer}}, partial=partial)

    def step(self, kind, *args):
        opened = getattr(self, self.tool + "_open")
        finish = getattr(self, self.tool + "_finish")
        if kind == "turn":
            opened(args[0])
            finish(args[1])
        elif kind == "open":
            opened(args[0])
        elif kind == "finish":
            finish(args[0])
        elif kind == "partial":
            opened(args[0])
            finish("half written answer", partial=True)
        elif kind == "rest":
            with open(self.path + ".rest") as f:
                self.lines.append(f.read())
            os.remove(self.path + ".rest")
        else:
            raise SystemExit("unknown step " + kind)

    def write(self):
        os.makedirs(os.path.dirname(self.path), exist_ok=True)
        with open(self.path, "a", encoding="utf-8") as f:
            f.write("".join(self.lines))
        if self.rest is not None:
            with open(self.path + ".rest", "w", encoding="utf-8") as f:
                f.write(self.rest)


def append(tool, path, cwd, sid, steps):
    w = Writer(tool, path, cwd, sid)
    for s in steps:
        w.step(*s)
    w.write()


def main(argv):
    if len(argv) < 4 or argv[0] not in ("claude", "codex"):
        raise SystemExit(__doc__)
    tool, path, cwd, sid = argv[:4]
    rest, steps = argv[4:], []
    arity = {"--turn": 2, "--open": 1, "--finish": 1, "--partial": 1, "--rest": 0}
    while rest:
        flag = rest.pop(0)
        if flag not in arity or len(rest) < arity[flag]:
            raise SystemExit(__doc__)
        steps.append((flag[2:],) + tuple(rest[: arity[flag]]))
        del rest[: arity[flag]]
    append(tool, path, cwd, sid, steps)


if __name__ == "__main__":
    main(sys.argv[1:])
