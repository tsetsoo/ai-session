#!/usr/bin/env python3
"""Offline tests for resuming after a usage limit: a fake hub, fake tmux, fake limits."""
import json
import os
from pathlib import Path
import re
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from unittest.mock import patch

import ai_todo_resume as resume
import ai_todo_status as status

SID = "5a1c0b5e-0000-4000-8000-0000000000aa"
RULE = "─" * 60
# Real Claude Code input lines (capture-pane -e, 2026-11-06).
EMPTY = "\x1b[39m❯ "
EMPTY_BUSY_GREY = "\x1b[38;5;246m❯ \x1b[39m"
SUGGESTION = "\x1b[39m❯ \x1b[2mgo through the other worktrees\x1b[0m"
OLD_PLACEHOLDER = "\x1b[0m\x1b[38;5;246m❯\x1b[39m \x1b[38;5;246mdescribe a task for a new session\x1b[39m"
DRAFT = "\x1b[39m❯ half a thou"
HISTORY = "\x1b[38;5;246m\x1b[48;5;237m❯ \x1b[38;5;231mcleanup here\x1b[39m"
CODEX_PLACEHOLDER = "\x1b[1m›\x1b[0m \x1b[2mAsk Codex to do anything\x1b[0m"


def claude_screen(input_line=EMPTY):
    return "\n".join(["", HISTORY, "", "⏺ Working on it.", "", "  ⎿  You've hit your session limit · resets 2am", "",
                      RULE, input_line, RULE, "  ⏸ manual mode on · ? for shortcuts", ""])


def swift_fixtures():
    path = Path(__file__).resolve().parents[2] / "Tests" / "AISessionCoreTests" / "TerminalPromptFixtures.swift"
    if not path.exists():
        return {}
    return {name: body for name, body in re.findall(r'static let (\w+) = #"""\n(.*?)\n"""#', path.read_text(), re.S)}


class ScreenTests(unittest.TestCase):
    def test_question_cards_match_the_phone_parser_on_its_captures(self):
        fixtures = swift_fixtures()
        if not fixtures:
            self.skipTest("the app's fixtures are not next to these scripts")
        cards = {"claudeBash", "claudeBashNarrow", "claudeBashTipAtEdge", "claudeEdit", "claudeQuestion", "codexCommand",
                 "codexPatch"}
        not_cards = {"claudeIdle", "claudeNumberedReply", "codexIdle", "claudeTrust", "codexTrust"}
        self.assertLessEqual(cards | not_cards, set(fixtures))
        for name in cards:
            self.assertTrue(resume.question_card(fixtures[name].split("\n")), name)
        for name in not_cards:
            self.assertFalse(resume.question_card(fixtures[name].split("\n")), name)

    def test_empty_input_is_told_from_a_placeholder_and_a_draft(self):
        def state(line):
            return resume.input_state(claude_screen(line).split("\n"))
        self.assertEqual(state(EMPTY), "empty")
        self.assertEqual(state(EMPTY_BUSY_GREY), "empty")
        self.assertEqual(state(SUGGESTION), "empty")
        self.assertEqual(state(OLD_PLACEHOLDER), "empty")
        self.assertEqual(state(DRAFT), "draft")
        self.assertEqual(resume.input_state(["", "› Run the tests", "", CODEX_PLACEHOLDER, "", "  gpt · ~/x"]), "empty")
        self.assertEqual(resume.input_state(["", "\x1b[1m›\x1b[0m fix the build", ""]), "draft")
        self.assertEqual(resume.input_state(["$ ls", "file"]), "none")

    def test_a_question_card_is_never_typed_into(self):
        fixtures = swift_fixtures()
        if not fixtures:
            self.skipTest("the app's fixtures are not next to these scripts")
        with patch.object(resume, "capture", return_value=fixtures["claudeBash"].split("\n")):
            self.assertEqual(resume.screen_ready("ai/claude/todo-1"), "question")
        with patch.object(resume, "capture", return_value=fixtures["claudeIdle"].split("\n")):
            self.assertIsNone(resume.screen_ready("ai/claude/todo-1"))
        # The trust question isn't a card for the phone, but it isn't an empty prompt either.
        with patch.object(resume, "capture", return_value=fixtures["claudeTrust"].split("\n")):
            self.assertIsNotNone(resume.screen_ready("ai/claude/todo-1"))

    def test_headroom_reads_the_limits_windows(self):
        now = 2_000_000_000
        future, past = resume.iso(now + 3600), resume.iso(now - 60)
        self.assertEqual(resume.headroom(None, now), ("unknown", None))
        self.assertEqual(resume.headroom([{"kind": "5h", "used_percent": 12}], now), ("ok", None))
        self.assertEqual(resume.headroom([{"kind": "5h", "used_percent": 100, "resets_at": future}], now),
                         ("blocked", now + 3600))
        # Codex's last snapshot still says 100%, but its reset has passed.
        self.assertEqual(resume.headroom([{"kind": "5h", "used_percent": 100, "resets_at": past}], now), ("ok", None))
        self.assertEqual(resume.headroom([{"kind": "monthly", "used_percent": 100, "resets_at": future}], now), ("ok", None))


