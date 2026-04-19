# orchclaude — Build Status

This file is updated at the end of every development session.
It is the first thing any new session should read before touching any code.

---

## Current State

**Version:** 0.1.0
**Phase:** 4 — Multi-Agent Execution
**Next item to implement:** Feature Backlog (see ROADMAP.md) — Phase 7 complete
**Last session date:** 2026-04-19 (7.1 audit)
**Windows stable:** yes
**Cross-platform:** no

---

## Completed Items

- [x] Core build loop (prompt -> Claude -> check token -> loop)
- [x] Timeout flag (`-t`)
- [x] Max iterations flag (`-i`)
- [x] Verbose flag (`-v`)
- [x] File prompt flag (`-f`)
- [x] Working directory flag (`-d`)
- [x] QA phase (automatic after build)
- [x] `-noqa` flag to skip QA
- [x] Custom token flag (`-token`)
- [x] `orchclaude --help` outputs full guide
- [x] Progress tracking across iterations (orchclaude-progress.txt)
- [x] Full run logging (orchclaude-log.txt)
- [x] orchclaude.cmd wrapper for terminal use
- [x] README polished for open source release
- [x] Published to GitHub: https://github.com/patou2024/orchclaude

---

## Phase 1 Checklist

- [x] 1.1 — External Validation Gate (`-test` flag)
- [x] 1.2 — Crash Recovery (`orchclaude resume`)
- [x] 1.3 — Rate Limiting and Circuit Breaker
- [x] 1.4 — Token / Cost Estimator
- [x] 1.5 — `--dry-run` flag

---

## Phase 2 Checklist

- [x] 2.1 — Pre-Planning Phase
- [x] 2.2 — Context Window Guard
- [x] 2.3 — Named Profiles

---

## Phase 3 Checklist

- [x] 3.1 — Git Worktree Isolation
- [x] 3.2 — Auto-Commit Checkpoints

---

## Phase 4 Checklist

- [x] 4.1 — Parallel Agents

---

## Phase 5 Checklist

- [x] 5.1 — Linux / macOS Port
- [x] 5.2 — Package Distribution (npm)

---

## Phase 6 Checklist

- [x] 6.1 — Status Dashboard
- [x] 6.2 — Log Viewer

---

## Phase 7 Checklist — Smart Model Mode

- [x] 7.1 — Task Classifier (route iterations to haiku / sonnet / opus automatically)
- [x] 7.2 — Adaptive Escalation (escalate model when no progress detected)
- [x] 7.3 — Cost-Aware Budget Mode (`-budget` flag)
- [x] 7.4 — Model Profile Presets (`-modelprofile fast/balanced/quality/auto`)

---

## Known Issues

- None currently logged.

---

## Notes from Last Session (7.1 audit)

- Audited codebase: 7.1 Task Classifier was already fully implemented as infrastructure for 7.2/7.4.
- `Get-TaskTier` / `get_task_tier` in both PS1 and SH: runs a haiku classifier call on the first 600 chars of the prompt and returns LIGHT / STANDARD / HEAVY.
- `$script:modelMap` / `MODEL_MAP` maps tiers to model IDs (haiku-4-5, sonnet-4-6, opus-4-7).
- `MODEL: <label>` line printed and logged per iteration.
- `-model` flag override fully wired.
- Phase 7 Checklist is now 100% complete.

---

## Notes from Last Session (7.4)

- Implemented 7.4: Model Profile Presets.
- Added `-modelprofile <preset>` flag to both `orchclaude.ps1` and `orchclaude.sh`.
- Four presets:
  - `fast` — sets `$model = "light"` (haiku throughout); bypasses classifier and escalation.
  - `quality` — sets `$model = "heavy"` (opus throughout); bypasses classifier and escalation.
  - `balanced` — runs the 7.1 classifier per iteration but disables 7.2 adaptive escalation (`$noEscalation = $true` / `NO_ESCALATION=true`).
  - `auto` — no-op; uses current default behavior (classifier + escalation).
- Unknown preset values exit with a clear error message.
- `-model` always wins over `-modelprofile` (explicit model ID takes precedence).
- Escalation floor application and escalation firing both gated with `noEscalation` flag.
- Banner updated: "Model : -modelprofile <preset> (<description>)" when a profile is active.
- Help flags line updated to include `-modelprofile`.
- Phase 7 checklist now fully complete.

