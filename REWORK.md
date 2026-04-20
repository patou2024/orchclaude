# orchclaude — Rework Audit

Date: 2026-04-20
Audited file: `orchclaude.ps1` (repo, ~2075 lines)

This document catalogs every real bug, missing implementation, and design flaw found
during a full line-by-line code review. Items are ranked by severity.

---

## CRITICAL — Will break real runs

### C1. Wrong Opus model ID
**File:** `orchclaude.ps1:1258`
**Code:** `"heavy" = "claude-opus-4-7"`
**Problem:** Model ID `claude-opus-4-7` does not exist. Correct ID is `claude-opus-4-6`.
Every call that escalates to opus — or uses `-modelprofile quality` or `-model heavy` — will
fail with a model-not-found error from the API.
**Fix:** Change `"claude-opus-4-7"` to `"claude-opus-4-6"`.

---

### C2. Classifier call missing `--dangerously-skip-permissions`
**File:** `orchclaude.ps1:1293`
**Code:**
```powershell
$raw = (& claude -p $classifyPrompt --model claude-haiku-4-5-20251001 --max-turns 1 2>&1) -join " "
```
**Problem:** Every build iteration calls `Get-TaskTier` which calls `claude` without
`--dangerously-skip-permissions`. In a fresh Claude Code session or after a session reset
Claude will prompt for tool permissions. Nobody answers → returns in ~2 seconds with empty
output → classifier always falls through to "standard". In the worst case it fully blocks.
**Fix:** Add `--dangerously-skip-permissions` to the classifier claude call.

---

### C3. Feature Backlog features not in repo PS1
**Affected features:** `orchclaude template`, `Send-Webhook`, `.orchclauderc` loading
**Problem:** STATUS.md marks all three as complete. The bin version (`C:\Users\pana5\bin\orchclaude.ps1`)
contains partial template code (confirmed by parse errors at bin:586-620). The repo PS1 has
none of these: no `template` command handler, no `Send-Webhook` function, no `.orchclauderc`
file loading. The repo is behind the bin, but the bin has parse errors. Neither version is clean.
**Evidence:** Bin parse errors referenced `orchclaude template show <name>` (redirection error)
and missing closing braces in `Handle-UsageLimit` (line 1245), suggesting the bin was modified
after the last repo sync and the modifications were broken.
**Fix:** Decide whether to implement these cleanly in the repo or strip them from STATUS.md.
A clean re-implementation from the STATUS.md notes is safer than recovering the broken bin.

---

### C4. `autowait` `continue` resumes wrong iteration
**File:** `orchclaude.ps1:1814-1819`
**Code:**
```powershell
if ($shouldResume) {
    continue  # autowait completed — re-run this iteration
}
```
**Problem:** `continue` in a `for` loop always increments `$iter`. The comment says "re-run this
iteration" but the code skips to the NEXT iteration. When usage limit hits mid-iteration,
that iteration's work is lost and the loop moves forward. The correct fix is `$iter--; continue`.
**Fix:** Replace `continue` with `$iter--; continue`.

---

### C5. Unattended mode blocks on interactive `Read-Host`
**Affects:** `-autowait` mode (overnight unattended runs)
Three places block indefinitely waiting for keyboard input with no auto-confirm:

| Location | Line | Prompt shown |
|---|---|---|
| Circuit breaker | ~1928 | `"Continue? (y/n/new prompt)"` |
| Budget exceeded | ~1023 | `"Continue? (y/n)"` |
| Worktree merge (end) | ~2057 | `"Merge branch? (y/n)"` |

A run that hits any of these in `-autowait` mode hangs forever.
The ROADMAP 1.6 spec explicitly required auto-confirm for unattended mode.
**Fix:** Check `$autowait -or $autoschedule` before each `Read-Host`. If true, log the
auto-decision and proceed with a safe default (circuit breaker: continue; budget: continue;
worktree merge: skip merge, preserve branch).

---

## HIGH — Correctness issues that affect real functionality

### H1. `Write-Session` missing critical flags
**File:** `orchclaude.ps1:935-950` (Write-Session flags hash)
**Problem:** The session file's `flags` object only saves:
`t, i, noqa, token, v, cooldown, breaker`
Missing: `autowait, autoschedule, waittime, agents, model, budget, modelprofile, nobranch`
On `orchclaude resume`, these flags are not restored. A run resumed after a crash loses its
model profile, budget limit, agent count, and usage-limit handling mode.
**Fix:** Add all missing flags to the `Write-Session` flags hash and restore them in the resume block.

