#!/usr/bin/env python3
"""Offline checks of how the sweep reads a conversation worktree's state: a detached HEAD is
only "dirty" while its commits exist nowhere but there."""
import os
import subprocess
import tempfile
import unittest

import ai_todo_workspace as workspace


def git(cwd, *args):
    env = dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@t", GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@t")
    return subprocess.run(["git", "-C", cwd, *args], check=True, capture_output=True, text=True, env=env).stdout.strip()


class DetachedHeadTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = os.path.realpath(self.tmp.name)
        self.origin, self.repo, self.wt = (os.path.join(root, n) for n in ("origin.git", "repo", "wt"))
        subprocess.run(["git", "init", "-q", "--bare", "-b", "main", self.origin], check=True)
        subprocess.run(["git", "init", "-q", "-b", "main", self.repo], check=True)
        git(self.repo, "remote", "add", "origin", self.origin)
        git(self.repo, "commit", "-q", "--allow-empty", "-m", "base")
        git(self.repo, "push", "-q", "origin", "main")
        self.base = git(self.repo, "rev-parse", "HEAD")
        git(self.repo, "worktree", "add", "-q", "-b", "ai/x-1", self.wt, self.base)
        self.entry = {"path": self.wt, "folder": self.repo, "branch": "ai/x-1", "base": self.base}

    def tearDown(self):
        self.tmp.cleanup()

    def commit(self):
        git(self.wt, "commit", "-q", "--allow-empty", "-m", "work")

    def test_on_its_branch_is_clean(self):
        self.assertEqual(workspace.state(self.entry), ("clean", 0))

    def test_detached_with_unpushed_commits_is_dirty(self):
        self.commit()
        git(self.wt, "checkout", "-q", "--detach")
        self.assertEqual(workspace.state(self.entry), ("dirty", 0))

    def test_detached_at_branch_tip_not_pushed_is_dirty(self):
        # branch carries a commit HEAD does not, and nothing is on a remote: keep it
        git(self.wt, "checkout", "-q", "ai/x-1")
        self.commit()
        git(self.wt, "checkout", "-q", "--detach", self.base)
        self.assertEqual(workspace.state(self.entry), ("dirty", 0))

    def test_detached_with_pushed_commits_is_not_dirty(self):
        self.commit()
        git(self.wt, "push", "-q", "origin", "ai/x-1")
        git(self.repo, "fetch", "-q", "origin")
        git(self.wt, "checkout", "-q", "--detach")
        kind, ahead = workspace.state(self.entry)
        self.assertEqual((kind, ahead), ("ahead", 1))

    def test_detached_at_base_is_clean(self):
        git(self.wt, "checkout", "-q", "--detach")
        git(self.wt, "push", "-q", "origin", "HEAD:refs/heads/ai/x-1")
        git(self.repo, "fetch", "-q", "origin")
        self.assertEqual(workspace.state(self.entry), ("clean", 0))

    def test_detached_with_uncommitted_changes_is_dirty(self):
        git(self.wt, "checkout", "-q", "--detach")
        git(self.wt, "push", "-q", "origin", "HEAD:refs/heads/ai/x-1")
        git(self.repo, "fetch", "-q", "origin")
        with open(os.path.join(self.wt, "f.txt"), "w") as f:
            f.write("x")
        self.assertEqual(workspace.state(self.entry), ("dirty", 0))

    def test_another_named_branch_is_dirty(self):
        git(self.wt, "checkout", "-q", "-b", "other")
        self.assertEqual(workspace.state(self.entry), ("dirty", 0))


if __name__ == "__main__":
    unittest.main()
