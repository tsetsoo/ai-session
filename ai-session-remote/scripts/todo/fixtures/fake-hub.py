#!/usr/bin/env python3
"""Fake todo-server for test-todo-scripts.sh: fake-hub.py STATE_JSON LOG_JSONL PORT_FILE

Every request is appended to LOG_JSONL as {method, path, query, auth, body}. STATE_JSON is
re-read on every request, so tests can change it between runs:

  {"computers": [...], "projects": [...], "memories": [...],
   "fail": {"POST /api/memories/bulk": 500, ...},    # forced error statuses
   "created_at": "2026-10-16T09:00:00Z"}             # created_at for inserted memories

GET /api/computers, /api/projects, /api/memories (filters project_id, tool, session_id, kind,
pinned, include_archived, since, limit) answer from the state. POST /api/memories/bulk inserts
into the state (exact project-wide dedup, supersedes) and answers like todo-server.
POST /api/sessions/stats answers {upserted, sessions}. Paths in folders/cwds expand ~ with $HOME.

Memory upgrade endpoints: GET /api/memories also filters q (any word, substring), global,
computer_id, pending (default false), include_unused and ids. POST /api/memories creates one
(manual or agent, maybe pending). POST /api/memories/uses bumps use_count of known ids and
answers {recorded, unknown, archived: []}. POST /api/memories/import upserts on
(computer_id, source_key). PATCH /api/memories/<id> merges the body into the row.

Scheduler runner: GET /api/runner/due answers {"settings": state["scheduler_settings"] (or the
defaults), "runs": state["due_runs"]}. POST /api/runs/<id>/claim answers 409 when the id is in
state["claimed"] (else adds it and answers the due run). /wait, /finish answer {"ok": true};
/start answers state["start_response"] or a default (todo t-sched, tmux ai/claude/todo-sched1).
Watchers: the due answer carries state["resolves"]; /report and POST /api/watch/... answer
{"ok": true} (the latter with state["watch_status"], default 200).
"""
import json
import os
import re
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlsplit

STATE, LOG, PORT_FILE = sys.argv[1:4]
HOME = os.environ["HOME"]


def load():
    with open(STATE) as f:
        return json.load(f)


def save(state):
    tmp = STATE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(state, f, indent=1)
    os.replace(tmp, STATE)


def text_key(text):
    return " ".join("".join(c if c.isalnum() else " " for c in text.lower()).split())


def expand(path):
    path = path or ""
    if path == "~" or path.startswith("~/"):
        path = HOME + path[1:]
    path = re.sub(r"/+", "/", path)
    return path.rstrip("/") or "/"


def project_for(state, computer_id, cwd):
    cwd, best = expand(cwd), None
    for p in state.get("projects", []):
        if (p.get("computer") or {}).get("id") != computer_id:
            continue
        folder = expand(p["folder"])
        if (cwd == folder or cwd.startswith(folder + "/")) and (best is None or len(folder) > len(expand(best["folder"]))):
            best = p
    return best["id"] if best else None


