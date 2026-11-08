# Competing agents: one todo, several conversations

Idea ea6d3c67, "Run competing approaches". Designed with the user on 2026-11-06. The research findings are stored on the idea.

## Why

The user wants to give the same task to more than one agent (Claude, Codex, the same tool with a different model) and see how each one tackles it. For **research**, that means reading each agent's findings and approach side by side, picking the better one, and continuing the implementation in that conversation. For **todos**, it means starting a coding task with several agents at once, each in its own worktree, and comparing the code later.

A todo can already hold several conversations; Duplicate creates them. But the app is built around one conversation at a time, so it is hard to see two of them together. The duplicate hand-off is also weak: the user never sees a summary, and in practice doesn't see the transcript arrive either. This work fixes both on the way.

Prior art: VS Code's "Compare Models". It runs 2–10 models concurrently, each in its own worktree from the committed state, and shows them in a tiled grid, with an optional judge and synthesizer. It has no explicit "pick the winner" step and no failure handling. We want the explicit pick and want to leave out the judge for now.

## Goals

1. A todo with several conversations is easy to use. A switcher shows **one conversation at a time or all of them side by side**. Each conversation has **"Continue with this"**. The others are **closed but can be reopened**, and after that they stay **out of the way** until asked for.
2. **Research now asks which agents to use, every time.** When the user clicks it, Claude and Codex are both selected by default. Scheduled research jobs keep using Claude alone, as today.
3. **A todo or conversation can be started with several agents.** The first message is typed once and sent to all of them, and each agent runs in its own worktree from the same commit.
4. **Duplicate becomes "Add agent"** on a todo, with a working hand-off. **Summary** is the default and is shown for editing before it's sent; **Full conversation** (fork or transcript) is the other choice.
5. **Any number of agents from 1 to 10.** The same tool may appear more than once with different models.

## Non-goals (for now)

- Automatic judging, scoring or synthesis.
- Code comparison of attempts (diff per attempt against the shared base, file × attempt matrix, running the same test command in each). This comes later, in the review workspace (branch `scheduled/research-now-ai-session-20261106-367898dc`, not merged yet). This design must not prevent it: attempts must record their **base commit**.
- Automatic merge, push or PR/MR of the winner.

## Anti-goals

- Several agents editing **the same folder** at once. Each agent in a multi-agent coding start gets its own worktree, or the start is refused.
- Attempts that start from **different commits**. All of a group's worktrees come from one base sha, resolved once.
- A losing conversation that is **destroyed** when the user picks a winner. It must be possible to reopen it.
- A hand-off where the user can't see what was sent.

## Stages (build in this order)

### Stage 0: worktree per conversation, slice 2

Stages 1 and 3 need conversations started from the app to get their own worktree. This is slice 2 of idea 7504e411, "Worktree per coding conversation". Slice 1 is on `main`: `ai_todo_workspace.py`, `.worktreeinclude`/`.worktreelink`, and merged-worktree cleanup.

Slice 2 has no written design yet, so it is designed and built first as part of this work. What the user has already decided for it:
- new conversations open in their own worktree by default in all git projects, and each project can opt out;
- the worktree lives at `~/.ai-remote/worktrees/<project>/<conversation>`;
- the app prepares it before `ai-todo-open`;
- existing conversations stay where they are, because moving one breaks resume.

Branch naming, who creates the worktree on a remote host (over SSH, with a host helper), and the registry are the builder's call. They should follow the runner's existing worktree code.

Throughout this document, "starting with one agent stays as today" means as in that project after slice 2, with or without worktrees.

**Worktree cleanup must know about todos.** The existing sweep, `cleanup_worktrees` in `ai_todo_workspace.py`, removes clean worktrees with no commits after about 3 days, and merged ones. Most closed research attempts have no commits, so the sweep would delete them while their todo is still open and they're meant to be reopenable. Change it as follows *(my call)*:
- The sweep **skips** any worktree whose conversation belongs to a todo that isn't Done. The hub tells hosts which ones those are, for example in the runner's tick answer or through an endpoint the sweep calls.
- When a todo is Done, its conversations' worktrees become eligible and are removed on the next sweep, under the existing dirty/unpushed safeguards.
- Reopening a conversation whose worktree is missing recreates it from its branch when the branch still exists. Otherwise it starts a fresh worktree on the same branch name from origin/HEAD and says so in the terminal. It never falls back to the shared project folder. *(Changed while planning: the shared folder is the anti-goal.)*