---

### H2. `Handle-UsageLimit` duplicates session save without `startCommit`/`originalWorkDir`/`worktreeBranch`
**File:** `orchclaude.ps1:1161-1181`
**Problem:** `Handle-UsageLimit` writes its own `$sessionData` directly to the session file
instead of calling `Write-Session`. This custom write is missing `startCommit`,
`originalWorkDir`, and `worktreeBranch`. After a usage-limit pause, `orchclaude diff` cannot
reconstruct the git diff because those fields are gone from the session.
**Fix:** Replace the manual session write in `Handle-UsageLimit` with `Write-Session "usage_limit_paused" $currentIter`,
then patch in `resumeAfter` and `pausedAt` on the resulting JSON, or extend `Write-Session` to accept extra fields.

---

### H3. `modelprofile` processed before named profile loading
**File:** `orchclaude.ps1:42-55` (modelprofile switch) vs `orchclaude.ps1:766-785` (profile load)
**Problem:** The 7.4 modelprofile switch block runs at script top, before named profile
(`-profile`) loading. STATUS.md notes say "the 7.4 block was moved to run AFTER RC and profile
loading" — but in the actual code it is still at the top. If a named profile sets `modelprofile`,
it is loaded at line 785 but the switch block that acts on it already ran at line 44.
Result: modelprofile from a named profile is silently ignored.
**Fix:** Move the entire modelprofile switch block to after the profile loading block (~line 785).

---

### H4. `metrics` display does not actually reverse order
**File:** `orchclaude.ps1:667`
**Code:**
```powershell
$reversed = @($metrics) | Select-Object -Last [int]::MaxValue
```
**Problem:** `Select-Object -Last N` selects the last N items in the existing order — it does
not reverse the array. Metrics are stored newest-first, so the display shows newest-first,
but the comment says "reverse for display (oldest-first)". The table is shown in the wrong order.
**Fix:** Use `[array]::Reverse($reversed)` after the Select-Object, or use
`$metrics | Sort-Object iterationNumber`.

---

## MEDIUM — Bad output / encoding / UX issues

### M1. Encoding corruption throughout (garbled unicode)
**Occurrences:** ~15+ places in the file
**Examples:**
- `"ÔÇö reinstall orchclaude"` (line 211, 297) — should be `"— reinstall orchclaude"` or just `"- reinstall orchclaude"`
- `"ÔåÆ always heavy"` (line 1277 comment) — should be `"→ always heavy"`
- `"ÔÇö"` in Write-Log messages, Write-Warning, Write-Error, and prompt strings

