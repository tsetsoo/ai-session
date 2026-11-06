"""Conversation worktrees: make one, bring the project's local files into it, keep copies
current, and sweep the ones that hold nothing. Used by ai-todo-runner (scheduled runs) and
ai-todo-workspace (list, sync, and ensure: a conversation's own worktree, made on its first
open by ai-todo-open --worktree).

Local files. A worktree has only what git tracks, so a project's gitignored files (.env,
an excluded CLAUDE.md, local notes) are missing from it. Two files at the top of the project
folder's repo name them, in .gitignore syntax (they may themselves be ignored, e.g. listed
in .git/info/exclude, so a shared repo needs no commit):
  .worktreeinclude  copied (the convention of Claude Code and PostHog Code). A conversation
                    may edit its copy without touching the project folder or other worktrees.
  .worktreelink     symlinked to the project folder's file or directory: for things that are
                    only read or are large (CLAUDE.md, CLAUDE.local.md, local/, .venv).
                    A directory ignored only as `dir/` becomes a real directory of symlinks
                    to its entries (git would list a symlink there as untracked).
A path is brought over only when git ignores it both in the project folder and in the new
worktree (whose .gitignore comes from the base commit and may differ): a pattern never
duplicates a tracked file, picks up uncommitted source, or leaves a secret committable. A
path the worktree already has is left alone; one that can't be read is skipped.
Copies are recorded with their source's hash; sync() re-copies a file whose source changed
while the worktree's copy was not edited, and reports one where both changed.

Sweep. A worktree older than the cleanup age (a conversation's: since it was last opened) is removed when it is clean and either has no
commits past its base or its work is already in origin/HEAD (merging it would change nothing:
a fast-forward, rebase or squash merge all count). Clean means: no uncommitted changes, still
on its own branch, no copied local file edited, and no tmux pane working inside it. Anything
else is kept. The merged check fetches each repo at most once per sweep and reruns at most
hourly per worktree. The registry is read and written under a lock.
"""

import contextlib
import fcntl
import hashlib
import json
import os
import shutil
import subprocess
import tempfile
import time

INCLUDE_FILE = ".worktreeinclude"
LINK_FILE = ".worktreelink"
COPY_MAX_FILES = 2000
COPY_MAX_BYTES = 100 << 20
MERGED_RECHECK = 3600
FETCH_TIMEOUT = 15


class NotARepo(Exception):
    pass


def git(folder, *args, timeout=60):
    try:
        p = subprocess.run(["git", "-C", folder] + list(args), capture_output=True, text=True,
                           timeout=timeout, stdin=subprocess.DEVNULL)
        return p.returncode, p.stdout.strip(), p.stderr.strip()
    except (OSError, subprocess.TimeoutExpired) as e:
        return 1, "", type(e).__name__


# --- Registry ------------------------------------------------------------------------

def load_registry(path):
    try:
        with open(path) as f:
            value = json.load(f)
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError):
        return {}


def save_registry(path, registry):
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".registry.")
    with os.fdopen(fd, "w") as f:
        json.dump(registry, f)
    os.replace(tmp, path)


