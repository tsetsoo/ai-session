#!/usr/bin/env python3
"""Offline tests for ai_todo_updates: fake hub, fake claude/codex, fake sessions and transcripts."""
import json
import os
import stat
import sys
import tempfile
import threading
import unittest
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ai_todo_updates as up  # noqa: E402

DAY = "2026-11-02"  # window 2026-11-02 06:00Z .. 2026-11-03 06:00Z (EET)


def utc(text):
    return datetime.fromisoformat(text).replace(tzinfo=timezone.utc)


def script(path, body):
    path.write_text("#!/bin/sh\n" + body)
    path.chmod(path.stat().st_mode | stat.S_IEXEC)
    return str(path)


class FakeHub:
    def __init__(self):
        self.requests = []
        self.work = {"settings": {"five_hour": 60, "weekly": 80, "claude_model": "haiku", "codex_model": "gpt-6.1-terra"},
                     "days": [DAY], "projects": [], "write": []}
        self.matched = []
        owner = self

        class Handler(BaseHTTPRequestHandler):
            def _reply(self, value):
                raw = json.dumps(value).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(raw)))
                self.end_headers()
                self.wfile.write(raw)

            def _body(self):
                n = int(self.headers.get("Content-Length") or 0)
                return json.loads(self.rfile.read(n)) if n else None

            def do_GET(self):
                owner.requests.append(("GET", self.path, None))
                self._reply(owner.work)

            def do_POST(self):
                body = self._body()
                owner.requests.append(("POST", self.path, body))
                if self.path == "/api/updates/match":
                    self._reply([m for m in owner.matched if any(s["session_id"] == m["session_id"] for s in body["sessions"])])
                else:
                    self._reply({"stored": len(body.get("items", [])), "skipped": 0} if "items" in body else {"ok": True})

            def do_PUT(self):
                owner.requests.append(("PUT", self.path, self._body()))
                self._reply({"day": DAY, "waiting_on": []})

            def log_message(self, *args):
                pass

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.url = "http://127.0.0.1:%d" % self.server.server_address[1]

    def posted(self, path):
        return [b for (m, p, b) in self.requests if m in ("POST", "PUT") and p == path]