### Stage 1: the multi-conversation todo view and "Add agent"

**Switcher (Mac).** When a todo has more than one open conversation, the todo's conversation pane gets a switcher at the top. It has one segment per conversation, labelled with the tool, model and status (✓ done, … working, ! needs you), plus **Side by side**.
- With two conversations, side by side is two columns. With more, it is a grid.
- Every pane is a live terminal you can type into.
- Each pane has a header: tool · model, status, elapsed time, and **Continue with this**.

The user approved this layout from a mockup ("C, with Continue with this").

**iPhone.** The same switcher as tabs, with no side by side, and **Continue with this** under the conversation.

**Continue with this.**
- The chosen conversation becomes the todo's main conversation, and the view returns to a normal single conversation, full width.
- Every other conversation of the todo is **closed**: its tmux session is stopped and the hub status becomes `closed`, but the conversation row, session id, worktree and branch are kept.
- A small note at the edge of the todo ("Codex attempt · closed", or "3 other attempts · closed") reopens them. Reopening resumes the conversation in its worktree via `ai-todo-open` and brings the switcher back.
- Otherwise the closed ones stay hidden until the user asks.

**Cleanup.** Closed attempts' worktrees are kept while the todo is open and removed once it is Done (see stage 0).

**Add agent (replaces Duplicate).** One action on a todo or conversation opens an agent picker (tool + model; see below) and a hand-off choice:
- **Summary** (default): a short summary of the source conversation is made, the same way it is made today (a one-shot `claude -p`), and shown in an editable sheet. "Start" sends the edited text as the new agent's first message.
- **Full conversation**: Claude → Claude forks (`--resume --fork-session`), as today. Anything else sends the transcript, or falls back to Summary when it is over budget.
- **Fresh with the same first message**: used by stage 3. The new agent gets the todo's original first message, not the conversation.

**Where the new agent runs (decided by the user).** In a git project with worktrees on, the new agent always gets **its own worktree**. It never shares the source's folder.
- **Summary** and **Full conversation** start from the **source's current state**: its branch head plus its uncommitted and untracked changes, carried over. One way is a snapshot commit from a temporary index, like `ai-todo-review` does.
- **Fresh** starts from the group's **base sha**, the clean starting commit.

In a project with worktrees off, or a folder that isn't a git repo, Add agent works as Duplicate does today (same folder), and warns that both agents share the folder.

**Hand-off bug (fix first in this stage).** The user reports that after Duplicate they see **no summary and no transcript** in the new conversation. Reproduce and fix this before building on the hand-off. Relevant code: `Sources/AISessionCore/Board/DuplicateHandoff.swift`, `App/AISessionRemote/Views/Frame/DuplicateInMenu.swift`, `DuplicateSummarySheet.swift`, and `TodoHubStore.summarizeConversation`. Earlier fixes are in commits ad2b8f4 and 718ee10 (paste timing). The fix is done when the text visibly arrives in the new agent and the agent replies to it.

### Stage 2: Research now with agents

**Picker.** Research Now (Mac `IdeasPanes.swift`, iPhone equivalent) opens a small sheet every time.
- It lists agent rows: tool (claude | codex | cursor where installed) and model (default or a chosen one). Rows can be added and removed, from 1 to 10.
- Defaults are **Claude and Codex** at their default models. *Auto* is not offered, because it would make the attempt depend on usage headroom.
- The sheet has a **computer** field, defaulting to the project's usual computer. It offers only the tools installed there. Runners report their installed tools to the hub, the way they already report watchers and job templates. The group's runs are pinned to that computer. *(My call.)*
- Scheduled research jobs are unchanged: one Claude run, no sheet.

