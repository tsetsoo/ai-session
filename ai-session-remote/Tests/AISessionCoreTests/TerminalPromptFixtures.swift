// Screens captured with `tmux capture-pane -p` from live sessions on 2026-10-31,
// 100x40 panes: Claude Code 2.1.316 (--permission-mode default) and codex-cli 0.166.0
// (-a on-request -s read-only). Keep them verbatim; add new captures when a tool's layout changes.
enum TerminalPromptFixtures {
    static let claudeBash = #"""

 ▐▛███▛█   Claude Code v2.1.316
▝▜██████▀  Opus 5.5 with medium effort · Claude Team
 ▝▝   ▝▝   /…/91aba451-187d-48a4-bc85-5f12d6e6aeef/scratchpad/promptlab

⚠ Your login expires in 2 days · run /login to renew

❯ Run the shell command touch made-by-test.txt with the Bash tool. Nothing else.

⏺ Creating empty file made-by-test.txt
  ⎿  $ touch made-by-test.txt

────────────────────────────────────────────────────────────────────────────────────────────────────
 Bash command
 Tip: auto mode handles these prompts for you — choose "switch to auto mode" below
 Create empty file made-by-test.txt
╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
 touch made-by-test.txt
╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
 Do you want to proceed?
 ❯ 1. Yes
   2. Yes, and always allow access to /private/tmp/claude-501/-Users-tsvetelinpantev-programming-ai-
      session/91aba451-187d-48a4-bc85-5f12d6e6aeef/scratchpad/promptlab from this project
   3. Yes, and switch to auto mode · auto mode handles these prompts for you
   4. No

 Esc to cancel · Tab to amend
"""#

    static let claudeEdit = #"""

 ▐▛███▛█   Claude Code v2.1.316
▝▜██████▀  Opus 5.5 with medium effort · Claude Team
 ▝▝   ▝▝   /…/91aba451-187d-48a4-bc85-5f12d6e6aeef/scratchpad/promptlab

⚠ Your login expires in 2 days · run /login to renew

❯ Run the shell command touch made-by-test.txt with the Bash tool. Nothing else.

  Ran 1 shell command
  ⎿  Interrupted · What should Claude do instead?

✻ Crunched for 1s · done 10:14 PM

❯ Edit a.txt so it says "hello world" instead of "hi", using the Edit tool. Nothing else.

  Read 1 file

⏺ Update(a.txt)

────────────────────────────────────────────────────────────────────────────────────────────────────
 Edit file
 a.txt
╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
 1 -hi
 1 +hello world
╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
 Do you want to make this edit to a.txt?
 ❯ 1. Yes
   2. Yes, and switch to accept edits (auto-approve file edits and common file commands) for this
      session (shift+tab)
   3. No

 Esc to cancel · Tab to amend
"""#

    static let claudeQuestion = #"""
 ▝▝   ▝▝   /…/91aba451-187d-48a4-bc85-5f12d6e6aeef/scratchpad/promptlab

⚠ Your login expires in 2 days · run /login to renew

❯ Run the shell command touch made-by-test.txt with the Bash tool. Nothing else.

  Ran 1 shell command
  ⎿  Interrupted · What should Claude do instead?

✻ Crunched for 1s · done 10:14 PM

❯ Edit a.txt so it says "hello world" instead of "hi", using the Edit tool. Nothing else.

  Read 1 file

⏺ Update(a.txt)
  ⎿  User rejected update to a.txt
      1 -hi
      1 +hello world

✻ Brewed for 4s · done 10:15 PM

❯ Use the AskUserQuestion tool to ask me which colour I prefer, with options Red, Green and Blue.
  Nothing else.
────────────────────────────────────────────────────────────────────────────────────────────────────
 ☐ Colour

Which colour do you prefer?

❯ 1. Red
     The colour red
  2. Green
     The colour green
  3. Blue
     The colour blue
  4. Type something.
────────────────────────────────────────────────────────────────────────────────────────────────────
  5. Chat about this

Enter to select · ↑/↓ to navigate · Esc to cancel
"""#

    static let claudeIdle = #"""

