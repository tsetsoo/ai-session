"""Conversation worktrees: make one, bring the project's local files into it, keep copies
current, and sweep the ones that hold nothing. Used by ai-todo-runner (scheduled runs) and
ai-todo-workspace (list, sync).

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
Only paths git ignores in the project folder are brought over: a pattern never duplicates a
tracked file or picks up uncommitted source. A path the worktree already has is left alone.
Copies are recorded with their source's hash; sync() re-copies a file whose source changed
while the worktree's copy was not edited, and reports one where both changed.

Sweep. A worktree older than the cleanup age is removed when it is clean (no uncommitted
changes) and either has no commits past its base or its work is already in origin/HEAD
(merging it would change nothing: a fast-forward, rebase or squash merge all count). Anything
else is kept. The merged check fetches each repo at most once per sweep and reruns at most
hourly per worktree.
"""

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


def git(folder, *args, timeout=60):
    try:
        p = subprocess.run(["git", "-C", folder] + list(args), capture_output=True, text=True,
                           timeout=timeout, stdin=subprocess.DEVNULL)
        return p.returncode, p.stdout.strip(), p.stderr.strip()
    except (OSError, subprocess.TimeoutExpired) as e:
        return 1, "", type(e).__name__


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
    lacks it); entry is the registry record. Raises RuntimeError when git can't make it."""
    code, top, _ = git(folder, "rev-parse", "--show-toplevel")
    if code != 0:
        raise RuntimeError("%s is not a git repository" % folder)
    code, prefix, _ = git(folder, "rev-parse", "--show-prefix")
    prefix = prefix.strip().strip("/") if code == 0 else ""
    if git(folder, "remote", "get-url", "origin")[0] == 0:
        git(folder, "fetch", "--quiet", "origin", timeout=30)
    base = "origin/HEAD" if git(folder, "rev-parse", "--verify", "--quiet", "origin/HEAD")[0] == 0 else "HEAD"
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    base_sha = git(folder, "rev-parse", base)[1]
    code, _, err = git(folder, "worktree", "add", "-b", branch, path, base)
    if code != 0:
        raise RuntimeError("git worktree add failed: %s" % err[:200])
    entry = {"path": path, "folder": folder, "top": top, "branch": branch, "base": base_sha,
             "created": time.time()}
    entry.update(bring_local_files(top, path))
    cwd = os.path.join(path, prefix) if prefix and os.path.isdir(os.path.join(path, prefix)) else path
    return cwd, entry


def _matches(top, patterns_file, directories):
    """Untracked paths under `top` matching `patterns_file` that git also ignores there."""
    if not os.path.isfile(patterns_file):
        return []
    args = ["ls-files", "--others", "--ignored", "-z", "--exclude-from=" + patterns_file]
    if directories:
        args.append("--directory")
    code, out, _ = git(top, *args, timeout=60)
    candidates = [p for p in out.split("\0") if p and not p.startswith(".git/")] if code == 0 else []
    if not candidates:
        return []
    try:
        p = subprocess.run(["git", "-C", top, "check-ignore", "--stdin", "-z"], input="\0".join(candidates) + "\0",
                           capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.TimeoutExpired):
        return []
    ignored = set(x for x in p.stdout.split("\0") if x)
    return [c for c in candidates if c in ignored]


def bring_local_files(top, path):
    """Copy .worktreeinclude matches and symlink .worktreelink matches from `top` into `path`.
    Returns {"copied": {rel: source sha256}, "linked": [rel], "skipped": [rel]}."""
    copied, linked, skipped = {}, [], []
    total = 0
    for rel in _matches(top, os.path.join(top, INCLUDE_FILE), directories=False):
        src, dst = os.path.join(top, rel), os.path.join(path, rel)
        if os.path.lexists(dst) or not os.path.isfile(src) or os.path.islink(src):
            continue
        size = os.path.getsize(src)
        if len(copied) >= COPY_MAX_FILES or total + size > COPY_MAX_BYTES:
            skipped.append(rel)
            continue
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copy2(src, dst)
        copied[rel] = sha256(src)
        total += size
    for rel in _matches(top, os.path.join(top, LINK_FILE), directories=True):
        rel = rel.rstrip("/")
        src, dst = os.path.join(top, rel), os.path.join(path, rel)
        if os.path.lexists(dst) or not os.path.lexists(src):
            continue
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        os.symlink(src, dst)
        # git sees a symlink as a file, so a directory ignored as `dir/` would show up as
        # untracked: make it a real directory of symlinks instead (ignored like the source).
        if os.path.isdir(src) and git(path, "check-ignore", "-q", rel)[0] != 0:
            os.remove(dst)
            os.mkdir(dst)
            for name in os.listdir(src):
                os.symlink(os.path.join(src, name), os.path.join(dst, name))
        linked.append(rel)
    return {"copied": copied, "linked": sorted(linked), "skipped": skipped}


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
        if now_dst is not None and now_dst != recorded:
            if now_dst != now_src:
                differs.append(rel)
            continue
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copy2(src, dst)
        copied[rel] = now_src
        updated.append(rel)
    entry["copied"] = copied
    return updated, differs


def remove(entry):
    folder = entry.get("folder") or ""
    git(folder, "worktree", "remove", "--force", entry.get("path") or "")
    if entry.get("branch"):
        git(folder, "branch", "-D", entry["branch"])


def merged(path):
    """True when merging HEAD into origin/HEAD would change nothing (its work is already in)."""
    code, target, _ = git(path, "rev-parse", "--verify", "--quiet", "origin/HEAD^{tree}")
    if code != 0:
        return False
    code, out, _ = git(path, "merge-tree", "--write-tree", "origin/HEAD", "HEAD")
    return code == 0 and out.split("\n", 1)[0].strip() == target


def state(entry):
    """("missing" | "dirty" | "clean" | "ahead", commits past base)."""
    path = entry.get("path") or ""
    if not os.path.isdir(path):
        return "missing", 0
    dirty = git(path, "status", "--porcelain")
    if dirty[0] != 0 or dirty[1]:
        return "dirty", 0
    if not entry.get("base"):
        return "ahead", 0
    code, out, _ = git(path, "rev-list", "--count", "%s..HEAD" % entry["base"])
    if code != 0:
        return "ahead", 0
    ahead = int(out or 0)
    return ("ahead" if ahead else "clean"), ahead


def sweep(registry_path, older_than, log=lambda *a, **k: None):
    """Remove old worktrees that hold nothing or whose work is merged; keep the rest."""
    registry = load_registry(registry_path)
    changed, fetched = False, set()
    now = time.time()
    for key, entry in list(registry.items()):
        if not isinstance(entry, dict) or now - float(entry.get("created") or now) < older_than:
            continue
        kind, _ = state(entry)
        if kind == "missing":
            registry.pop(key)
            changed = True
            continue
        if kind == "ahead":
            if now - float(entry.get("merged_checked") or 0) < MERGED_RECHECK:
                continue
            folder = entry.get("folder") or ""
            if folder not in fetched:
                fetched.add(folder)
                if git(folder, "remote", "get-url", "origin")[0] == 0:
                    git(folder, "fetch", "--quiet", "origin", timeout=30)
            entry["merged_checked"] = now
            changed = True
            if not merged(entry["path"]):
                continue
            kind = "merged"
        if kind in ("clean", "merged"):
            remove(entry)
            registry.pop(key)
            changed = True
            log("cleaned", run=key, reason=kind)
    if changed:
        save_registry(registry_path, registry)