**Hub.** `POST /api/ideas/{id}/research` takes the list of attempts. It creates one run per attempt, all sharing a new `group_id`, plus **one todo** that will hold all of the group's conversations.
- The idea's single `run_id` and `findings` fields become per-attempt. Each run saves its own findings, and the idea shows them per attempt, labelled with tool · model.
- The idea counts as `researched` when the first attempt saves findings and stays researched. *(My call.)*
- This needs a schema bump. Take the next free version at build time, because other unmerged work may also bump it.

**Runner.** All runs of a group:
- start **on the computer chosen in the sheet**;
- use **one base sha**, resolved once when the first run of the group is claimed and passed to every worktree. Today `make_worktree` resolves `origin/HEAD` per run, so it needs a `base_sha` parameter;
- each get their own worktree and branch, as today;
- each pass the existing usage guard per attempt. Research Now stays "always run".

If one attempt fails to start, the others continue; the failed one shows as failed in the switcher, with **Retry**.

**Prompt.** Every attempt gets byte-identical research instructions. The only thing that differs is the conversation itself, so the comparison is fair. `ai-todo-idea findings` must attribute the findings to the attempt that saved them. How it identifies the attempt (run id in the prompt, or worktree → run) is the builder's call.

**After the pick.** "Continue with this" on a research attempt works as in stage 1, and the user keeps typing in that conversation to implement. The chosen attempt's findings are marked as the idea's chosen findings; the others stay readable.

### Stage 3: start any todo with several agents

*Built 2026-11-08 on branch `competing-agents-stage3`: plan docs/superpowers/plans/2026-11-08-competing-agents-stage3-start-with-agents.md. App-driven start, base from `ai-todo-workspace base`, no schema change.*

- Wherever a todo's conversation is started (Mac and iPhone), the user can pick several agents with the same picker. The first message is typed **once**, in a text box, and sent as each agent's first message.
- Each agent runs in its own worktree (stage 0) from the same base sha.
- **The base is the latest `main` on origin**, as decided by the user: fetch, then use origin's default branch head (`origin/HEAD`), as the runner does. It is resolved once for the group. The user's local branch, unpushed commits and uncommitted changes are not included. The start sheet states the base, for example "from origin/main @ 8f5a29c".
- A multi-agent start in a project whose worktrees are switched off, or a folder that isn't a git repo, is refused with a clear message (see anti-goals).
- With one agent, starting stays exactly as today.
- After the agents run, use the stage 1 switcher and Continue with this. Code comparison comes later in the review workspace.

## Constraints

- Build from current `origin/main`. This spec was written on a scheduled branch that is behind it: `ai_todo_workspace.py` and the merged-worktree cleanup are only on `main`.
- Repo layout and commands are in `AGENTS.md`. Server in `todo-app/crates`, client in `ai-session-remote/Sources/AISessionCore/TodoHub/` and `App/AISessionRemote/Services/TodoHubStore.swift`, host scripts in `ai-session-remote/scripts/todo/`.
- Conversations already support several per todo (`conversations.id`, `label`). Status polling and the Needs you / Ready for review lists must keep working per conversation. The todo's list state should be its most urgent open conversation, as commit e853b7c does for duplicate rows.
- The Mac inspector must not lay out hidden content (see the 2026-11-02 switch stalls). Side by side should mount only the visible terminals.
- Usage: 10 agents can use a lot of quota. The picker shows how many conversations will start. No extra cap beyond 10.
- Isolation note: worktrees separate files, not ports, the hub or the keychain. The research prompt already tells agents not to touch anything outside their worktree.

## Left to the builder

- The exact schema shape: `group_id` on `job_runs` and/or conversations, how per-attempt findings are stored, and how "chosen" is recorded.
- How `ai-todo-idea findings` identifies the attempt.
- Grid sizing for 3–10 panes, and the visual details of the switcher and notes.
- Elapsed-time source (run start → last status change is fine).
- Whether Retry reuses the failed attempt's run or makes a new run in the group.
