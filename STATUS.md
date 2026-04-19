# orchclaude — Build Status

This file is updated at the end of every development session.
It is the first thing any new session should read before touching any code.

---

## Current State

**Version:** 0.1.0
**Phase:** 1 — Foundation Hardening
**Next item to implement:** 1.2 — Crash Recovery (`orchclaude resume`)
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
- [ ] 1.2 — Crash Recovery (`orchclaude resume`)
- [ ] 1.3 — Rate Limiting and Circuit Breaker
- [ ] 1.4 — Token / Cost Estimator
- [ ] 1.5 — `--dry-run` flag

---

## Phase 2 Checklist

- [ ] 2.1 — Pre-Planning Phase
- [ ] 2.2 — Context Window Guard
- [ ] 2.3 — Named Profiles

---

## Phase 3 Checklist

- [ ] 3.1 — Git Worktree Isolation
- [ ] 3.2 — Auto-Commit Checkpoints

---

## Phase 4 Checklist

- [ ] 4.1 — Parallel Agents

---

## Phase 5 Checklist

- [ ] 5.1 — Linux / macOS Port
- [ ] 5.2 — Package Distribution (npm)

---

## Phase 6 Checklist

- [ ] 6.1 — Status Dashboard
- [ ] 6.2 — Log Viewer

---

## Known Issues

- None currently logged.

---

## Notes from Last Session

- Implemented 1.1: External Validation Gate (-test flag).
- After each completion claim, the test command runs via cmd /c.
- Test failure injects $testFailureContext into the next iteration prompt.
- Test output capped at 40 lines to keep prompts manageable.
- Works with npm test, pytest, cargo test, any shell command.
- em dash characters cause PowerShell parse errors — avoid in script strings, use plain dash.
- Exit code 1 on git push is a false alarm — git writes remote info to stderr.

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