class Hub(BaseHTTPRequestHandler):
    def reply(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self.handle_request("GET")

    def do_POST(self):
        self.handle_request("POST")

    def do_PATCH(self):
        self.handle_request("PATCH")

    def do_PUT(self):
        self.handle_request("PUT")

    def handle_request(self, method):
        parts = urlsplit(self.path)
        path, query = parts.path, parse_qs(parts.query, keep_blank_values=True)
        raw = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        body = json.loads(raw) if raw else None
        with open(LOG, "a") as f:
            f.write(json.dumps({"method": method, "path": path,
                                "query": {k: v[0] if len(v) == 1 else v for k, v in query.items()},
                                "auth": self.headers.get("Authorization"), "body": body}) + "\n")
        state = load()
        forced = (state.get("fail") or {}).get(method + " " + path)
        if forced:
            return self.reply(forced, {"error": "forced failure"})
        if method == "GET" and path == "/api/computers":
            return self.reply(200, state.get("computers", []))
        if method == "GET" and path == "/api/projects":
            return self.reply(200, state.get("projects", []))
        if method == "GET" and path == "/api/memories":
            return self.reply(200, self.memories(state, query))
        if method == "POST" and path == "/api/memories/bulk":
            return self.bulk(state, body)
        if method == "POST" and path == "/api/memories":
            return self.create(state, body)
        if method == "POST" and path == "/api/memories/uses":
            return self.uses(state, body)
        if method == "POST" and path == "/api/memories/import":
            return self.import_(state, body)
        if method == "GET" and path == "/api/runner/due":
            return self.reply(200, {"settings": state.get("scheduler_settings") or
                                    {"five_hour": 60, "weekly": 80, "pause_waiting": False},
                                    "runs": state.get("due_runs", []),
                                    "resolves": state.get("resolves", [])})
        if method == "PUT" and path.startswith("/api/computers/") and path.endswith("/watchers"):
            return self.reply(state.get("watchers_status", 200), {"ok": True})
        if method == "POST" and path.startswith("/api/watch/"):
            return self.reply(state.get("watch_status", 200), {"ok": True})
        if method == "GET" and path == "/api/ideas":
            ideas = [i for i in state.get("ideas", []) if query.get("project_id", [None])[0] in (None, i["project_id"])]
            return self.reply(200, ideas)
        if method == "POST" and path == "/api/ideas":
            row = dict(body, id="idea-new-%d" % (len(state.get("ideas", [])) + 1), status="new")
            state.setdefault("ideas", []).append(row)
            save(state)
            return self.reply(201, row)
        if method == "PATCH" and path.startswith("/api/ideas/"):
            row = next((i for i in state.get("ideas", []) if i["id"] == path.rsplit("/", 1)[1]), None)
            if row is None:
                return self.reply(404, {"error": "Idea not found"})
            row.update(body or {})
            save(state)
            return self.reply(200, row)
        if method == "PUT" and path.endswith("/conversation/session"):
            return self.reply(200, {"ok": True})
        if method == "POST" and path.startswith("/api/runs/"):
            return self.runs(state, path.split("/")[3], path.split("/")[4], body)
        if method == "PATCH" and path.startswith("/api/memories/"):
            return self.patch(state, path.rsplit("/", 1)[1], body)
        if method == "POST" and path == "/api/sessions/stats":
            sessions = body.get("sessions", [])
            return self.reply(200, {"upserted": len(sessions), "sessions": [
                {"tool": s["tool"], "session_id": s["session_id"],
                 "project_id": project_for(state, body.get("computer_id"), s.get("cwd"))} for s in sessions]})
        return self.reply(404, {"error": "not found"})

    def memories(self, state, query):
        def q(name):
            return query.get(name, [None])[0]

        ms = list(state.get("memories", []))
        if q("ids"):
            wanted = q("ids").split(",")
            return [m for m in ms if m["id"] in wanted]
        for key in ("project_id", "tool", "session_id", "todo_id", "computer_id"):
            if q(key) is not None:
                ms = [m for m in ms if m.get(key) == q(key)]
        if q("global") == "true":
            ms = [m for m in ms if not m.get("project_id") and not m.get("todo_id")
                  and m.get("source") in ("manual", "agent", "claude-memory")]
        ms = [m for m in ms if bool(m.get("pending")) == (q("pending") == "true")]
        if q("q") is not None:
            words = [w for w in re.split(r"[^\w]+", q("q").lower()) if w]
            ms = [m for m in ms if any(w in m["text"].lower() for w in words)]
            if q("include_unused") == "true":
                ms = [m for m in ms if not m.get("archived") or m.get("archived_reason") == "unused"]
                return sorted(ms, key=lambda m: bool(m.get("archived")))[: int(q("limit") or 200)]
        if q("kind"):
            kinds = set(",".join(query["kind"]).split(","))
            ms = [m for m in ms if m["kind"] in kinds]
        if q("pinned") == "true":
            ms = [m for m in ms if m.get("pinned")]
        if q("include_archived") != "true":
            ms = [m for m in ms if not m.get("archived")]
        if q("since"):
            ms = [m for m in ms if m["created_at"] >= q("since")]
        ms.sort(key=lambda m: m["created_at"], reverse=True)
        ms.sort(key=lambda m: not m.get("pinned"))
        return ms[: min(int(q("limit") or 200), 1000)]

    def bulk(self, state, req):
        pid = project_for(state, req["computer_id"], req["cwd"])
        memories = state.setdefault("memories", [])
        known = {text_key(m["text"]) for m in memories if m.get("project_id") == pid and pid}
        known |= {text_key(m["text"]) for m in memories if m.get("session_id") == req["session_id"]}
        inserted, duplicates, archived = [], 0, []
        stamp = state.get("created_at") or time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        for m in req["memories"]:
            if text_key(m["text"]) in known:
                duplicates += 1
                continue
            known.add(text_key(m["text"]))
            state["next_id"] = state.get("next_id", 0) + 1
            row = {"id": "mem-%d" % state["next_id"], "project_id": pid, "todo_id": None,
                   "computer_id": req["computer_id"], "tool": req["tool"], "session_id": req["session_id"],
                   "kind": m["kind"], "text": m["text"], "files": m.get("files", []),
                   "confidence": m.get("confidence"), "source": "extracted", "pinned": False,
                   "archived": False, "created_at": stamp, "updated_at": stamp}
            memories.append(row)
            inserted.append(row)
            for old in memories:
                if old["id"] in (m.get("supersedes") or []) and old.get("project_id") == pid and not old.get("pinned"):
                    old["archived"] = True
                    archived.append(old["id"])
        save(state)
        self.reply(201, {"inserted": inserted, "duplicates": duplicates, "archived": archived,
                         "project_id": pid, "todo_id": None})

    def next_id(self, state):
        state["next_id"] = state.get("next_id", 0) + 1
        return "mem-%d" % state["next_id"]

    def stamp(self, state):
        return state.get("created_at") or time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())

    def create(self, state, req):
        row = {"id": self.next_id(state), "project_id": req.get("project_id"), "todo_id": req.get("todo_id"),
               "computer_id": req.get("computer_id"), "tool": None, "session_id": None, "kind": req["kind"],
               "text": req["text"], "files": req.get("files") or [], "confidence": None,
               "source": req.get("source") or "manual", "pinned": bool(req.get("pinned")), "archived": False,
               "pending": bool(req.get("pending")), "use_count": 0, "last_used_at": None,
               "archived_reason": None, "source_key": None,
               "created_at": self.stamp(state), "updated_at": self.stamp(state)}
        state.setdefault("memories", []).append(row)
        save(state)
        self.reply(201, row)

    def uses(self, state, req):
        ids = {m["id"]: m for m in state.get("memories", [])}
        recorded, unknown = 0, []
        for u in req.get("uses", []):
            m = ids.get(u["id"])
            if m is None:
                unknown.append(u["id"])
                continue
            m["use_count"] = m.get("use_count", 0) + 1
            if m.get("archived_reason") == "unused":
                m["archived"], m["archived_reason"] = False, None
            recorded += 1
        save(state)
        self.reply(200, {"recorded": recorded, "unknown": unknown, "archived": []})

    def import_(self, state, req):
        memories = state.setdefault("memories", [])
        counts = {"inserted": 0, "updated": 0, "unchanged": 0}
        for item in req.get("items", []):
            row = next((m for m in memories if m.get("computer_id") == req["computer_id"]
                        and m.get("source_key") == item["source_key"]), None)
            if row is None:
                memories.append({"id": self.next_id(state), "project_id": item.get("project_id"), "todo_id": None,
                                 "computer_id": req["computer_id"], "tool": None, "session_id": None,
                                 "kind": item["kind"], "text": item["text"], "files": [], "confidence": 1.0,
                                 "source": "claude-memory", "pinned": False, "archived": False, "pending": False,
                                 "use_count": 0, "last_used_at": None, "archived_reason": None,
                                 "source_key": item["source_key"],
                                 "created_at": self.stamp(state), "updated_at": self.stamp(state)})
                counts["inserted"] += 1
            elif row["text"] == item["text"]:
                counts["unchanged"] += 1
            else:
                row.update(text=item["text"], kind=item["kind"], project_id=item.get("project_id"))
                counts["updated"] += 1
        counts["removed"] = 0
        for key in req.get("remove_keys", []):
            for m in memories:
                if m.get("computer_id") == req["computer_id"] and m.get("source_key") == key and not m.get("archived"):
                    m["archived"], m["archived_reason"] = True, "retired"
                    counts["removed"] += 1
        save(state)
        self.reply(200, counts)

    def patch(self, state, mid, req):
        row = next((m for m in state.get("memories", []) if m["id"] == mid), None)
        if row is None:
            return self.reply(404, {"error": "Memory not found"})
        row.update(req or {})
        save(state)
        self.reply(200, row)

    def runs(self, state, rid, verb, body):
        due = next((d for d in state.get("due_runs", []) if d["run"]["id"] == rid), None)
        if verb == "claim":
            claimed = state.setdefault("claimed", [])
            if rid in claimed or due is None:
                return self.reply(409, {"error": "Run is not due"})
            claimed.append(rid)
            save(state)
            return self.reply(200, dict(due, run=dict(due["run"], state="running")))
        if verb == "start":
            tool = (due or {}).get("job", {}).get("action", {}).get("tool", "claude")
            if "start_response" in state:
                return self.reply(200, state["start_response"])
            return self.reply(200, {
                "todo_id": "t-sched", "tmux_name": "ai/%s/todo-sched1" % tool,
                "session_id": "5e55a0de-0000-4000-8000-000000000001" if tool == "claude" else "",
                "tool": tool, "prompt": "PREAMBLE for %s\n\nDo the thing." % body.get("cwd")})
        return self.reply(200, {"ok": True})

    def log_message(self, *args):
        pass


server = HTTPServer(("127.0.0.1", 0), Hub)
with open(PORT_FILE, "w") as f:
    f.write(str(server.server_port))
server.serve_forever()