## Notes from Last Session (7.3)

- Implemented 7.3: Cost-Aware Budget Mode.
- Added `-budget <amount>` flag (e.g. `-budget 0.50`); default 0 = disabled. Applied to both `orchclaude.ps1` and `orchclaude.sh`.
- Added `Get-EstimatedCost` / `get_estimated_cost` helper that returns the running total cost as a number (extracted from the existing cost estimator logic).
- Added `Check-Budget` / `check_budget` function:
  - No-op when `-budget` is 0 or omitted.
  - Computes current estimated cost; if it exceeds the budget threshold, prints a `BUDGET EXCEEDED` warning in Red.
  - Prompts `Continue? (y/n)`.
  - If n: logs the stop reason, writes session as `timeout`, shows cost estimate, cleans up worktree info, exits with code 1.
  - If y: doubles the budget threshold and logs the new value in Yellow.
- `Check-Budget` is called in two places per run: (a) at the end of each build loop iteration that will loop again (before "Token not found. Looping..."), and (b) before the QA phase starts (both in sequential and parallel-agents mode).
- Banner now shows: `Budget: $<amount> limit — pause and confirm if cost exceeds threshold` (or `disabled` when not set).
- Help text updated to include `-budget` in the flags list.

## Notes from Last Session (7.2)

- Implemented 7.2: Adaptive Escalation.
- Added `$escalationFloor` / `ESCALATION_FLOOR` variable (starts empty, ratchets up: "" → "standard" → "heavy").
- Added `$noProgressStreak` / `NO_PROGRESS_STREAK` counter (separate from `$failureStreak`; resets on progress OR on each escalation event so the next tier gets a fresh 2-iteration window).
- Added `$escalatedToStandard` / `$escalatedToHeavy` booleans to ensure each escalation fires exactly once per run (never de-escalates).
- Escalation floor is applied after the 7.1 classifier — if the classifier picks a tier below the floor, the floor wins.
- Escalation fires at `$noProgressStreak -ge 2`:
  - light → standard: prints `ESCALATED: haiku -> sonnet (no progress after 2 iterations)`
  - standard → heavy: prints `ESCALATED: sonnet -> opus (no progress after 2 iterations)`
- Escalation events are written to both terminal (Yellow) and `orchclaude-log.txt`.
- `-model` override bypasses both the classifier and the escalation floor (fixed model throughout).
- Banner line updated: "auto (classifier + adaptive escalation: haiku->sonnet->opus on stall)".
- Changes applied to both `orchclaude.ps1` and `orchclaude.sh` (feature parity).

## Notes from Last Session (6.2)

- Implemented 6.2: Log Viewer.
- Created `logviewer.html`: standalone dark-theme HTML log viewer with no external dependencies.
  - Fetches `/api/logs` to get list of all `orchclaude-log*.txt` files in the work directory.
  - Fetches `/api/log?file=<name>` to get full content of the selected log file.
  - Polls every 3 seconds (live-friendly for in-progress runs).
  - Color coding: PROGRESS lines → green, QA_FINDING/QA_SUMMARY/QA_PASS → yellow, ERROR/CIRCUIT BREAKER/TIMEOUT/FAILED → red, phase banners → blue, ORCHESTRATION_COMPLETE/TEST PASSED → bright green, all others → dim gray.
  - Filter toolbar: ALL / PROGRESS / QA / ERRORS / INFO — single-click toggles.
  - Live search input (200ms debounce) with `<mark>` highlight on matching text.
  - File selector dropdown: auto-populates from workDir, sorted newest-first; supports switching between orchclaude-log.txt and agent logs (orchclaude-log-agent1.txt etc.).
  - Line numbers in gutter for easy reference.
  - Auto-scroll checkbox (on by default); unchecking lets the user browse historical lines without jumping.
  - Line counter: "Lines: N visible / M total" updates with every filter/search change.
  - Live dot indicator: green pulse when connected, gray when server unreachable.
