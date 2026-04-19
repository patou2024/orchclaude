# orchclaude — Self-Build Prompt

This file is the project spec for `orchclaude buildurself`.
Run it with:

    orchclaude run -f C:\Users\pana5\orchclaude\BUILDSELF.md -t 2h -d C:\Users\pana5\orchclaude

---

## Task

You are building orchclaude — a Windows orchestrator for Claude Code.
The codebase is in the current working directory.
Your job is to implement exactly one feature from the roadmap, test it, and commit it.

## Step 1 — Read the current state

Read STATUS.md. Find the field "Next item to implement". That is your target.
Read nothing else until you have done this.

## Step 2 — Read the full spec for that item

Open ROADMAP.md. Find the section for that item (e.g. "1.1 — External Validation Gate").
Read the entire section including:
- What it is
- Why it matters
- Implementation details
- Acceptance Criteria

Do not skip the acceptance criteria. They define what done means.

## Step 3 — Read the current code

Read orchclaude.ps1 in full. Understand the existing structure before making any changes.
Pay attention to:
- The param() block at the top (all new flags go here)
- The Invoke-Claude function (all Claude calls go through this)
- The Phase 1 build loop
- The Phase 2 QA section

## Step 4 — Implement the feature

Make the changes to orchclaude.ps1 (and any other files needed).
Follow the implementation instructions from ROADMAP.md exactly.
Do not add features beyond what is specified.
Do not refactor unrelated code.

## Step 5 — Test every acceptance criterion

For each acceptance criterion listed in ROADMAP.md for this item:
- Test it manually using PowerShell
- Confirm it works
- If it fails, fix it and test again
- Do not proceed until every criterion passes

For flags: test with a short real prompt like:
  "Create a file called test-output.txt with the word hello inside it"
  -t 5m -d C:\Users\pana5\orchclaude

## Step 6 — Update README and --help

If the feature adds a new flag or command:
- Add it to the flags table in README.md
- Update ORCHCLAUDE-GUIDE.md with the new flag and an example
- The --help output reads from ORCHCLAUDE-GUIDE.md so it updates automatically

Also copy the updated README.md to C:\Users\pana5\ORCHCLAUDE-GUIDE.md so --help stays in sync.

## Step 7 — Update STATUS.md

- Check off the completed item in the relevant phase checklist
- Update "Next item to implement" to the next unchecked item in the current phase
- Update "Last session date" to today's date
- Add a note under "Notes from Last Session" describing what was done and any issues found

## Step 8 — Commit

Run these commands:
  git add -A
  git commit -m "feat: <item number and name>"
  git push origin master:main

Example commit message: feat: 1.1 external validation gate (-test flag)

## Step 9 — Output completion

When all 8 steps are done and the commit is pushed, output:
ORCHESTRATION_COMPLETE

---

## Rules

- Implement exactly one roadmap item per session. Not two, not zero.
- If you hit an error you cannot resolve, document it in STATUS.md under Known Issues and stop.
- Never mark an item complete in STATUS.md unless every acceptance criterion passes.
- Never push broken code. If tests fail, fix them first.
- The goal is slow and correct, not fast and broken.
