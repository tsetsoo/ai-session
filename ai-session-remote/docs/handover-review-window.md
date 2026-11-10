# Handover: review window — find and show the conversation's PRs/MRs and branches

Status on 2026-11-10: the installed app was inspected on the real test conversation. It
opens **#1859** after the transcript lookup. Reproduced problems: the initial folder diff
flashes before the lookup completes; unrelated worktree suggestions remain in PR scope;
`main` and Compare With describe the folder beside the PR diff; Switch… renders as an icon.
Two copies of the app were running (the installed app and another worktree's release build),
so inspect `~/Applications/AI Session Remote.app` explicitly when using computer automation.

Follow-up fixes: hide the folder diff until both target lookups finish (including failures),
clear the previous diff when opening a PR, hide worktree suggestions and folder toolbar
controls in PR scope, show Switch… with its title, and remember worktree choices only when
made by the user. Regression checks cover target loading/failure and automatic folder memory.

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
- Expected: the window opens **#1859** (GitHub verified 2026-11-10: 9 files, +336 −217;
  the earlier 5 files, +323 −92 was before subsequent updates), lists 24 PRs under
  "Made by This Conversation", and lists 16 branches without a PR.

History of their complaints, in order:
1. Wrong tree reviewed.
2. "Can't find the right PR or branch."
3. Empty window: a stale host helper on the Spread Mac.
4. 30 PRs filled the sidebar, so the files were off screen, and the empty-state text overlapped them.
5. "Only the relevant PRs" led to the transcript scan.
6. Now: "still a bit buggy".

## How it works now

**Host helper**, `ai-session-remote/scripts/todo/ai-todo-review` (Python, installed to `~/.ai-remote/bin/`):
- `prs <cwd> [--since ISO] [--session claude|codex:<id>]` lists the PRs/MRs the computer's gh/glab
  account opened, the 30 most recently updated.
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
  - **Branches:** must exist locally or on origin, with commits beyond the default branch.
  - **PRs missing from the account's list:** fetched in one GraphQL query (one by one if that
    fails), at most 15.
  - **PR fields:** `mine` (`created`|`changed`|`read`) and `mine_at`. A PR whose head is one of
    the conversation's branches counts as `changed`.
  - **Output:** the PR list, plus `branches` (those with no listed PR) and `transcript` (true/false).
- `fetch-pr <cwd> --number N` fetches `pull/N/head` into `refs/ai-review/pr/N`. The base is the
  merge base; for a merged PR it is the parent of the first commit or GitLab's
  `diff_refs.base_sha`. The diff matched GitHub's file and line counts for 8 real PRs.
- `status`/`diff --ref X` now also accept `origin/<branch>`.

**App:**
- `Sources/AISessionCore/Review/ReviewModels.swift`: `ReviewPullRequestList` (`Item.mine/mineAt/isMine`,
  `Branch`, `branches`, `transcript`) and `target(linkedURL:agentBranches:)`. The runner-linked
  PR comes first, then whatever the conversation made, changed or pushed most recently, then
  the old rule (open PR on the agent's branch).
- `App/AISessionRemote/Views/Review/ReviewSession.swift`:
  - `loadPullRequests` sends `--session`, and retries without it on exit 64 (older helper).
  - `openLikelyPullRequest` runs only after both the PR list and the worktrees have loaded, and
    only until the user picks something (`userChose`).
  - `open(pullRequest:)` shows the PR scope.
  - `open(branch:)`: a branch checked out in a worktree opens that worktree in Branch scope, so
    uncommitted work shows too. Otherwise `reviewedBranch` is set, and the reads use
    `--ref <branch or origin/branch>` from the current folder.
  - `choose(folder:)` is the user's pick; `show(folder:)` is shared with branch opening.
- `App/AISessionRemote/Views/Review/ReviewView.swift`:
  - **Detail pane:** with nothing to show, `PullRequestPicker` lists "What to review?" in groups
    built by `PullRequestGroups.make`: Made by This Conversation, Its Branches Without a Pull
    Request, Read by This Conversation, Your Other Open, Your Other Merged or Closed.
  - **Sidebar:** the open PR or branch (`PullRequestRow` / `BranchRow`), a **Switch…** menu,
    then the files.

## Remaining suspects for "still a bit buggy"

- **Remembered folder:** automatic branch selection no longer saves a folder. Existing saved
  user choices remain. The old remembered value for the test conversation was
  `/private/tmp/ein13910-cross-dataset-deadlocks`.
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
  - `xcodebuild -scheme AISessionRemoteMac -derivedDataPath <scratch>/dd CODE_SIGNING_ALLOWED=NO test` (90)
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
  (delete `~/.ai-remote/review-scan/codex-01a15ed1*` first to force a full rescan).