 ▐▛███▛█   Claude Code v2.1.316
▝▜██████▀  Opus 5.5 with medium effort · Claude Team
 ▝▝   ▝▝   /…/91aba451-187d-48a4-bc85-5f12d6e6aeef/scratchpad/promptlab

⚠ Your login expires in 2 days · run /login to renew

❯ Run the shell command touch made-by-test.txt with the Bash tool. Nothing else.

  Ran 1 shell command
  ⎿  Interrupted · What should Claude do instead?

✻ Crunched for 1s · done 10:14 PM























────────────────────────────────────────────────────────────────────────────────────────────────────
❯
────────────────────────────────────────────────────────────────────────────────────────────────────
  ⏸ manual mode on · ? for shortcuts · ← 2 agents
"""#

    static let claudeNumberedReply = #"""

⏺ Update(a.txt)
  ⎿  User rejected update to a.txt
      1 -hi
      1 +hello world

✻ Brewed for 4s · done 10:15 PM

❯ Use the AskUserQuestion tool to ask me which colour I prefer, with options Red, Green and Blue.
  Nothing else.

⏺ User declined to answer questions
  ⎿  · Which colour do you prefer? (Red / Green / Blue)

✻ Worked for 1s · done 10:16 PM

❯ Ask me the same colour question again with AskUserQuestion.

⏺ User answered Claude's questions:
  ⎿  · Which colour do you prefer? → Purple

⏺ You picked Purple. It wasn't one of the three options, so you must have typed it in yourself.

✻ Baked for 3s · done 10:16 PM

❯ Reply with exactly this numbered list and nothing else, no tools: 1. Apples 2. Bananas 3.
  Cherries — and end with the question: Which one do you want?

⏺ 1. Apples
  2. Bananas
  3. Cherries

  Which one do you want?

✻ Baked for 1s · done 10:16 PM

────────────────────────────────────────────────────────────────────────────────────────────────────
❯
────────────────────────────────────────────────────────────────────────────────────────────────────
  ⏸ manual mode on · ? for shortcuts · ← 2 agents
"""#

    static let claudeTrust = #"""

────────────────────────────────────────────────────────────────────────────────────────────────────
 Accessing workspace:

 /private/tmp/claude-501/-Users-tsvetelinpantev-programming-ai-session/91aba451-187d-48a4-bc85-5f12
 d6e6aeef/scratchpad/promptlab

 Quick safety check: Is this a project you created or one you trust? (Like your own code, a
 well-known open source project, or work from your team). If not, take a moment to review what's in
 this folder first.

 Claude Code'll be able to read, edit, and execute files here.

 Security guide

 ❯ No, exit
   Yes, I trust this folder

 Enter to confirm · Esc to cancel
"""#

    static let codexCommand = #"""

  >_ OpenAI Codex (v0.166.0)
     /private/tmp/claude-501/-Users-tsvetelinpantev-programming-ai-session/…/scratchpad/promptlab


› Run the shell command: touch codex-made.txt (it needs write access, request approval). Nothing
  else.


• I’ll request write approval for that command.

• Running touch codex-made.txt














  Would you like to run the following command?

  Environment: local

  Reason: Allow creating codex-made.txt in the current directory?

  $ touch codex-made.txt


› 1. Yes, proceed (y)
  2. Yes, and don't ask again for commands that start with `touch codex-made.txt` (p)
  3. No, and tell Codex what to do differently (esc)

  Press enter to confirm or esc to cancel
"""#

    static let codexPatch = #"""


• I’ll request write approval for that command.

✗ You canceled the request to run touch codex-made.txt

• Exited (status 1) touch codex-made.txt
  └ (no output)

■ Conversation interrupted - use /feedback if something went wrong


› Edit a.txt so it says hello world, using apply_patch (request approval). Nothing else.


• I’ll check a.txt, then request approval to update it with apply_patch.

• Explored
  └ Read a.txt
    + Show details

• Edited a.txt (+1 -1)
    1 -hi
    1 +hello world
    + Show details


  Would you like to make the following edits?

  Description: Apply proposed file edits
  Destination:
  /private/tmp/claude-501/-Users-tsvetelinpantev-programming-ai-session/91aba451-187d-48a4-bc85-5f
  12d6e6aeef/scratchpad/promptlab/a.txt


› 1. Yes, proceed (y)
  2. Yes, and don't ask again for these files (a)
  3. No, and tell Codex what to do differently (esc)

  Press enter to confirm or esc to cancel
"""#

    static let codexIdle = #"""

