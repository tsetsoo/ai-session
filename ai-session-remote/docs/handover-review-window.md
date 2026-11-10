# Handover: review window — find and show the conversation's PRs/MRs and branches

Status on 2026-11-10 (evening): the user said the PR-first approach still failed to identify
what they changed and asked to base review on the worktree, its branches and PRs. The resolver
now uses the conversation's assigned worktree first. For older conversations on a shared
checkout it uses branches the conversation created/pushed, validated against Git, and the
worktrees checking them out. Repository-wide activity and PR comments do not prove ownership.

A worktree review shows the live snapshot, including unpublished edits and commits. A matching
PR supplies its target branch (including release targets), but never replaces the live
snapshot with the last pushed head. `fetch-pr --live SHA` refreshes the target ref and computes
the merge base with the local snapshot, so unpublished rebases do not include unrelated base
commits. An unchanged merged PR head retains its historical PR base; a moved merged branch
uses the live base and leaves its completed PR snapshot available explicitly. Explicit PR selection still opens the
published PR diff. With no trustworthy target, the window asks for a choice instead of showing
a shared checkout's unrelated changes. Saved folder preferences are no longer restored.

## What the user wants

They open **Conversation ▸ Review Changes…** (⌥⌘R) on a conversation, and the window should
show **exactly the PR/MR or branch that conversation is working on**, with all of its changed
files. It should not show the conversation's folder (often a checkout on `main` with nothing
uncommitted), and not a long list of unrelated PRs.

Their test case: the todo **"Cypher query simplification"** on **spreads-macbook-pro**.
- It is a Codex conversation in `~/Spread/Repository/esf-domain`: hub conversation id
  `e6388597-160c-4ed1-be2f-6efb411ee839`, Codex session `01a15ed1-3d29-7fd1-b72e-efb9f1287608`.
- It has run since 2026-10-22 and opened dozens of PRs, each from a worktree it made itself
  under `/private/tmp/ein…` or `~/.codex/worktrees/…`.
- Latest verified ownership on the evening of 2026-11-10: branch
  `codex/ein-13516-restore-edge-followup`, worktree `/private/tmp/ein13516-restore-edge-followup`,
  PR **#1883** (merged during validation). The previous **#1859** expectation is historical; it must not pin the
  conversation to an older PR as the conversation moves on.