@contextlib.contextmanager
def locked_registry(path):
    """The registry, locked against other writers; saved on exit when the body didn't raise."""
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    with open(path + ".lock", "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        registry = load_registry(path)
        yield registry
        save_registry(path, registry)


# --- Create --------------------------------------------------------------------------

def sha256(path):
    h = hashlib.sha256()
    try:
        with open(path, "rb") as f:
            for chunk in iter(lambda: f.read(1 << 16), b""):
                h.update(chunk)
    except OSError:
        return None
    return h.hexdigest()


def create(folder, path, branch):
    """Make a worktree of `folder`'s repo at `path` on a new `branch` from origin/HEAD (else
    HEAD), with the repo's local files brought in. Returns (cwd, entry): cwd is `folder`'s place
    inside the worktree (a monorepo subfolder opens there, or at the root when the base commit
    lacks it); entry is the registry record. Raises NotARepo for a folder outside git and
    RuntimeError when git can't make the worktree."""
    code, top, _ = git(folder, "rev-parse", "--show-toplevel")
    if code != 0:
        raise NotARepo(folder)
    code, prefix, _ = git(folder, "rev-parse", "--show-prefix")
    prefix = prefix.strip().strip("/") if code == 0 else ""
    if git(folder, "remote", "get-url", "origin")[0] == 0:
        git(folder, "fetch", "--quiet", "origin", timeout=30)
    base = "origin/HEAD" if git(folder, "rev-parse", "--verify", "--quiet", "origin/HEAD")[0] == 0 else "HEAD"
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    base_sha = git(folder, "rev-parse", base)[1]
    reused = git(folder, "rev-parse", "--verify", "--quiet", "refs/heads/" + branch)[0] == 0
    if reused:
        # A conversation's worktree made again (swept, or deleted by hand): its branch is
        # kept with whatever it has.
        git(folder, "worktree", "prune")
        code, _, err = git(folder, "worktree", "add", path, branch)
    else:
        code, _, err = git(folder, "worktree", "add", "-b", branch, path, base)
    if code != 0:
        raise RuntimeError("git worktree add failed: %s" % err[:200])
    entry = {"path": path, "folder": folder, "top": top, "branch": branch, "base": base_sha,
             "created": time.time()}
    try:
        entry.update(bring_local_files(top, path))
    except Exception:
        undo_create(entry, reused)
        raise
    entry["reused_branch"] = reused
    cwd = os.path.join(path, prefix) if prefix and os.path.isdir(os.path.join(path, prefix)) else path
    return cwd, entry


def _ignored(folder, paths):
    """The subset of `paths` git ignores in `folder`."""
    if not paths:
        return set()
    try:
        p = subprocess.run(["git", "-C", folder, "check-ignore", "--stdin", "-z"], input="\0".join(paths) + "\0",
                           capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.TimeoutExpired):
        return set()
    return set(x for x in p.stdout.split("\0") if x)


def _matches(top, patterns_file, directories):
    """Untracked paths under `top` matching `patterns_file` that git also ignores there, or
    None when git couldn't list them."""
    if not os.path.isfile(patterns_file):
        return []
    args = ["ls-files", "--others", "--ignored", "-z", "--exclude-from=" + patterns_file]
    if directories:
        args.append("--directory")
    code, out, _ = git(top, *args, timeout=60)
    if code != 0:
        return None
    candidates = [p for p in out.split("\0") if p and not p.startswith(".git/")]
    ignored = _ignored(top, candidates)
    return [c for c in candidates if c in ignored]


def _place(dst, make):
    """Run make(); a failure leaves nothing at dst. True when it worked."""
    try:
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        make()
        return True
    except OSError:
        if os.path.islink(dst) or os.path.isfile(dst):
            os.remove(dst)
        elif os.path.isdir(dst):
            shutil.rmtree(dst, ignore_errors=True)
        return False


def bring_local_files(top, path):
    """Copy .worktreeinclude matches and symlink .worktreelink matches from `top` into `path`.
    Returns {"copied": {rel: source sha256}, "linked": [rel], "skipped": [rel]}."""
    copied, linked, skipped = {}, [], []
    total = 0
    include = _matches(top, os.path.join(top, INCLUDE_FILE), directories=False)
    link = _matches(top, os.path.join(top, LINK_FILE), directories=True)
    if include is None:
        skipped.append(INCLUDE_FILE)
    if link is None:
        skipped.append(LINK_FILE)
    include = [r for r in include or [] if os.path.isfile(os.path.join(top, r)) and not os.path.islink(os.path.join(top, r))]
    link = [r.rstrip("/") for r in link or []]
    # Ignored in the worktree too: its .gitignore is the base commit's, not the live folder's.
    # A directory is asked about as `dir/` (it doesn't exist there yet, and `dir/` patterns
    # match only directories).
    asked = {r + "/" if os.path.isdir(os.path.join(top, r)) else r: r for r in include + link}
    safe = set(asked[a] for a in _ignored(path, list(asked)) if a in asked)
    for rel in include:
        src, dst = os.path.join(top, rel), os.path.join(path, rel)
        if os.path.lexists(dst):
            continue
        size = os.path.getsize(src)
        if rel not in safe or len(copied) >= COPY_MAX_FILES or total + size > COPY_MAX_BYTES:
            skipped.append(rel)
            continue
        digest = sha256(src)
        if digest is None or not _place(dst, lambda: shutil.copy2(src, dst)):
            skipped.append(rel)
            continue
        copied[rel] = digest
        total += size
    for rel in link:
        src, dst = os.path.join(top, rel), os.path.join(path, rel)
        if os.path.lexists(dst) or not os.path.lexists(src):
            continue
        if rel not in safe:
            skipped.append(rel)
            continue
        if not _place(dst, lambda: os.symlink(src, dst)):
            skipped.append(rel)
            continue
        # git sees a symlink as a file, so a directory ignored as `dir/` would show up as
        # untracked: make it a real directory of symlinks instead (ignored like the source).
        if os.path.isdir(src) and not _ignored(path, [rel]):
            os.remove(dst)
            if not _place(dst, lambda: _link_entries(src, dst)):
                skipped.append(rel)
                continue
        linked.append(rel)
    return {"copied": copied, "linked": sorted(linked), "skipped": skipped}


def _link_entries(src, dst):
    os.mkdir(dst)
    for name in os.listdir(src):
        os.symlink(os.path.join(src, name), os.path.join(dst, name))


# --- Sync ----------------------------------------------------------------------------

def sync(entry):
    """Re-copy local files whose source changed while the worktree's copy was untouched.
    Updates entry["copied"]; returns (updated, differs): lists of relative paths."""
    updated, differs = [], []
    top, path = entry.get("top") or "", entry.get("path") or ""
    copied = entry.get("copied") or {}
    for rel, recorded in sorted(copied.items()):
        src, dst = os.path.join(top, rel), os.path.join(path, rel)
        now_src = sha256(src)
        if now_src is None or now_src == recorded:
            continue
        now_dst = sha256(dst)
        if now_dst == now_src:
            copied[rel] = now_src  # the same edit on both sides: in step again
            continue
        if now_dst is not None and now_dst != recorded:
            differs.append(rel)
            continue
        if _place(dst, lambda: shutil.copy2(src, dst)):
            copied[rel] = now_src
            updated.append(rel)
    entry["copied"] = copied
    return updated, differs


def undo_create(entry, reused_branch):
    """Remove a worktree create() just made. A branch it did not make (reused) is kept: it may
    hold the conversation's commits."""
    remove(dict(entry, branch=None) if reused_branch else entry)


def _lock_path(path):
    return os.path.join(os.path.dirname(path), "." + os.path.basename(path) + ".lock")


def ensure(registry_path, path, folder, branch, log=lambda msg: None):
    """A conversation's own worktree at `path` (of `folder`'s repo, on `branch`): made and
    registered when missing, its local files synced when present. Safe to call on every open
    and from two devices at once (a lock per path). Returns (made, updated, differs).
    Raises NotARepo or RuntimeError as create() does."""
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    with open(_lock_path(path), "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if os.path.isdir(path):
            with locked_registry(registry_path) as registry:
                entry = next((e for e in registry.values() if e.get("path") == path), None)
                if entry:
                    entry["opened"] = time.time()  # the sweep counts its age from here
                updated, differs = sync(entry) if entry else ([], [])
            return False, updated, differs
        log("Preparing a worktree of %s on branch %s" % (folder, branch))
        _, entry = create(folder, path, branch)
        reused = entry.pop("reused_branch", False)
        entry["opened"] = entry["created"]
        try:
            with locked_registry(registry_path) as registry:
                for key in [k for k, e in registry.items() if e.get("path") == path]:
                    registry.pop(key)
                registry[os.path.basename(path)] = entry
        except Exception:
            undo_create(entry, reused)
            raise
        return True, [], []


# --- Sweep ---------------------------------------------------------------------------

def remove(entry):
    """Remove the worktree and its branch. False (branch kept) when git couldn't remove it."""
    folder = entry.get("folder") or ""
    if git(folder, "worktree", "remove", "--force", entry.get("path") or "")[0] != 0:
        return False
    with contextlib.suppress(OSError):
        os.unlink(_lock_path(entry.get("path") or ""))
    if entry.get("branch"):
        git(folder, "branch", "-D", entry["branch"])
    return True


def merged(path):
    """True when merging HEAD into origin/HEAD would change nothing (its work is already in)."""
    code, target, _ = git(path, "rev-parse", "--verify", "--quiet", "origin/HEAD^{tree}")
    if code != 0:
        return False
    code, out, _ = git(path, "merge-tree", "--write-tree", "origin/HEAD", "HEAD")
    return code == 0 and out.split("\n", 1)[0].strip() == target


def tmux_paths():
    """The current folder of every tmux pane (any server this user runs on the default
    socket, or AI_TODO_TMUX_SOCKET's). Empty when tmux isn't there."""
    socket = os.environ.get("AI_TODO_TMUX_SOCKET")
    argv = ["tmux"] + (["-L", socket] if socket else []) + ["list-panes", "-a", "-F", "#{pane_current_path}"]
    try:
        p = subprocess.run(argv, capture_output=True, text=True, timeout=10, stdin=subprocess.DEVNULL)
    except (OSError, subprocess.TimeoutExpired):
        return []
    return [line for line in p.stdout.splitlines() if line] if p.returncode == 0 else []


def state(entry, panes=None):
    """(kind, commits past base). kind: "missing" | "in use" (a tmux pane works in it) |
    "dirty" (uncommitted changes, an edited local copy, or switched off its branch) |
    "clean" | "ahead"."""
    path = entry.get("path") or ""
    if not os.path.isdir(path):
        return "missing", 0
    real = os.path.realpath(path)
    for pane in panes or []:
        pane = os.path.realpath(pane)
        if pane == real or pane.startswith(real + "/"):
            return "in use", 0
    dirty = git(path, "status", "--porcelain")
    if dirty[0] != 0 or dirty[1]:
        return "dirty", 0
    if entry.get("branch") and git(path, "rev-parse", "--abbrev-ref", "HEAD")[1] != entry["branch"]:
        return "dirty", 0
    for rel, recorded in (entry.get("copied") or {}).items():
        if sha256(os.path.join(path, rel)) not in (recorded, None):
            return "dirty", 0
    if not entry.get("base"):
        return "ahead", 0
    code, out, _ = git(path, "rev-list", "--count", "%s..HEAD" % entry["base"])
    if code != 0:
        return "ahead", 0
    ahead = int(out or 0)
    return ("ahead" if ahead else "clean"), ahead


def _opening(path):
    """True while ensure() holds this worktree's lock (an open is about to start a tool in it)."""
    try:
        with open(_lock_path(path)) as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError:
                return True
            fcntl.flock(lock, fcntl.LOCK_UN)
    except OSError:
        pass
    return False


def _kept(path, keep):
    """True when `path` is, or holds, one of the `keep` paths."""
    real = os.path.realpath(path)
    for k in keep:
        k = os.path.realpath(k)
        if k == real or k.startswith(real + "/"):
            return True
    return False


def sweep(registry_path, older_than, log=lambda *a, **k: None, keep=()):
    """Remove old worktrees that hold nothing or whose work is merged; keep the rest, and
    always keep one that is, or holds, a path in `keep` (an open todo's conversation)."""
    keep = list(keep)
    with locked_registry(registry_path) as registry:
        now = time.time()
        due = []
        for key, entry in list(registry.items()):
            try:
                old = now - max(float(entry.get("created") or now), float(entry.get("opened") or 0)) >= older_than
            except (AttributeError, TypeError, ValueError):
                registry.pop(key)
                continue
            if old and not _kept(entry.get("path") or "", keep):
                due.append(key)
        if not due:
            return
        panes, fetched = tmux_paths(), set()
        for key in due:
            entry = registry[key]
            if _opening(entry.get("path") or ""):
                continue
            kind, _ = state(entry, panes)
            if kind == "missing":
                registry.pop(key)
                continue
            if kind == "ahead":
                if now - float(entry.get("merged_checked") or 0) < MERGED_RECHECK:
                    continue
                folder = entry.get("folder") or ""
                if folder not in fetched:
                    fetched.add(folder)
                    if git(folder, "remote", "get-url", "origin")[0] == 0:
                        git(folder, "fetch", "--quiet", "origin", timeout=FETCH_TIMEOUT)
                entry["merged_checked"] = now
                if not merged(entry["path"]):
                    continue
                kind = "merged"
            if kind in ("clean", "merged"):
                if remove(entry):
                    registry.pop(key)
                    log("cleaned", run=key, reason=kind)
                else:
                    log("clean_failed", run=key)
