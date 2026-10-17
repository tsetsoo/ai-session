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
        for key in ("project_id", "tool", "session_id", "todo_id"):
            if q(key) is not None:
                ms = [m for m in ms if m.get(key) == q(key)]
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

    def log_message(self, *args):
        pass


server = HTTPServer(("127.0.0.1", 0), Hub)
with open(PORT_FILE, "w") as f:
    f.write(str(server.server_port))
server.serve_forever()