- Added `orchclaude log` command to `orchclaude.ps1`.
  - Starts a PS HttpListener on port 7891 (separate from dashboard's 7890; no admin required for localhost).
  - Serves: `GET /` → logviewer.html, `GET /api/logs` → JSON array of orchclaude-log*.txt filenames, `GET /api/log?file=<name>` → full file content.
  - File parameter is sanitized (must match `^orchclaude-log[a-zA-Z0-9_\-]*\.txt$`) to prevent path traversal.
  - Returns full file content (not capped at 200 lines like the dashboard endpoint).
  - Opens browser automatically via `Start-Process`.
  - Accepts `-d <path>` to point at a different work directory.
- Added `logviewer.html` to `files` array in `package.json` so npm installs it alongside the scripts.
- Updated help text and unknown-command error to include `log`.
- Phase 6 now fully complete. Next: 7.1 Task Classifier.

## Notes from Previous Session (6.1)

- Implemented 6.1: Status Dashboard.
- Created `dashboard.html`: standalone dark-theme HTML dashboard with no external dependencies.
  - Fetches `/api/session` and `/api/log` every 3 seconds via JavaScript polling.
  - Shows: status badge (running/complete/timeout), iteration progress bar, elapsed/remaining time, progress lines list, task preview, and color-coded log viewer.
  - PROGRESS lines → green, QA_FINDING → yellow, errors → red, banners → blue.
  - Live indicator dot with pulse animation shows connection state.
- Added `orchclaude dashboard` command to `orchclaude.ps1`.
  - Starts a PS HttpListener on port 7890 (no admin required for localhost).
  - Serves: `GET /` → dashboard.html, `GET /api/session` → orchclaude-session.json, `GET /api/log` → last 200 lines of orchclaude-log.txt.
  - Uses `BeginGetContext` + 100ms poll loop so Ctrl+C exits cleanly.
  - Opens browser automatically via `Start-Process`.
  - Accepts `-d <path>` to point at a different work directory.
- Added `dashboard.html` to `files` array in `package.json` so npm installs it alongside the scripts.
- Updated help text and unknown-command error message to include `dashboard`.
- Phase 6 item 6.1 complete. Next: 6.2 Log Viewer.

## Notes from Previous Session (5.2)

- Implemented 5.2: Package Distribution (npm).
- Created `package.json`: name `orchclaude`, version 0.1.0, `bin` field points to `bin/orchclaude.js`, `postinstall` runs `scripts/postinstall.js`, `files` includes only the scripts and bin/scripts dirs.
- Created `bin/orchclaude.js`: Node.js shim (#!/usr/bin/env node). Detects `process.platform`. On Windows: spawns `powershell.exe -ExecutionPolicy Bypass -File orchclaude.ps1`. On Unix: spawns `bash orchclaude.sh`. Passes all args through. Forwards exit code.
- Created `scripts/postinstall.js`: on non-Windows, runs `chmod +x orchclaude.sh` after install. Non-fatal if it fails.
- Updated README.md: added "Install via npm (recommended)" section at the top with `npm install -g orchclaude` and upgrade instructions.
- Users can now install with: `npm install -g orchclaude`
- Phase 5 is now fully complete. Next: 6.1 Status Dashboard.

## Notes from Previous Session (5.1)

- Implemented 5.1: Linux / macOS Port.
- Wrote `orchclaude.sh` — a full bash equivalent of `orchclaude.ps1` with 100% feature parity.
- Same flags: -t, -i, -f, -d, -v, -noqa, -token, -cooldown, -breaker, -dryrun, -noplan, -nobranch, -profile, -agents.
- Same commands: run, resume, status, help, profile (save/list/delete).
- Same phases: Planning, Parallel Agents, Build Loop (with Context Window Guard + Auto-Commit Checkpoints), QA.
- ANSI colours replace PowerShell's -ForegroundColor; python3 used for JSON I/O (universally available on Linux/macOS).
- Parallel agents use bash background subshells (`&`) + temp files; `wait` replaces `Wait-Job`.
- Profiles stored in `~/.orchclaude/profiles.json` (same concept as Windows `%USERPROFILE%\.orchclaude\profiles.json`).
- Git worktree isolation works unchanged (same git CLI).
- Updated README.md with Linux/macOS one-time setup instructions.
- Phase 5 item 5.1 complete. Next: 5.2 Package Distribution (npm).

## Notes from Previous Session (4.1)

- Implemented 4.1: Parallel Agents.
- Added `-agents <n>` flag (default: 1, existing behavior unchanged).
- Errors if `-agents > 1` combined with `-noplan` (planning required for task splitting).
- After the plan phase, parses `depends: none` tasks from the plan file.
- Splits independent tasks round-robin across N agents (caps at number of independent tasks).
- Each agent: `Start-Job` PowerShell background job, own log `orchclaude-log-agentN.txt`, own subdir `agent-N/`.
- Agent job is self-contained: defines its own claude call, writes its log, returns output.
- Orchestrator waits for all jobs (`Wait-Job` with remaining timeout), then runs a merge Claude call.
- Merge phase: feeds all agent outputs + any dependent tasks to Claude, asks it to integrate into `$workDir`.
- CONFLICT lines flagged in Red; PROGRESS lines appended to progress log.
- If merge produces completion token: QA + git merge prompt run as normal, then `exit 0`.
- Falls back to single-agent if no `depends: none` tasks found.
- Phase 4 is now fully complete. Next: 5.1 Linux/macOS Port.

## Notes from Last Session (3.2)

- Implemented 3.2: Auto-Commit Checkpoints.
- After each build iteration where new PROGRESS lines appear, checks `git status --porcelain` in the worktree.
- If files changed: runs `git add -A` + `git commit -m "orchclaude checkpoint: <last PROGRESS line>"`.
- Logs the short commit hash with `Write-Log` in DarkCyan; also appends to orchclaude-log.txt.
- No-op when: no worktree (nobranch/non-git), no new progress lines, or no file changes (prevents empty commits).
- Phase 3 is now fully complete. Next: 4.1 Parallel Agents.

## Notes from Previous Session (3.1)

- Implemented 3.1: Git Worktree Isolation.
- At run start, checks if workDir is a git repo (`git rev-parse --git-dir`).
- If yes: creates branch `orchclaude/<timestamp>` and worktree in `%TEMP%\orchclaude-wt-<timestamp>`.
- All build/QA work happens inside the worktree; `$workDir` is updated to point there.
- Subdir handling: if `$workDir` was a subdirectory of the repo root, the equivalent subdir in the worktree is used.
- On success: prompts user "Merge? (y/n)". y → `git merge --no-ff` then cleans up branch; n → removes worktree folder, preserves branch.
- On failure/timeout: prints branch name and merge command for manual recovery.
- `-nobranch` flag skips all of this and writes directly (previous behavior).
- Non-git dirs: skip silently with a DarkGray notice.
- Banner shows active branch name or why isolation was skipped.
- `nobranch` added to profile save/load.
- Phase 3 checklist: 3.1 complete, 3.2 next.

## Notes from Previous Session (2.3)

- Implemented 2.3: Named Profiles.
- Profiles stored in `%USERPROFILE%\.orchclaude\profiles.json` (human-readable JSON).
- `orchclaude profile save <name> [flags]`: saves explicitly-passed flags using $PSBoundParameters.
- `orchclaude profile list`: shows all profiles with their flag values.
- `orchclaude profile delete <name>`: removes a profile; errors if not found.
- `-profile <name>` on `orchclaude run`: loads profile flags; CLI flags override via $PSBoundParameters check.
- Helper functions `Get-Profiles` / `Save-Profiles` defined globally for reuse.
- Position=2 param `$SubArg` used to capture profile name in save/delete subcommands.
- Banner shows "Profile: <name>" line when a profile is loaded.
- README and ORCHCLAUDE-GUIDE.md updated with profile documentation and examples.
- Phase 2 is now fully complete.

---

## How to Start a New Session

1. Read this file (STATUS.md) — find "Next item to implement"
2. Read ROADMAP.md — find that item, read the full spec including acceptance criteria
3. Read orchclaude.ps1 — understand the current code before changing it
4. Implement the feature
5. Test every acceptance criterion manually
6. Update STATUS.md: check off the item, update "Next item to implement", update "Last session date"
7. Commit: git add -A && git commit -m "feat: <item name>"
8. Push: git push origin master:main