**Problem:** The file was saved with mixed encoding at some point (UTF-8 BOM content decoded
as Windows-1252). The garbled sequences appear in user-visible terminal output and in prompts
sent to Claude, making both look unprofessional.
These do NOT crash PowerShell (they're in quoted strings, not operators) but they look broken.
**Fix:** Replace all `ÔÇö` with `-` and all `ÔåÆ` with `->` throughout the file.

---

### M2. `<name>` in Write-Host strings (bin version parse failure)
**File:** `C:\Users\pana5\bin\orchclaude.ps1:586-620`
**Problem:** The bin version has `Write-Host "orchclaude template show <name>"` and
`Write-Error "Usage: orchclaude template show <name>"`. PowerShell interprets `<` as a
redirection operator in unquoted contexts, but even inside double-quoted strings in some
PS versions (especially older ones or strict mode) this can cause parse errors.
The bin file fails to parse at all due to these errors and the unclosed-brace cascade that follows.
**Fix:** Replace `<name>` with `NAME` in all string literals.

---

### M3. `EXPLAIN MODE ÔÇö` in prompt sent to Claude
**File:** `orchclaude.ps1:415`
**Code:** `## EXPLAIN MODE ÔÇö read-only, no file changes`
**Problem:** The garbled sequence is sent inside the actual prompt to Claude. Claude will
receive `ÔÇö` in its instructions. Non-critical (Claude ignores it) but looks bad in logs.
**Fix:** Change to `## EXPLAIN MODE - read-only, no file changes`.

---

### M4. `metrics` command exists but not in ROADMAP or STATUS
**File:** `orchclaude.ps1:636-704`
**Problem:** A fully-implemented `orchclaude metrics` command and `Write-Metrics` function
exist in the code, referenced as "Phase 9.1". STATUS.md says "Phase 9 undefined." This
feature was implemented without updating the roadmap, without documenting it in STATUS.md,
and without being mentioned in README or ORCHCLAUDE-GUIDE.md.
Users can't discover it. Help text doesn't mention it prominently.
**Fix:** Add Phase 9 to ROADMAP.md (document `metrics` under 9.1), check off 9.1 in STATUS.md,
add `orchclaude metrics` to README and ORCHCLAUDE-GUIDE.md.

---

## LOW — Minor issues / polish

### L1. Temp prompt files not cleaned up on crash
**File:** `orchclaude.ps1:1231-1251` (Invoke-Claude)
**Problem:** `Remove-Item $promptFile` is called normally, but if `claude` crashes or the
script is Ctrl+C'd mid-call, the temp files in `$env:TEMP` accumulate. No try/finally block.
**Fix:** Wrap the claude call in try/finally to ensure `Remove-Item` always runs.

---

### L2. `$completed = $true` set inside parallel block but never read there
**File:** `orchclaude.ps1:1590`
**Problem:** Line 1590 sets `$completed = $true` during the parallel merge phase, but the
parallel path always ends with `exit 0` or `exit 1` before reaching the build loop where
`$completed` is first initialized at line 1705. The assignment at 1590 has no effect.
**Fix:** Remove line 1590 (the `$completed = $true` assignment in the parallel merge block).

---

### L3. `history` -n flag default is redundant
**File:** `orchclaude.ps1:594`
**Code:** `$limit = if ($n -gt 0) { $n } else { 20 }`
**Problem:** `$n` defaults to 20 in the param block and is always > 0, so the `else { 20 }`
branch is unreachable. Minor but dead code.
**Fix:** Simplify to `$limit = $n`.

---

### L4. `$PSScriptRoot` may be empty when called via `.cmd` wrapper
**File:** `orchclaude.ps1:210, 294`
**Code:** `$dashHtml = Join-Path $PSScriptRoot "dashboard.html"`
**Problem:** `$PSScriptRoot` is only populated when the script is run as a file via
`powershell -File script.ps1`. When invoked via `orchclaude.cmd` (which uses `-Command`
or redirects), `$PSScriptRoot` can be empty, causing the dashboard/log paths to resolve to
the current directory instead of the orchclaude install directory.
**Fix:** Add a fallback: `$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path $MyInvocation.MyCommand.Path }`.

---

## Summary Table

| ID | Severity | Description |
|---|---|---|
| C1 | CRITICAL | Wrong opus model ID (`4-7` should be `4-6`) |
| C2 | CRITICAL | Classifier missing `--dangerously-skip-permissions` |
| C3 | CRITICAL | template/webhook/.orchclauderc not in repo PS1 |
| C4 | CRITICAL | autowait `continue` skips iteration instead of re-running |
| C5 | CRITICAL | 3x `Read-Host` blocks unattended `-autowait` runs |
| H1 | HIGH | `Write-Session` missing 8 flags; resume loses them |
| H2 | HIGH | `Handle-UsageLimit` session save missing git diff fields |
| H3 | HIGH | modelprofile switch runs before profile loading; profile modelprofile ignored |
| H4 | HIGH | metrics display not actually reversed (wrong order) |
| M1 | MEDIUM | ~15 garbled unicode sequences in terminal output |
| M2 | MEDIUM | `<name>` in bin PS1 strings causes parse failure |
| M3 | MEDIUM | Garbled unicode in prompt sent to Claude |
| M4 | MEDIUM | `metrics` command undocumented (no ROADMAP/STATUS/README entry) |
| L1 | LOW | Temp files not cleaned up on crash |
| L2 | LOW | Dead `$completed = $true` in parallel branch |
| L3 | LOW | Unreachable `else { 20 }` in history limit |
| L4 | LOW | `$PSScriptRoot` empty when called via .cmd wrapper |

---

## Recommended fix order

1. C1 — one line change, highest impact (all opus calls failing right now)
2. C2 — one line change, fixes classifier in unattended mode
3. C5 — add 3 auto-confirm guards for `-autowait`
4. C4 — one line change in autowait resume loop
5. H3 — move modelprofile block ~40 lines down
6. H1 + H2 — extend Write-Session, fix Handle-UsageLimit session write
7. M1 + M3 — bulk find-replace encoding garbage
8. C3 — re-implement template/webhook/.orchclauderc cleanly
9. M4 + L4 — documentation and PSScriptRoot fix