class FakeHub:
    def __init__(self):
        self.calls = []
        self.conversations = {}
        owner = self

        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                owner.calls.append(body)
                state = owner.conversations.get(body["session_id"])
                if state is None:
                    self.send_response(404)
                    self.end_headers()
                    return
                state = owner.act(state, body)
                data = json.dumps(state).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def log_message(self, *args):
                pass

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True)
        self.thread.start()

    def add(self, sid=SID, kind="session", resets_at=None, on=True, **extra):
        paused = {"kind": kind}
        if resets_at:
            paused["resets_at"] = resets_at
        self.conversations[sid] = dict({"conversation_id": "c-" + sid[:4], "tmux_name": "ai/codex/todo-" + sid[:8],
                                        "cwd": "~/code", "status": "idle", "paused": paused, "reviewed": False,
                                        "resume_on_reset": on, "token": None}, **extra)

    def act(self, state, body):
        """A small model of resume.rs: enough for the host's decisions."""
        action, granted, reason = body["action"], False, None
        paused = state.get("paused")
        if action == "arm" and paused:
            paused["resume_at"] = body.get("resume_at") if state["resume_on_reset"] and paused["kind"] == "session" else None
        elif action == "disarm" and paused:
            paused.pop("resume_at", None)
        elif action == "offer" and paused:
            paused["offer"] = True
        elif action == "claim":
            if not paused:
                reason = "not_paused"
            elif state["token"] and state["token"] != body["token"]:
                reason = "leased"
            elif not body.get("manual") and not state["resume_on_reset"]:
                reason = "toggle_off"
            else:
                granted, state["token"] = True, body["token"]
        elif action in ("sent", "release"):
            granted = state["token"] == body.get("token")
            if action == "release" and granted:
                state["token"] = None
        return dict({k: v for k, v in state.items() if k != "token"}, granted=granted, reason=reason)

    def actions(self):
        return [call["action"] for call in self.calls]

    def close(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()


FAKE_TMUX = r'''#!/usr/bin/env python3
import json, os, sys
d = os.environ["FAKE_TMUX_DIR"]
args = sys.argv[1:]
if args[:1] == ["-L"]:
    args = args[2:]
with open(os.path.join(d, "calls"), "a") as f:
    f.write(json.dumps(args) + "\n")
alive = os.path.exists(os.path.join(d, "alive"))
def read(name):
    p = os.path.join(d, name)
    return open(p).read() if os.path.exists(p) else ""
if args[0] == "has-session":
    sys.exit(0 if alive else 1)
if args[0] == "list-panes":
    # The tool's pane first; the user's shell split beside it is the active one.
    sys.stdout.write("0 1 %7\n0 0 %3\n"); sys.exit(0 if alive else 1)
if args[0] == "list-clients":
    sys.stdout.write(read("clients")); sys.exit(0 if alive else 1)
if args[0] == "capture-pane":
    if not alive: sys.exit(1)
    sys.stdout.write(read("screen")); sys.exit(0)
if args[0] == "send-keys":
    sys.exit(0 if alive else 1)
sys.exit(2)
'''

FAKE_OPEN = r'''#!/bin/sh
printf '%s\n' "$*" > "$FAKE_TMUX_DIR/opened"
touch "$FAKE_TMUX_DIR/alive"
cp "$FAKE_TMUX_DIR/screen-after-open" "$FAKE_TMUX_DIR/screen"
'''

FAKE_LIMITS = r'''#!/bin/sh
[ -f "$FAKE_TMUX_DIR/limits" ] || exit 75
cat "$FAKE_TMUX_DIR/limits"
'''


class ResumeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.home = Path(self.temp.name)
        self.fake = self.home / "fake"
        self.fake.mkdir()
        self.hub = FakeHub()
        conf = self.home / "hub.conf"
        conf.write_text("TODO_HUB_URL='http://127.0.0.1:%s'\nTODO_API_TOKEN='not-a-real-token'\n" % self.hub.server.server_port)
        for name, text in (("tmux", FAKE_TMUX), ("ai-todo-open", FAKE_OPEN), ("ai-todo-limits", FAKE_LIMITS)):
            path = self.fake / ("bin-" + name)
            path.write_text(text)
            path.chmod(0o755)
        self.environment = patch.dict(os.environ, {
            "HOME": str(self.home), "AI_TODO_STATUS_DIR": str(self.home / "queue"), "AI_TODO_HUB_CONF": str(conf),
            "FAKE_TMUX_DIR": str(self.fake), "AI_TODO_TMUX": str(self.fake / "bin-tmux"),
            "AI_TODO_OPEN_BIN": str(self.fake / "bin-ai-todo-open"), "AI_TODO_LIMITS_BIN": str(self.fake / "bin-ai-todo-limits")})
        self.environment.start()
        os.environ.pop("AI_TODO_TMUX_SOCKET", None)  # test-todo-scripts.sh exports its own
        self.sleep = patch.object(resume.time, "sleep", lambda s: None)
        self.sleep.start()
        self.write("screen", claude_screen())
        self.write("alive", "")

    def tearDown(self):
        self.sleep.stop()
        self.environment.stop()
        self.hub.close()
        self.temp.cleanup()

    def write(self, name, text):
        (self.fake / name).write_text(text)

    def typed(self):
        path = self.fake / "calls"
        calls = [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []
        return [call[3:] for call in calls if call[0] == "send-keys"]

    def pause(self, kind="session", resets_at=None, paused_at=None):
        pause = {"kind": kind}
        if resets_at:
            pause["resets_at"] = resets_at
        with status.session_lock(SID, tool="codex"):
            resume.note_pause("codex", SID, pause, int((paused_at or time.time()) * 1e9))

    def entry(self):
        return status.read_json(resume.entry_path("codex", SID))

    def tick(self, now):
        entry = self.entry()
        self.assertIsNotNone(entry)
        return resume.tick_one(entry, now)

    def test_a_session_limit_resumes_after_the_reset_with_the_toggle_on(self):
        now = time.time()
        reset = now + 3600
        self.pause(resets_at=resume.iso(reset), paused_at=now)
        self.hub.add(resets_at=resume.iso(reset))
        # Before the reset: the planned time goes to the hub, nothing is typed.
        self.assertEqual(self.tick(now + 10), "armed")
        armed = self.hub.conversations[SID]["paused"]["resume_at"]
        self.assertGreaterEqual(resume.epoch(armed), reset + resume.GRACE_S)
        self.assertLessEqual(resume.epoch(armed), reset + resume.GRACE_S + resume.JITTER_S)
        self.assertEqual(self.tick(now + 30), "waiting", "re-armed once a minute, not every tick")
        self.assertEqual(self.typed(), [])
        # After it: the lease, then Escape, the message and Enter to the exact =name: target.
        self.assertEqual(self.tick(reset + 300), "resumed")
        self.assertEqual(self.typed(), [["Escape"], ["-l", resume.TEXT], ["Enter"]])
        calls = [json.loads(line) for line in (self.fake / "calls").read_text().splitlines()]
        # Into the tool's own pane, never the active shell beside it.
        targets = {call[call.index("-t") + 1] for call in calls if call[0] in ("send-keys", "capture-pane")}
        self.assertEqual(targets, {"%3"})
        self.assertEqual(self.hub.actions()[-2:], ["claim", "sent"])
        self.assertIsNone(self.entry(), "done with it")

    def test_switching_the_toggle_off_cancels_the_resume_and_on_again_resumes(self):
        now = time.time()
        self.pause(resets_at=resume.iso(now - 300), paused_at=now - 3600)
        self.hub.add(resets_at=resume.iso(now - 300), on=False)
        self.hub.conversations[SID]["paused"]["resume_at"] = resume.iso(now - 100)
        self.assertEqual(self.tick(now), "off")
        self.assertEqual(self.typed(), [])
        self.assertEqual(self.hub.actions(), ["state", "disarm"])
        self.assertAlmostEqual(self.entry()["next_at"], now + resume.RETRY_S, delta=1)
        # Switched on after the reset: it resumes at the next look.
        self.hub.conversations[SID]["resume_on_reset"] = True
        self.assertEqual(self.tick(now + resume.RETRY_S + 1), "resumed")
        # Left off for half a day: forgotten, nothing typed or offered.
        self.pause(resets_at=resume.iso(now - 300), paused_at=now - 3600)
        self.hub.conversations[SID].update(resume_on_reset=False, token=None)
        self.assertEqual(self.tick(now + 13 * 3600), "off")
        self.assertIsNone(self.entry())
        self.assertNotIn("offer", self.hub.actions())

    def test_weekly_and_unknown_limits_are_offered_never_typed(self):
        now = time.time()
        self.pause(kind="weekly", resets_at=resume.iso(now - 60), paused_at=now - 7200)
        self.hub.add(kind="weekly", resets_at=resume.iso(now - 60))
        self.assertEqual(self.tick(now - 3600), "waiting")
        self.assertNotIn("arm", self.hub.actions(), "a weekly limit is never planned")
        self.assertEqual(self.tick(now + 200), "offered")
        self.assertTrue(self.hub.conversations[SID]["paused"]["offer"])
        self.assertEqual(self.typed(), [])

    def test_a_reset_missed_by_half_a_day_is_offered(self):
        now = time.time()
        self.pause(resets_at=resume.iso(now - 13 * 3600), paused_at=now - 15 * 3600)
        self.hub.add(resets_at=resume.iso(now - 13 * 3600))
        self.assertEqual(self.tick(now), "offered")
        self.assertEqual(self.typed(), [])

    def test_the_cap_turns_into_an_offer(self):
        now = time.time()
        self.pause(resets_at=resume.iso(now - 300), paused_at=now - 3600)
        self.hub.add(resets_at=resume.iso(now - 300), on=False, resume_off_reason="cap")
        self.assertEqual(self.tick(now), "offered")

    def test_no_reset_time_backs_off_then_reads_the_limits(self):
        now = time.time()
        self.pause(kind="limit", paused_at=now)
        self.hub.add(kind="limit")
        entry = self.entry()
        self.assertAlmostEqual(resume.due(entry), now + 300, delta=1)
        self.assertEqual(self.tick(now + 301), "backoff", "no reading yet")
        self.assertAlmostEqual(resume.due(self.entry()), now + 300 + 900, delta=1)
        self.write("limits", json.dumps({"tool": "claude", "windows": [
            {"kind": "5h", "used_percent": 100, "resets_at": resume.iso(now + 7200)}]}))
        self.assertEqual(self.tick(now + 1201), "reset_found")
        self.assertEqual(self.entry()["resets_at"], resume.iso(now + 7200))
        # At that reset it is offered (an unknown kind is never typed).
        self.assertEqual(self.tick(now + 7200 + 300), "offered")
        # Without any reading it offers after the third step.
        self.hub.calls.clear()
        self.pause(kind="limit", paused_at=now)
        (self.fake / "limits").unlink()
        for step in (301, 1201, 3001):
            result = self.tick(now + step)
        self.assertEqual(result, "offered")

    def test_recent_input_waits_but_a_fresh_attach_or_old_input_does_not(self):
        now = time.time()
        paused = now - 3600
        self.pause(resets_at=resume.iso(now - 300), paused_at=paused)
        self.hub.add(resets_at=resume.iso(now - 300))
        # You are at it right now: wait, don't type over you, don't give up.
        self.write("clients", "%d %d\n" % (time.time() - 30, now - 1800))
        self.assertEqual(self.tick(now), "retry:typed")
        self.assertEqual(self.typed(), [])
        self.assertNotIn("claim", self.hub.actions())
        # The app attached after the pause and answered the terminal's queries right away.
        self.write("clients", "%d %d\n" % (time.time() - 1, time.time() - 3))
        self.assertEqual(self.tick(now + 400), "resumed")
        # Input after the pause but minutes ago (scrolling to read it) doesn't hold it up.
        self.pause(resets_at=resume.iso(now - 300), paused_at=paused)
        self.hub.conversations[SID]["token"] = None
        self.write("clients", "%d %d\n" % (time.time() - 600, now - 1800))
        self.assertEqual(self.tick(now + 800), "resumed")

    def test_the_screen_is_checked_again_after_the_lease(self):
        now = time.time()
        self.pause(resets_at=resume.iso(now - 300), paused_at=now - 3600)
        self.hub.add(resets_at=resume.iso(now - 300))
        # You start typing while the limits are read and the lease is taken.
        real_hub = resume.hub
        def hub(action, *args, **kwargs):
            if action == "claim":
                self.write("screen", claude_screen(DRAFT))
            return real_hub(action, *args, **kwargs)
        with patch.object(resume, "hub", hub):
            self.assertEqual(self.tick(now), "retry:draft")
        self.assertEqual(self.typed(), [])
        self.assertEqual(self.hub.actions()[-3:], ["claim", "release", "arm"])

    def test_a_question_card_or_a_draft_waits(self):
        fixtures = swift_fixtures()
        now = time.time()
        self.pause(resets_at=resume.iso(now - 300), paused_at=now - 3600)
        self.hub.add(resets_at=resume.iso(now - 300))
        if fixtures:
            self.write("screen", fixtures["claudeQuestion"])
            self.assertEqual(self.tick(now), "retry:question")
            self.assertAlmostEqual(self.entry()["next_at"], now + resume.RETRY_S, delta=5)
        self.write("screen", claude_screen(DRAFT))
        self.assertEqual(self.tick(now + 400), "retry:draft")
        self.assertEqual(self.typed(), [])
        self.assertNotIn("claim", self.hub.actions(), "no lease taken for a screen that can't take it")
        self.write("screen", claude_screen(SUGGESTION))
        self.assertEqual(self.tick(now + 800), "resumed")

    def test_still_limited_waits_for_the_new_reset(self):
        now = time.time()
        self.pause(resets_at=resume.iso(now - 300), paused_at=now - 3600)
        self.hub.add(resets_at=resume.iso(now - 300))
        self.write("limits", json.dumps({"tool": "claude", "windows": [
            {"kind": "5h", "used_percent": 100, "resets_at": resume.iso(now + 1800)}]}))
        self.assertEqual(self.tick(now), "retry:limit")
        self.assertAlmostEqual(self.entry()["next_at"], now + 1800 + resume.GRACE_S, delta=1)
        self.assertEqual(self.typed(), [])

    def test_another_claimant_holds_the_lease(self):
        now = time.time()
        self.pause(resets_at=resume.iso(now - 300), paused_at=now - 3600)
        self.hub.add(resets_at=resume.iso(now - 300))
        self.hub.conversations[SID]["token"] = "someone-else"
        self.assertEqual(self.tick(now), "retry:leased")
        self.assertEqual(self.typed(), [])

    def test_a_closed_session_is_reopened_first(self):
        now = time.time()
        self.pause(resets_at=resume.iso(now - 300), paused_at=now - 3600)
        self.hub.add(resets_at=resume.iso(now - 300))
        (self.fake / "alive").unlink()
        self.write("screen-after-open", claude_screen())
        self.assertEqual(self.tick(now), "resumed")
        self.assertEqual((self.fake / "opened").read_text().split(),
                         ["--detached", "ai/codex/todo-5a1c0b5e", "~/code", SID, "codex"])
        self.assertEqual(self.typed(), [["Escape"], ["-l", resume.TEXT], ["Enter"]])

    def test_a_reopened_session_with_a_question_is_released(self):
        fixtures = swift_fixtures()
        if not fixtures:
            self.skipTest("the app's fixtures are not next to these scripts")
        now = time.time()
        self.pause(resets_at=resume.iso(now - 300), paused_at=now - 3600)
        self.hub.add(resets_at=resume.iso(now - 300))
        (self.fake / "alive").unlink()
        self.write("screen-after-open", fixtures["claudeTrust"])
        with patch.object(resume, "REOPEN_WAIT_S", 0.01):
            self.assertTrue(self.tick(now).startswith("retry:"))
        self.assertEqual(self.typed(), [])
        self.assertEqual(self.hub.actions()[-3:], ["claim", "release", "arm"])

    def test_still_limited_without_a_known_reset_invents_no_time(self):
        now = time.time()
        self.hub.add(kind="weekly", on=False)
        self.write("limits", json.dumps({"tool": "claude", "windows": [{"kind": "weekly", "used_percent": 100}]}))
        self.assertEqual(resume.resume_now("codex", SID), (75, {"resumed": False, "reason": "limit"}))

    def test_the_pause_ending_stops_everything(self):
        now = time.time()
        self.pause(resets_at=resume.iso(now + 3600), paused_at=now - 120)
        self.hub.add(resets_at=resume.iso(now + 3600))
        self.hub.conversations[SID]["paused"] = None
        self.assertEqual(self.tick(now), "dropped")
        self.assertIsNone(self.entry())

    def test_a_pause_the_hub_has_not_heard_of_yet_is_kept(self):
        now = time.time()
        self.pause(resets_at=resume.iso(now + 3600), paused_at=now - 10)
        self.hub.add(resets_at=resume.iso(now + 3600))
        self.hub.conversations[SID]["paused"] = None
        self.assertEqual(self.tick(now), "waiting", "just paused: the post may still be on its way")
        record = status.root() / (SID + ".json")
        status.atomic_json(record, {"body": {}, "pending": True})
        self.assertEqual(self.tick(now + 600), "waiting", "the outbox still has it")
        status.atomic_json(record, {"body": {}, "pending": False})
        self.assertEqual(self.tick(now + 700), "dropped")

    def test_the_one_tap_resume(self):
        now = time.time()
        self.hub.add(kind="weekly", resets_at=resume.iso(now - 60), on=False)
        code, result = resume.resume_now("codex", SID)
        self.assertEqual((code, result), (0, {"resumed": True}))
        self.assertTrue(self.hub.calls[1]["manual"])
        self.write("limits", json.dumps({"tool": "claude", "windows": [
            {"kind": "weekly", "used_percent": 100, "resets_at": resume.iso(now + 600)}]}))
        self.hub.conversations[SID]["token"] = None
        code, result = resume.resume_now("codex", SID)
        self.assertEqual((code, result["reason"], result["resets_at"]), (75, "limit", resume.iso(now + 600)))
        self.hub.conversations[SID]["paused"] = None
        self.assertEqual(resume.resume_now("codex", SID), (75, {"resumed": False, "reason": "not_paused"}))
        self.assertEqual(resume.resume_now("claude", "nobody"), (75, {"resumed": False, "reason": "unknown"}))
        self.assertEqual(resume.resume_now("claude", "../x"), (75, {"resumed": False, "reason": "unknown"}))


class PublishTests(unittest.TestCase):
    """The publisher leaves and removes the entries the loop works from."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.home = Path(self.temp.name)
        conf = self.home / "hub.conf"
        conf.write_text("TODO_HUB_URL='http://127.0.0.1:9'\n")
        self.environment = patch.dict(os.environ, {"HOME": str(self.home), "AI_TODO_STATUS_DIR": str(self.home / "queue"),
                                                   "AI_TODO_HUB_CONF": str(conf)})
        self.environment.start()

    def tearDown(self):
        self.environment.stop()
        self.temp.cleanup()

    def entry(self):
        return status.read_json(resume.entry_path("claude", SID))

    def limit(self, at):
        status.publish({"tool": "claude", "session_id": SID, "status": "idle", "_hook_event": "StopFailure",
                        "_limit": {"message": "You've hit your session limit · resets 2am (Europe/Sofia)"}}, at, try_send=False)

    def test_a_claude_session_pause_is_left_to_claude(self):
        self.limit(100)
        self.assertIsNone(self.entry(), "Claude continues on its own")
        # A weekly one gets the one-tap offer: it is noted.
        status.publish({"tool": "claude", "session_id": SID, "status": "idle", "_hook_event": "StopFailure",
                        "_limit": {"message": "You've hit your weekly limit · resets Mon 1am"}}, 200, try_send=False)
        self.assertEqual(self.entry()["kind"], "weekly")
        # An idle heartbeat keeps it; typing starts a turn and forgets it.
        status.publish({"tool": "claude", "session_id": SID, "status": "idle"}, 300, source="runtime", try_send=False)
        self.assertIsNotNone(self.entry())
        status.publish({"tool": "claude", "session_id": SID, "status": "busy", "_hook_event": "UserPromptSubmit"}, 400,
                       try_send=False)
        self.assertIsNone(self.entry())

    def test_a_codex_pause_is_noted(self):
        sid = "0019f8b4-ff53-7201-8585-162b40a93fb3"
        with status.session_lock(sid, tool="codex"):
            resume.note_pause("codex", sid, {"kind": "session", "resets_at": "2026-11-06T22:00:00Z"}, 100)
        self.assertEqual(status.read_json(resume.entry_path("codex", sid))["paused_ns"], 100)

    def weekly(self, at):
        status.publish({"tool": "claude", "session_id": SID, "status": "idle", "_hook_event": "StopFailure",
                        "_limit": {"message": "You've hit your weekly limit · resets Mon 1am"}}, at, try_send=False)

    def test_claude_continuing_on_its_own_cancels_ours(self):
        self.weekly(100)
        self.assertIsNotNone(self.entry())
        hook = str(Path(__file__).with_name("ai-todo-hook"))
        env = dict(os.environ, AI_TODO_HOOK_SYNC="1", AI_TODO_TMUX_SESSION="other",
                   AI_TODO_MEMORY_BIN=str(self.home / "no-memory-helper"))
        import subprocess
        subprocess.run([hook, "waiting"], input=json.dumps({
            "session_id": SID, "hook_event_name": "Notification", "notification_type": "quota_auto_resume_fired",
            "message": "Resuming after the usage limit"}), env=env, capture_output=True, text=True, check=True)
        record = status.read_json(status.root() / ("claude." + SID + ".json"))
        self.assertEqual(record["body"]["status"], "busy")
        self.assertIsNone(self.entry())
        # Even a stale report of it (older than what was published) drops a newer pause.
        self.weekly(2**62)
        self.assertIsNotNone(self.entry())
        status.publish({"tool": "claude", "session_id": SID, "status": "busy", "_hook_event": "Notification",
                        "_auto_resumed": True}, 500, try_send=False)
        self.assertIsNone(self.entry())


if __name__ == "__main__":
    unittest.main()