- Other proven worktrees include `codex/ein-14093-single-delete-cleanup` (PR #1878) and
  `codex/ein-13515-bulk-delete` (PR #1876). The helper returned 48 extant owned branches.
- #1859 still has 9 files, +336 −217 as verified earlier that day; it is available explicitly
  in the target switcher, alongside the conversation's other branches and PRs.

History of their complaints, in order:
1. Wrong tree reviewed.
2. "Can't find the right PR or branch."
3. Empty window: a stale host helper on the Spread Mac.
4. 30 PRs filled the sidebar, so the files were off screen, and the empty-state text overlapped them.
5. "Only the relevant PRs" led to the transcript scan.
6. Now: "still a bit buggy".

## How it works now

**Host helper**, `ai-session-remote/scripts/todo/ai-todo-review` (Python, installed to `~/.ai-remote/bin/`):
- `prs <cwd> [--since ISO] [--session claude|codex:<id>]` starts with the account’s 30 most
  recently updated PRs/MRs, then directly looks up the checked-out and proven conversation
  branches across authors and states. GitHub uses a batched GraphQL head-branch query; GitLab
  uses source-branch filtering. The latest 15 proven branches are enriched per request.
- With `--session` it also reads the conversation's transcript (`conversation_work`, class `Work`).
  This is plain text parsing, with no model:
  - **Codex:** `CommandExecution` items, each a command with its output; `McpToolCall` items
    (the GitHub connector, e.g. `github.create_pull_request`); and older `function_call` /
    `function_call_output` pairs.
  - **Claude:** `Bash` tool_use paired with its tool_result; `toolUseResult.gitOperation`
    (`pr` created/edited/merged…, `push.branch`); and `mcp__*` calls.
  - **Commands:** `pr_commands()` tokenizes `gh pr …` / `glab mr …` with shlex. It skips flag
    values and quoted text, and honours `-R`.
  - **Pushed branches:** read from `git push` output (`[new branch] a -> b`, `x..y a -> b`).
  - **New branches:** `git switch -c`, `git checkout -b` and `worktree add -b`.
- The result is cached per transcript in `~/.ai-remote/review-scan/<tool>-<id>.json`, with the
  byte offset reached. Only new lines are read next time, and a version bump (`WORK_VERSION`)
  forces a full rescan.
- `add_work()` filters, enriches and marks the results:
  - **This repository only:** PRs by URL slug against origin. Branches and number-only PRs are
    dropped only when their cwd is provably another repo (`other_repo`).
  - **Branches:** must exist locally or on origin. `work_branches` retains ownership even
    after merge; the older `branches` list contains only branches with changes and no listed PR.
  - **PRs missing from the account's list:** fetched in one GraphQL query (one by one if that
    fails), at most 15.
  - **PR fields:** `mine` (`created`|`changed`|`read`) and `mine_at`. A PR whose head is one of
    the conversation's branches counts as `changed`.
  - **Output:** the PR list, `work_branches` (all extant proven branches, even merged),
    `default_branch`, `branches` (changed branches with no listed PR), and `transcript`.
    Local ownership is still returned if the forge CLI cannot be reached. `repository` and
    each PR’s `head_repository` prevent same-named fork branches being associated with local
    branches. GitHub validates head repository identity; GitLab validates source/target project IDs.
- `fetch-pr <cwd> --number N` fetches `pull/N/head` into `refs/ai-review/pr/N`. The base is the
  merge base; for a merged PR it is the parent of the first commit or GitLab's
  `diff_refs.base_sha`. The diff matched GitHub's file and line counts for 8 real PRs.
- `status`/`diff --ref X` now also accept `origin/<branch>`.

**App:**
- `Sources/AISessionCore/Review/ReviewModels.swift`: `target` and `associatedWorktrees` resolve
  assigned worktree → actual non-default checkout → proven branches/worktrees → explicit PR
  link. Commit/reflog activity ranks only already-owned worktrees. Another conversation’s
  worktree is excluded. Multiple historical PRs without branch evidence require a choice.
- `ReviewSession` waits for PR and worktree reads, resolves once, and respects manual choices.
  It opens an assigned worktree in Conversation scope (recorded base → live snapshot), or an
  agent-created worktree in Branch scope. A branch’s matched PR supplies the base when present;
  the local snapshot supplies the new side. PR scope remains an explicit published snapshot.
  PR state is part of the diff load key so merging a PR reloads its historical comparison.
  Target changes invalidate in-flight diff/PR reads synchronously; reselecting the same checkout
  preserves PR information when its source is unchanged.
  Worktree discovery stays rooted in the conversation when switching among temporary trees;
  PR discovery also queries the currently selected checkout’s head branch.
- `ReviewView` shows the chosen worktree, its branch and matching PR, and offers the other
  proven worktrees in Switch…. An ambiguous target opens the picker even if the original
  shared folder has unrelated dirty files. Other account PRs remain in the explicit switcher.
  Comments on another PR do not put it into the initial conversation-work group.

## Remaining suspects for "still a bit buggy"

- **Remembered folder:** removed from initial resolution. Every new window resolves from the
  conversation’s current identity and Git data; an old preference cannot redirect it.
- **Reloads:** when the folder changes, `pullRequests` is cleared and the list reloads. Look
  for flicker, the picker flashing, or a double load.
- **Branches that do have a PR:** a branch whose PR is older than the 30 listed, and that the
  transcript never mentions as a PR, shows as "without a PR". Matching is only against listed
  heads.
- **PR header in branch scope:** `loadPullRequest` calls `pr --ref origin/<b>` in branch scope.
  Check how `cmd_pr` resolves a branch name from an `origin/` ref (it may look up the wrong head).
- **GitLab with `-R`:** the URL is built as `https://gitlab.com/<repo>/-/merge_requests/N`, which
  is wrong for self-hosted GitLab. Filtering compares paths only, so mostly harmless.
- **Agents not seen:** Codex subagents' own rollouts are not scanned; Claude sidechains are
  included.
- **Toolbar:** PR scope now hides the folder and Compare With menus. Check smaller windows
  for overflow; the status line still competes with the window title for space.
- **"since":** every PR counts as "since the conversation began" for old conversations.
- **Phone:** the ⋯ ▸ Review sheet shows review items only. It has no PRs, branches or diff.

## Other open items

- **Publish / Approve / Merge** to GitHub or GitLab have never been run against a real PR.
  Try them first on a throwaway PR in this repo (`tsetsoo/ai-session`), not a Spread or Sigma one.
- **Kept branches:** a code review finding is still open. When a conversation's worktree is gone
  and its kept branch is reviewed, that branch isn't reset to where the conversation left it.
- **glab and codex:** glab is only on this Mac, so the other two can't read GitLab MRs. codex is
  only on the Spread Mac (`~/.local/bin`), so "Review with Codex" fails elsewhere.
- **install.sh:** it has no guard against an older checkout reinstalling old scripts. The app
  rebuild has one (`~/Applications/.ai-session-remote-commit`). Another session overwrote the
  helper before, which caused complaint 3.

## Rules for shipping (from the original handover and the user's memory)

- **Repos:** work in your own worktree, never in `programming/ai-session`. Never commit, push,
  MR or deploy in other projects such as Sigma.
- **Before pushing:** run the tests, then `/code-review high`, and fix its findings. Then
  rebase onto `origin/main` and run `git push origin HEAD:main`. Commit messages end with
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- **Tests:**
  - `swift test` (580)
  - `xcodebuild -scheme AISessionRemoteMac -derivedDataPath <scratch>/dd CODE_SIGNING_ALLOWED=NO test` (96)
  - `scripts/todo/test-todo-scripts.sh` (308, about 8 min). Timing tests fail when load is
    above about 30: rerun. When running it from a copy, copy `scripts`, `watchers` and `jobs`.
  - Quick check of the review sections only: lines 1–94 of the script, then
    `REVIEW="${SCRIPT_DIR}/ai-todo-review"`, then the `# ai-todo-review prs / fetch-pr` section
    through `pass "review_prs_from_the_conversations_transcript"`, then the last 4 lines.
- **Unsigned Mac test host stuck before tests start:** a process sample showed the main
  thread blocked in `TodoHubSettings.token` / `SecItemCopyMatching`, reading the real hub
  token. Avoid changing Keychain access: run `build-for-testing`, copy the generated
  `Build/Products/*.xctestrun` beside the original, set the test target's `CommandLineArguments`
  to `["-todoHub.baseURL", "disabled://tests"]`, then use `test-without-building -xctestrun`
  on that copy. This overrides the URL only for the test process. An empty string is omitted
  by Xcode and doesn't reliably override the saved URL.
- **Install host scripts from a clean detached worktree of main:**
  - This Mac: `scripts/todo/install.sh`.
  - The other two:
    `tar -czf - scripts/todo watchers jobs | ssh -o IdentitiesOnly=yes -i ~/.ssh/id_ed25519_aisession <host> 'd=$(mktemp -d) && tar -xzf - -C "$d" && "$d/scripts/todo/install.sh"'`
  - Spread Mac: `tsvetelinpantev@100.94.164.63`. Codbex: `tsetso@100.107.204.56`.
  - Verify with e.g. `grep -c "def conversation_work" ~/.ai-remote/bin/ai-todo-review`.
- **Mac app:** `ai-session-remote/scripts/rebuild-mac-app.sh` from that clean worktree (team
  233QTK6KCL). Before asking the user to look, check `~/Applications/.ai-session-remote-commit`:
  other sessions rebuild from old checkouts. Other sessions pushed to main again on 2026-11-10.
- **iPhone:** deploy only when the phone UI changes.
- **Real data:** reproduce on the Spread Mac. Example:
  `cd /private/tmp/ein13910-cross-dataset-deadlocks && ai-todo-review prs . --since 2026-10-22T20:38:40Z --session codex:01a15ed1-3d29-7fd1-b72e-efb9f1287608`
  (a full rescan is only needed when transcript parsing changes; ownership/PR enrichment is live).
