# orchclaude — Build Status

This file is updated at the end of every development session.
It is the first thing any new session should read before touching any code.

---

## Current State

**Version:** 0.1.0
**Phase:** 4 — Multi-Agent Execution
**Next item to implement:** 5.1 — Linux / macOS Port
**Last session date:** 2026-04-19
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

- [ ] 5.1 — Linux / macOS Port
- [ ] 5.2 — Package Distribution (npm)

---

## Phase 6 Checklist

- [ ] 6.1 — Status Dashboard
- [ ] 6.2 — Log Viewer

---

## Phase 7 Checklist — Smart Model Mode

- [ ] 7.1 — Task Classifier (route iterations to haiku / sonnet / opus automatically)
- [ ] 7.2 — Adaptive Escalation (escalate model when no progress detected)
- [ ] 7.3 — Cost-Aware Budget Mode (`-budget` flag)
- [ ] 7.4 — Model Profile Presets (`-modelprofile fast/balanced/quality/auto`)

---

## Known Issues

- None currently logged.

---

## Notes from Last Session (4.1)

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