class Base(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.home = Path(self.temp.name)
        (self.home / "bin").mkdir()
        self.hub = FakeHub()
        conf = self.home / "todo-hub.conf"
        conf.write_text("TODO_HUB_URL=%s\nTODO_API_TOKEN=t0ken-for-tests\nTODO_COMPUTER_ID=mac\n" % self.hub.url)
        self.sessions = []
        self.transcripts = {}
        self.model_answers = self.home / "answers.jsonl"
        self.model_log = self.home / "model-stdin.log"
        self.calls = self.home / "model-calls.log"
        self.env = patch.dict(os.environ, {
            "HOME": str(self.home),
            "AI_TODO_HUB_CONF": str(conf),
            "AI_TODO_UPDATES_STATE_DIR": str(self.home / "state"),
            "AI_TODO_SESSIONS_BIN": self._sessions_bin(),
            "AI_TODO_TRANSCRIPT_BIN": self._transcript_bin(),
            "AI_TODO_CLAUDE_BIN": self._model_bin("claude"),
            "AI_TODO_CODEX_BIN": self._model_bin("codex"),
            "AI_TODO_LIMITS_BIN": script(self.home / "bin" / "limits", "exit 3\n"),
        })
        self.env.start()

    def tearDown(self):
        self.env.stop()
        self.hub.server.shutdown()
        self.hub.server.server_close()
        self.temp.cleanup()

    def _sessions_bin(self):
        return script(self.home / "bin" / "sessions", 'cat "%s/sessions.json"\n' % self.home)

    def _transcript_bin(self):
        return script(self.home / "bin" / "transcript", 'f="%s/t-$2.json"; [ -f "$f" ] || exit 94; cat "$f"\n' % self.home)

    def _model_bin(self, name):
        # Records stdin, then answers the next line of answers.jsonl (as claude's JSON envelope,
        # or into codex's -o file). FAIL as the answer exits 1.
        return script(self.home / "bin" / name, r'''
echo "{name}" >>"{calls}"
printf '%s\n' "$@" >>"{log}"
cat >>"{log}"
line=$(head -n 1 "{answers}"); tail -n +2 "{answers}" >"{answers}.rest"; mv "{answers}.rest" "{answers}"
[ "$line" = FAIL ] && exit 1
if [ "{name}" = codex ]; then
  while [ "$#" -gt 0 ]; do [ "$1" = -o ] && printf '%s' "$line" >"$2"; shift; done
else
  python3 -c 'import json,sys; print(json.dumps({{"type":"result","is_error":False,"structured_output":json.loads(sys.argv[1])}}))' "$line"
fi
'''.format(name=name, calls=self.calls, log=self.model_log, answers=self.model_answers))

    def answer(self, *values):
        with open(self.model_answers, "a") as f:
            for v in values:
                f.write((v if isinstance(v, str) else json.dumps(v)) + "\n")

    def add_session(self, sid, cwd="~/w/a", entries=(), tool="claude", updated="2026-11-02T12:00:00Z", project="pa"):
        self.sessions.append({"tool": tool, "session_id": sid, "cwd": cwd, "title": "Title " + sid, "updated_at": updated})
        (self.home / "sessions.json").write_text(json.dumps(self.sessions))
        (self.home / ("t-%s.json" % sid)).write_text(json.dumps(list(entries)))
        if project:
            self.hub.matched.append({"tool": tool, "session_id": sid, "project_id": project})

    def model_calls(self):
        return self.calls.read_text().split() if self.calls.exists() else []


def entry(text, time, role="user"):
    return {"role": role, "text": text, "time": time}


class PureTests(unittest.TestCase):
    def test_day_window(self):
        self.assertEqual(up.day_window("2026-11-02"), (utc("2026-11-02 06:00:00"), utc("2026-11-03 06:00:00")))
        self.assertEqual(up.day_window("2026-10-24"), (utc("2026-10-24 05:00:00"), utc("2026-10-25 06:00:00")))

    def test_window_entries_edges(self):
        start, end = up.day_window(DAY)
        entries = [entry("before", "2026-11-02T05:59:59.999Z"), entry("first", "2026-11-02T06:00:00.000Z"),
                   entry("last", "2026-11-03T05:59:59Z"), entry("next day", "2026-11-03T06:00:00Z"),
                   {"role": "user", "text": "no time"}]
        self.assertEqual([e["text"] for e in up.window_entries(entries, start, end)], ["first", "last"])

    def test_transcript_text_truncates_middle(self):
        text = "".join(chr(65 + i % 26) for i in range(100000))
        out = up.transcript_text([{"role": "user", "text": text}])
        self.assertLessEqual(len(out), 60003)
        body = out[len("user: "):]
        self.assertTrue(body.startswith(text[:10000 - len("user: ")]))
        self.assertTrue(out.endswith(text[-50000:]))
        self.assertIn("[…]", out)

    def test_transcript_text_formats_activity(self):
        out = up.transcript_text([{"role": "user", "text": "fix it"},
                                  {"role": "activity", "text": "", "kind": "run", "target": "cargo test"},
                                  {"role": "assistant", "text": "done"}])
        self.assertEqual(out, "user: fix it\n· run cargo test\nassistant: done")

    def test_pick_model(self):
        s = {"five_hour": 60, "weekly": 80, "claude_model": "haiku", "codex_model": "gpt-6.1-terra"}
        usage = lambda readings: (lambda tool: readings.get(tool))  # noqa: E731
        self.assertEqual(up.pick_model(s, usage({})), ("claude", "haiku"))
        self.assertEqual(up.pick_model(s, usage({"claude": {"5h": 10, "weekly": 10}})), ("claude", "haiku"))
        self.assertEqual(up.pick_model(s, usage({"claude": {"5h": 70, "weekly": 10}, "codex": {"5h": 10, "weekly": 10}})),
                         ("codex", "gpt-6.1-terra"))
        self.assertIsNone(up.pick_model(s, usage({"claude": {"5h": 10, "weekly": 90}, "codex": {"5h": 70, "weekly": 10}})))

    def test_verified_keys(self):
        self.assertEqual(up.verified_keys(["EIN-1", "XYZ-9", "lower-1", "EIN-1"], "worked on EIN-1", "title"), ["EIN-1"])
        self.assertEqual(up.verified_keys(["CH-12"], "x", "CH-12 title"), ["CH-12"])
        self.assertEqual(up.verified_keys(["EIN-1"], "EIN-12 only"), [])


class SummarizeRunTests(Base):
    def test_posts_summaries_and_reports(self):
        self.add_session("s1", entries=[entry("work on EIN-1 please", "2026-11-02T09:00:00Z"),
                                        entry("done", "2026-11-02T09:05:00Z", "assistant")])
        self.answer({"summary": "Fixed EIN-1.", "jira_keys": ["EIN-1", "XYZ-9"], "committed": True})
        self.assertEqual(up.main(["run"]), 0)
        posted = self.hub.posted("/api/updates/summaries")
        self.assertEqual(len(posted), 1)
        item = posted[0]["items"][0]
        self.assertEqual((posted[0]["day"], item["session_id"], item["summary"], item["jira_keys"], item["model"]),
                         (DAY, "s1", "Fixed EIN-1.", ["EIN-1"], "claude haiku"))
        self.assertEqual(self.hub.posted("/api/updates/reports"), [{"computer_id": "mac", "day": DAY}])

    def test_skips_sessions_outside_window_and_unmatched(self):
        self.add_session("old", updated="2026-11-01T10:00:00Z", entries=[entry("x", "2026-11-01T10:00:00Z")])
        self.add_session("off", project=None, entries=[entry("x", "2026-11-02T10:00:00Z")])
        self.add_session("quiet", entries=[entry("x", "2026-11-03T07:00:00Z")])
        up.main(["run"])
        self.assertEqual(self.model_calls(), [])
        match = self.hub.posted("/api/updates/match")[0]
        self.assertEqual([s["session_id"] for s in match["sessions"]], ["off", "quiet"])
        self.assertEqual(self.hub.posted("/api/updates/summaries"), [])
        self.assertEqual(len(self.hub.posted("/api/updates/reports")), 1)

    def test_secrets_never_reach_model_or_hub(self):
        secret = "sk-ant-api03-" + "Ab3" * 30
        self.add_session("s1", entries=[entry("use key " + secret, "2026-11-02T09:00:00Z")])
        self.answer({"summary": "Used " + secret, "jira_keys": [], "committed": False})
        up.main(["run"])
        self.assertNotIn(secret, self.model_log.read_text())
        self.assertNotIn(secret, json.dumps(self.hub.posted("/api/updates/summaries")))

    def test_codex_fallback_when_claude_limited(self):
        script(self.home / "bin" / "limits",
               'if [ "$2" = claude ]; then echo \'{"windows":[{"kind":"5h","used_percent":95}]}\'; '
               'else echo \'{"windows":[{"kind":"5h","used_percent":5},{"kind":"weekly","used_percent":5}]}\'; fi\n')
        self.add_session("s1", entries=[entry("x", "2026-11-02T09:00:00Z")])
        self.answer({"summary": "S", "jira_keys": [], "committed": False})
        up.main(["run"])
        self.assertEqual(self.model_calls(), ["codex"])
        self.assertEqual(self.hub.posted("/api/updates/summaries")[0]["items"][0]["model"], "codex gpt-6.1-terra")

    def test_waits_without_headroom(self):
        script(self.home / "bin" / "limits", "echo '{\"windows\":[{\"kind\":\"weekly\",\"used_percent\":99}]}'\n")
        self.add_session("s1", entries=[entry("x", "2026-11-02T09:00:00Z")])
        up.main(["run"])
        self.assertEqual(self.model_calls(), [])
        self.assertEqual(self.hub.posted("/api/updates/reports"), [])
        self.assertIn('"wait"', (self.home / "state" / "updates.log").read_text())

    def test_failing_conversation_skipped_after_three_runs(self):
        self.add_session("s1", entries=[entry("x", "2026-11-02T09:00:00Z")])
        self.add_session("s2", entries=[entry("y", "2026-11-02T09:00:00Z")])
        self.answer({"summary": "two", "jira_keys": [], "committed": False}, "FAIL")  # s1 then s2, in list order
        up.main(["run"])
        self.assertEqual(self.hub.posted("/api/updates/reports"), [])
        self.answer("FAIL")
        up.main(["run"])
        self.assertEqual(self.hub.posted("/api/updates/reports"), [])
        self.answer("FAIL")
        up.main(["run"])
        self.assertEqual(len(self.hub.posted("/api/updates/reports")), 1)
        self.assertEqual(len(self.model_calls()), 4, "the posted one isn't summarized again")
        failed = [i for b in self.hub.posted("/api/updates/summaries") for i in b["items"] if i.get("failed")]
        self.assertEqual([(i["session_id"], i["summary"]) for i in failed], [("s2", "")], "the day says so")

    def test_unreadable_transcript_counted_as_failed(self):
        self.add_session("gone", entries=[])
        (self.home / "t-gone.json").unlink()
        up.main(["run"])
        items = [i for b in self.hub.posted("/api/updates/summaries") for i in b["items"]]
        self.assertEqual([(i["session_id"], i.get("failed")) for i in items], [("gone", True)])
        self.assertEqual(len(self.hub.posted("/api/updates/reports")), 1)

    def test_lock_held_exits_without_hub(self):
        os.makedirs(self.home / "state", exist_ok=True)
        import fcntl
        with open(self.home / "state" / "lock", "w") as held:
            fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.assertEqual(up.main(["run"]), 0)
        self.assertEqual(self.hub.requests, [])


def git(repo, *args, env=None):
    import subprocess
    full = dict(os.environ, GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_NOSYSTEM="1", **(env or {}))
    return subprocess.run(["git", "-C", str(repo)] + list(args), check=True, capture_output=True, text=True, env=full).stdout


def commit(repo, subject, email, when):
    env = {"GIT_AUTHOR_EMAIL": email, "GIT_AUTHOR_NAME": "A", "GIT_COMMITTER_EMAIL": email, "GIT_COMMITTER_NAME": "A",
           "GIT_AUTHOR_DATE": when, "GIT_COMMITTER_DATE": when}
    git(repo, "commit", "--allow-empty", "-q", "-m", subject, env=env)


class CommitTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def repo(self, path):
        path.mkdir(parents=True)
        git(path, "init", "-q", "-b", "main")
        git(path, "config", "user.email", "me@x")
        return path

    def test_user_commits_mine_and_scheduled_in_window(self):
        r = self.repo(self.root / "r")
        commit(r, "before", "me@x", "2026-11-02T05:00:00Z")
        commit(r, "mine", "me@x", "2026-11-02T09:00:00Z")
        commit(r, "theirs", "other@x", "2026-11-02T10:00:00Z")
        git(r, "checkout", "-q", "-b", "scheduled/a")
        commit(r, "scheduled run", "bot@x", "2026-11-02T11:00:00Z")
        git(r, "checkout", "-q", "main")
        start, end = up.day_window(DAY)
        self.assertEqual(sorted(c["subject"] for c in up.user_commits(str(r), start, end)), ["mine", "scheduled run"])

    def test_plus_address_matches_exactly(self):
        r = self.repo(self.root / "r")
        git(r, "config", "user.email", "me+work@x.io")
        commit(r, "mine", "me+work@x.io", "2026-11-02T09:00:00Z")
        commit(r, "lookalike", "mexwork@x.io", "2026-11-02T10:00:00Z")
        start, end = up.day_window(DAY)
        self.assertEqual([c["subject"] for c in up.user_commits(str(r), start, end)], ["mine"])

    def test_cherry_pick_counted_once(self):
        r = self.repo(self.root / "r")
        commit(r, "base", "me@x", "2026-11-01T09:00:00Z")
        git(r, "checkout", "-q", "-b", "other")
        commit(r, "fix", "me@x", "2026-11-02T09:00:00Z")
        sha = git(r, "rev-parse", "HEAD").strip()
        git(r, "checkout", "-q", "main")
        git(r, "cherry-pick", "--allow-empty", sha, env={"GIT_COMMITTER_EMAIL": "me@x", "GIT_COMMITTER_NAME": "A",
                                         "GIT_COMMITTER_DATE": "2026-11-02T12:00:00Z"})
        start, end = up.day_window(DAY)
        self.assertEqual([c["subject"] for c in up.user_commits(str(r), start, end)], ["fix"])

    def test_repos_in_nested(self):
        self.repo(self.root / "a")
        self.repo(self.root / "b" / "c")
        (self.root / "node_modules" / "x" / ".git").mkdir(parents=True)
        (self.root / ".hidden" / ".git").mkdir(parents=True)
        self.assertEqual(sorted(os.path.relpath(p, self.root) for p in up.repos_in(str(self.root))), ["a", os.path.join("b", "c")])
        single = self.repo(self.root / "single")
        self.assertEqual(up.repos_in(str(single)), [str(single)])

    def test_unknown_keys(self):
        text = "- **[EIN-1](https://j/browse/EIN-1)** done\n- [XYZ-9](https://j/browse/XYZ-9) made up"
        self.assertEqual(up.unknown_keys(text, ["EIN-1 summary"]), {"XYZ-9"})

    def test_delink(self):
        text = "[XYZ-9](https://j/browse/XYZ-9) and [EIN-1](https://j/browse/EIN-1)"
        self.assertEqual(up.delink(text, {"XYZ-9"}), "XYZ-9 and [EIN-1](https://j/browse/EIN-1)")


class WriteRunTests(Base):
    def write_item(self, **kw):
        item = {"project_id": "pa", "project_name": "a", "folder": str(self.home / "nope"), "day": DAY,
                "style": "Group by Jira: [KEY](https://solveit.atlassian.net/browse/KEY)",
                "summaries": [], "completed_todos": [], "todo_titles": [], "generation": 7}
        item.update(kw)
        self.hub.work["days"] = []
        self.hub.work["write"] = [item]

    def test_empty_day_puts_empty_without_model(self):
        self.write_item()
        up.main(["run"])
        self.assertEqual(self.model_calls(), [])
        self.assertEqual(self.hub.posted("/api/projects/pa/updates/%s" % DAY), [{"text": "", "commits": 0, "generation": 7}])

    def test_writes_markdown_from_summaries(self):
        self.write_item(summaries=[{"title": "T", "summary": "Fixed EIN-1.", "jira_keys": ["EIN-1"], "computer": "mac"}])
        self.answer({"text": "- **[EIN-1](https://solveit.atlassian.net/browse/EIN-1)** fixed"})
        up.main(["run"])
        put = self.hub.posted("/api/projects/pa/updates/%s" % DAY)
        self.assertEqual(put, [{"text": "- **[EIN-1](https://solveit.atlassian.net/browse/EIN-1)** fixed", "commits": 0,
                                "generation": 7}])
        self.assertIn("Fixed EIN-1.", self.model_log.read_text())
        self.assertIn("Group by Jira", self.model_log.read_text())

    def test_made_up_key_retried_then_delinked(self):
        self.write_item(summaries=[{"title": "T", "summary": "Fixed EIN-1.", "jira_keys": ["EIN-1"], "computer": "mac"}])
        bad = {"text": "[XYZ-9](https://solveit.atlassian.net/browse/XYZ-9) fixed"}
        self.answer(bad, bad)
        up.main(["run"])
        self.assertEqual(len(self.model_calls()), 2)
        text = self.hub.posted("/api/projects/pa/updates/%s" % DAY)[0]["text"]
        self.assertIn("XYZ-9", text)
        self.assertNotIn("browse/XYZ-9", text)

    def test_commits_counted_and_passed(self):
        repo = self.home / "proj"
        repo.mkdir()
        git(repo, "init", "-q", "-b", "main")
        git(repo, "config", "user.email", "me@x")
        commit(repo, "CH-12 add export", "me@x", "2026-11-02T09:00:00Z")
        self.write_item(folder=str(repo))
        self.answer({"text": "- [CH-12](https://jira.digital.ingka.com/browse/CH-12) export"})
        up.main(["run"])
        put = self.hub.posted("/api/projects/pa/updates/%s" % DAY)[0]
        self.assertEqual(put["commits"], 1)
        self.assertIn("browse/CH-12", put["text"])
        self.assertIn("CH-12 add export", self.model_log.read_text())

    def test_tilde_folder(self):
        repo = self.home / "w" / "a"
        repo.mkdir(parents=True)
        git(repo, "init", "-q", "-b", "main")
        git(repo, "config", "user.email", "me@x")
        commit(repo, "x", "me@x", "2026-11-02T09:00:00Z")
        self.write_item(folder="~/w/a")
        self.answer({"text": "x"})
        up.main(["run"])
        self.assertEqual(self.hub.posted("/api/projects/pa/updates/%s" % DAY)[0]["commits"], 1)

    def test_key_made_up_in_summary_prose_is_delinked(self):
        self.write_item(summaries=[{"title": "T", "summary": "Fixed XYZ-9 (invented).", "jira_keys": [], "computer": "mac"}])
        bad = {"text": "[XYZ-9](https://solveit.atlassian.net/browse/XYZ-9) fixed"}
        self.answer(bad, bad)
        up.main(["run"])
        text = self.hub.posted("/api/projects/pa/updates/%s" % DAY)[0]["text"]
        self.assertNotIn("browse/XYZ-9", text)

    def test_failing_write_counted_and_others_continue(self):
        summary = [{"title": "T", "summary": "S", "jira_keys": [], "computer": "mac"}]
        self.write_item(summaries=summary)
        second = dict(self.hub.work["write"][0], project_id="pb")
        self.hub.work["write"].append(second)
        for run in range(3):
            self.answer("FAIL", {"text": "b ok"})
            up.main(["run"])
        a = self.hub.posted("/api/projects/pa/updates/%s" % DAY)
        b = self.hub.posted("/api/projects/pb/updates/%s" % DAY)
        self.assertEqual(len(b), 3, "the second item is written every run")
        self.assertEqual(len(a), 1, "the first gets a note after 3 failures")
        self.assertIn("couldn't be written", a[0]["text"])

    def test_long_text_cut_to_hub_limit(self):
        self.write_item(summaries=[{"title": "T", "summary": "S", "jira_keys": [], "computer": "mac"}])
        self.answer({"text": "y" * 25000})
        up.main(["run"])
        self.assertEqual(len(self.hub.posted("/api/projects/pa/updates/%s" % DAY)[0]["text"]), 20000)


WEEK = "2026-11-02"


class WeeklyRunTests(Base):
    def weekly_item(self, **kw):
        item = {"project_id": "pa", "project_name": "a", "week": WEEK,
                "style": "Jira site: https://solveit.atlassian.net",
                "days": [{"day": "2026-11-02", "state": "update", "text": "- Fixed EIN-1 export", "summaries": []},
                         {"day": "2026-11-03", "state": "quiet", "text": "", "summaries": []},
                         {"day": "2026-11-04", "state": "missing", "text": "",
                          "summaries": [{"title": "Spike", "summary": "Tried the importer."}]},
                         {"day": "2026-11-05", "state": "untracked", "text": "", "summaries": []}]}
        item.update(kw)
        self.hub.work["days"] = []
        self.hub.work["weekly"] = [item]
        return item

    def put_path(self):
        return "/api/projects/pa/weekly/%s" % WEEK

    def test_weekly_written_and_put(self):
        self.weekly_item()
        self.answer({"headline": "Export shipped", "wins": "- You fixed the export"})
        up.main(["run"])
        self.assertEqual(self.hub.posted(self.put_path()),
                         [{"headline": "Export shipped", "wins": "- You fixed the export", "failed": False}])
        self.assertIn("Fixed EIN-1 export", self.model_log.read_text())

    def test_weekly_message_skips_quiet_and_untracked_and_uses_summaries_for_missing(self):
        msg = up.weekly_message(self.weekly_item())
        self.assertIn("<<<MATERIAL", msg)
        self.assertIn("MATERIAL>>>", msg)
        self.assertIn("## 2026-11-02 (update)\n- Fixed EIN-1 export", msg)
        self.assertIn("## 2026-11-04 (no update; conversation summaries)", msg)
        self.assertIn("Tried the importer.", msg)
        self.assertNotIn("2026-11-03", msg)
        self.assertNotIn("2026-11-05", msg)
        empty = up.weekly_message(self.weekly_item(days=[{"day": "2026-11-06", "state": "failed", "text": "", "summaries": []}]))
        self.assertNotIn("2026-11-06", empty)

    def test_weekly_empty_wins_counted_as_failure(self):
        self.weekly_item()
        for run in range(3):
            self.answer({"headline": "h", "wins": "  "})
            up.main(["run"])
        self.assertEqual(self.hub.posted(self.put_path()), [{"headline": "", "wins": "", "failed": True}])

    def test_weekly_waits_without_headroom(self):
        script(self.home / "bin" / "limits", "echo '{\"windows\":[{\"kind\":\"weekly\",\"used_percent\":99}]}'\n")
        self.weekly_item()
        up.main(["run"])
        self.assertEqual(self.model_calls(), [])
        self.assertEqual(self.hub.posted(self.put_path()), [])

    def test_weekly_fails_after_three(self):
        self.weekly_item()
        for run in range(3):
            self.answer("FAIL")
            up.main(["run"])
        puts = self.hub.posted(self.put_path())
        self.assertEqual(puts, [{"headline": "", "wins": "", "failed": True}])

    def test_weekly_unknown_jira_key_delinked(self):
        self.weekly_item()
        bad = {"headline": "h", "wins": "- [XYZ-9](https://solveit.atlassian.net/browse/XYZ-9) and "
                                        "[EIN-1](https://solveit.atlassian.net/browse/EIN-1)"}
        self.answer(bad, bad)
        up.main(["run"])
        wins = self.hub.posted(self.put_path())[0]["wins"]
        self.assertNotIn("browse/XYZ-9", wins)
        self.assertIn("browse/EIN-1", wins)

    def test_weekly_headline_cut_to_120(self):
        self.weekly_item()
        self.answer({"headline": "h" * 200, "wins": "- w"})
        up.main(["run"])
        self.assertEqual(len(self.hub.posted(self.put_path())[0]["headline"]), 120)

    def test_runner_without_weekly_key_still_works(self):
        self.hub.work["days"] = []
        self.hub.work.pop("weekly", None)
        self.assertEqual(up.main(["run"]), 0)
        self.assertIsNone(json.loads((self.home / "state" / "status.json").read_text())["last_error"])


if __name__ == "__main__":
    unittest.main(verbosity=1)
