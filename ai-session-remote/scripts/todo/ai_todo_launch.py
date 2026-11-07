"""A conversation's launch settings, so starting it again (its tmux session gone, or a
restart onto a new CLI version) keeps them: `ai-todo-status launch save|resume-args`.

`ai-todo-open` saves what it started a conversation with (--model, --auto-approve) and, when
it resumes one, adds `resume-args`. The MCP selection is not here: the app passes it on
every open, from the hub.

What a resume gets comes from the conversation's own transcript first, so a change made in
it (Claude's /model or Shift+Tab mode, Codex's /model) wins over how it was started:

- Claude: the last permission mode when it is auto, acceptEdits, plan or dontAsk (manual /
  default needs no flag; bypassPermissions is never put back without the user asking).
  The model only when one was chosen: started with --model, or changed since the first
  turn. Otherwise the CLI's default applies, so a newer default model is picked up.
- Codex: network access in the workspace sandbox when the last turn had it, and the model
  and reasoning effort under the same rule as Claude's model.
- Cursor: nothing.

Without a transcript entry, the saved settings are used. Nothing here is secret: model
names and flags only.
"""
import json
import os
from pathlib import Path
import re
import time

import ai_todo_status as status

HEADER = "ai-todo-launch v1"
MODEL = re.compile(r"[A-Za-z0-9._:\[\]-]{1,100}")
EFFORT = re.compile(r"[a-z]{1,20}")
SESSION = re.compile(r"[A-Za-z0-9_-]{1,200}")
CLAUDE_MODES = ("auto", "acceptEdits", "plan", "dontAsk")
# Codex's approval reviewer runs as its own model in the same session's turns on some
# versions; it is never the conversation's model.
CODEX_IGNORED_MODELS = {"codex-auto-review"}
KEEP_DAYS = 90


def directory():
    return Path(os.environ.get("AI_TODO_LAUNCH_DIR", str(Path.home() / ".ai-remote" / "launch")))


def record_path(tool, sid):
    if tool not in ("claude", "codex", "cursor") or not SESSION.fullmatch(sid or ""):
        raise ValueError("invalid tool or session id")
    return directory() / ("%s.%s.json" % (tool, sid))


def save(tool, sid, model=None, auto_approve=False, now=None):
    """Record how `ai-todo-open` started the conversation; drop records unused for 90 days."""
    if model is not None and not MODEL.fullmatch(model):
        raise ValueError("invalid model")
    path = record_path(tool, sid)
    now = now or time.time()
    status.atomic_json(path, {"tool": tool, "session_id": sid, "model": model,
                              "auto_approve": bool(auto_approve), "saved_at": int(now),
                              "chrome": load(tool, sid).get("chrome"), "search": load(tool, sid).get("search")})
    for old in path.parent.glob("*.json"):
        try:
            if now - old.stat().st_mtime > KEEP_DAYS * 86400:
                old.unlink()
        except OSError:
            continue


def update(tool, sid, **fields):
    """Change saved settings and keep the rest (a conversation with no record gets one).
    `chrome`: True / False for Claude in Chrome, None to leave it to Claude's own setting.
    `search`: True for Codex's live web search (--search); False / None leave it off."""
    path = record_path(tool, sid)
    record = load(tool, sid) or {"tool": tool, "session_id": sid, "model": None, "auto_approve": False}
    for key, value in fields.items():
        if key in ("chrome", "search") and value not in (True, False, None):
            raise ValueError("invalid %s setting" % key)
        record[key] = value
    record["saved_at"] = int(time.time())
    status.atomic_json(path, record)
    return record


def load(tool, sid):
    try:
        return status.read_json(record_path(tool, sid), {}) or {}
    except ValueError:
        return {}