  >_ OpenAI Codex (v0.166.0)
     /private/tmp/claude-501/-Users-tsvetelinpantev-programming-ai-session/…/scratchpad/promptlab


› Run the shell command: touch codex-made.txt (it needs write access, request approval). Nothing
  else.


• I’ll request write approval for that command.

✗ You canceled the request to run touch codex-made.txt

• Exited (status 1) touch codex-made.txt
  └ (no output)

■ Conversation interrupted - use /feedback if something went wrong



















› Ask Codex to do anything

  GPT-6.1-Sol high · /private/tmp/claude-501/-Users-tsvetelinpantev-programming-ai-session/91aba451…
  ← for agents · ? for shortcuts                                          ⚠ 2 warnings · f2 to view
"""#

    static let codexTrust = #"""

  Folder access
  /private/tmp/claude-501/-Users-tsvetelinpantev-programming-ai-session/91aba451-187d-48a4-bc85-5f
  12d6e6aeef/scratchpad/promptlab

  Trust this folder? Codex can read, edit, and run files here, subject to your permission
  settings. Folder settings can run code automatically, even without a model request. Continue
  only if you trust these files. Your trust decision will be saved.

› 1. Trust and continue
  2. Back to Agent Command Center

  enter continue · esc back
"""#

    // Claude Code 2.1.318 at the phone's width (58x39 pane), captured 2026-11-05 with
    // `tmux capture-pane -p`. The tip wraps onto a second line here.
    static let claudeBashNarrow = #"""
     Besides the usual env secrets and the hub token, it
     also removes every value from
     ~/.ai-remote/watchers/env (for example the Sentry
     token). Exit codes: 64 for bad arguments, 65 for no
     worktree or config, 1 for a hub error, 90 for missing
     tools.

✻ Sautéed for 1m 33s · done 1:52 PM

❯ Now do the same for every .swift file in
  ai-session-remote/Sources/AISessionCore/TodoHub: one
  Read call per file, a 4-line summary after each,
  nothing changed.

⏺ Listing Swift files in the TodoHub folder
  ⎿  $ ls -1 /Users/tsvetelinpantev/programming/ai-session
     /ai-session-remote/Sources/AISessionCore/TodoHub/ |
     grep '\.swift$'

──────────────────────────────────────────────────────────
 Bash command
 Tip: auto mode handles these prompts for you — choose
 "switch to auto mode" below
 List Swift files in the TodoHub folder
╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
 │ ls -1 /Users/tsvetelinpantev/programming/ai-session/ai
 │ -session-remote/Sources/AISessionCore/TodoHub/ | grep
 │ '\.swift$'
╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
 This command requires approval

 Do you want to proceed?
 ❯ 1. Yes
   2. Yes, and don’t ask again for: grep '\.swift$'
   3. Yes, and switch to auto mode · auto mode handles
      these prompts for you
   4. No

 Esc to cancel · Tab to amend
"""#

    // Claude Code 2.1.318 in an 86x40 pane, captured 2026-11-05: the tip fits on one line
    // and ends 2 columns short of the edge, so it must not take the line under it along.
    static let claudeBashTipAtEdge = #"""

 ▐▛███▛█   Claude Code v2.1.318
▝▜██████▀  Opus 5.5 with medium effort · Claude Team
 ▝▝   ▝▝   /…/cc97db91-a727-483b-ab76-97c84287bc3c/scratchpad/promptlab


❯ Run the shell command touch made-by-test.txt with the Bash tool. Nothing else.

⏺ Creating empty file made-by-test.txt
  ⎿  $ touch made-by-test.txt

──────────────────────────────────────────────────────────────────────────────────────
 Bash command
 Tip: auto mode handles these prompts for you — choose "switch to auto mode" below
 Create empty file made-by-test.txt
╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
 touch made-by-test.txt
╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
 Do you want to proceed?
 ❯ 1. Yes
   2. Yes, and always allow access to /private/tmp/claude-501/-Users-tsvetelinpantev-p
      rogramming-ai-session/cc97db91-a727-483b-ab76-97c84287bc3c/scratchpad/promptlab
      from this project
   3. Yes, and switch to auto mode · auto mode handles these prompts for you
   4. No

 Esc to cancel · Tab to amend
"""#
}