def lines(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            for line in handle:
                try:
                    value = json.loads(line)
                except ValueError:
                    continue
                if isinstance(value, dict):
                    yield value
    except OSError:
        return


def claude_transcript(sid):
    """The newest copy of the conversation's transcript (one id can sit in several project folders)."""
    home = Path(os.environ.get("CLAUDE_CONFIG_DIR", str(Path.home() / ".claude")))
    copies = [p for p in (home / "projects").glob("*/%s.jsonl" % sid) if p.is_file()]
    return max(copies, key=lambda p: p.stat().st_mtime) if copies else None


def claude_state(sid):
    """{"first_model", "last_model", "mode"} from the transcript; values None when not found."""
    state = {"first_model": None, "last_model": None, "mode": None}
    path = claude_transcript(sid)
    if path is None:
        return state
    for entry in lines(path):
        if entry.get("isSidechain"):
            continue  # a sub-agent's turns, on its own model
        if isinstance(entry.get("permissionMode"), str):
            state["mode"] = entry["permissionMode"]
        message = entry.get("message") if isinstance(entry.get("message"), dict) else {}
        model = entry.get("requestedModel") or message.get("model")
        if isinstance(model, str) and model != "<synthetic>" and entry.get("type") == "assistant":
            state["first_model"] = state["first_model"] or model
            state["last_model"] = model
    return state


def codex_state(sid):
    """{"first", "last": (model, effort), "network": bool} from the rollout's turn contexts."""
    state = {"first": None, "last": None, "network": None}
    sessions = status.codex_home() / "sessions"
    rollouts = sorted(sessions.glob("*/*/*/rollout-*-%s.jsonl" % sid))
    if not rollouts:
        return state
    for entry in lines(rollouts[-1]):
        if entry.get("type") != "turn_context" or not isinstance(entry.get("payload"), dict):
            continue
        payload = entry["payload"]
        model = payload.get("model")
        if isinstance(model, str) and model not in CODEX_IGNORED_MODELS:
            pair = (model, payload.get("effort") if isinstance(payload.get("effort"), str) else None)
            state["first"] = state["first"] or pair
            state["last"] = pair
        sandbox = payload.get("sandbox_policy")
        if isinstance(sandbox, dict) and sandbox.get("type") == "workspace-write":
            state["network"] = sandbox.get("network_access") is True
    return state


def resume_args(tool, sid):
    """Extra arguments for resuming `sid`, after the tool's own resume arguments."""
    saved = load(tool, sid)
    saved_model = saved.get("model") if isinstance(saved.get("model"), str) and MODEL.fullmatch(saved["model"]) else None
    args = []
    if tool == "claude":
        state = claude_state(sid)
        mode = state["mode"]
        if mode in CLAUDE_MODES:
            args += ["--permission-mode", mode]
        elif mode is None and saved.get("auto_approve"):
            args += ["--permission-mode", "auto"]
        chosen = saved_model or (state["first_model"] and state["first_model"] != state["last_model"])
        model = state["last_model"] or saved_model
        if chosen and model and MODEL.fullmatch(model):
            args += ["--model", model]
        # Claude in Chrome, when it was chosen for this conversation (a restart's choice).
        if saved.get("chrome") is True:
            args += ["--chrome"]
        elif saved.get("chrome") is False:
            args += ["--no-chrome"]
    elif tool == "codex":
        state = codex_state(sid)
        if state["network"] or (state["network"] is None and saved.get("auto_approve")):
            args += ["-c", "sandbox_workspace_write.network_access=true"]
        chosen = saved_model or (state["first"] and state["first"] != state["last"])
        model, effort = state["last"] or (saved_model, None)
        if chosen and model and MODEL.fullmatch(model):
            args += ["-m", model]
            if effort and EFFORT.fullmatch(effort):
                args += ["-c", 'model_reasoning_effort="%s"' % effort]
        # Live web search, when it was chosen for this conversation (a restart's choice).
        if saved.get("search") is True:
            args += ["--search"]
    return args


def settings(tool, sid):
    """What a restart would start with, for the app: {"chrome", "search", "model",
    "permission_mode", "network", "args"}. Values are None when not set (the CLI's own default)."""
    args = resume_args(tool, sid)

    def after(flag):
        return args[args.index(flag) + 1] if flag in args[:-1] else None
    return {"chrome": load(tool, sid).get("chrome"), "search": load(tool, sid).get("search"),
            "model": after("--model") or after("-m"),
            "permission_mode": after("--permission-mode"),
            "network": "sandbox_workspace_write.network_access=true" in args, "args": args}


def create_args(tool, sid):
    """Saved settings a start without a transcript still needs: Claude in Chrome. (A restart
    of a conversation with nothing sent yet starts it again with the same id.)"""
    if tool != "claude":
        return []
    chrome = load(tool, sid).get("chrome")
    return ["--chrome"] if chrome is True else ["--no-chrome"] if chrome is False else []


def main(args):
    """`save <tool> <sid> [--model M] [--auto-approve]` | `resume-args|create-args <tool> <sid>` | `show <tool> <sid>`.
    resume-args prints the header line, then one argument per line."""
    if args[:1] == ["save"] and len(args) >= 3:
        model, auto_approve, rest = None, False, args[3:]
        while rest:
            if rest[0] == "--model" and len(rest) >= 2:
                model, rest = rest[1], rest[2:]
            elif rest[0] == "--auto-approve":
                auto_approve, rest = True, rest[1:]
            else:
                return 64
        save(args[1], args[2], model, auto_approve)
        return 0
    if args[:1] == ["show"] and len(args) == 3:
        print(json.dumps(settings(args[1], args[2])))
        return 0
    if args[:1] == ["resume-args"] and len(args) == 3:
        record_path(args[1], args[2])  # validates
        print("\n".join([HEADER] + resume_args(args[1], args[2])))
        return 0
    if args[:1] == ["create-args"] and len(args) == 3:
        record_path(args[1], args[2])
        print("\n".join([HEADER] + create_args(args[1], args[2])))
        return 0
    return 64
