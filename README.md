# orchclaude

Keeps Claude Code running on a project until it actually finishes — not until Claude decides it's done.

> **Status: actively self-building.** orchclaude is being developed by running itself against its own codebase. **Only tested on Windows.** A Linux/macOS shell script exists but has never been run in the field — treat it as experimental. See [Known Issues](#known-issues) before using in production.

---

## What it does

You give it a prompt and a time limit. It calls Claude Code in a loop until Claude outputs `ORCHESTRATION_COMPLETE` or time runs out. After the build it runs a second adversarial QA pass that finds edge cases and fixes them directly in the files.

Every run is resumable. Kill the terminal, come back, run `orchclaude resume` and it picks up exactly where it left off — progress, prompt, and all flags intact.

---

## Install

Requires Node.js 14+ and Claude Code (`claude` CLI) in your PATH.

```
npm install -g orchclaude
```

Or clone and use directly:

**Windows** — add `bin/` to your PATH, then:
```powershell
Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
```

**Linux / macOS:**
```bash
chmod +x orchclaude.sh
cp orchclaude.sh ~/.local/bin/orchclaude
```

---

## Quick start

```
orchclaude run "Build a Python script that renames files by date" -t 20m
orchclaude run -f my-project.md -t 2h
orchclaude resume                          # continue after a crash or Ctrl+C
```

---

## All flags

```
REQUIRED
  "prompt"            What to build. Be as detailed as you want.
  -t <time>           Timeout. Format: 30m, 2h, 90m

OPTIONAL
  -f <file>           Load prompt from a .md or .txt file
  -i <n>              Max iterations before giving up (default: 40)
  -d <path>           Working directory (default: current folder)
  -v                  Verbose — print Claude's full output each iteration
  -noqa               Skip the QA pass
  -noplan             Skip pre-planning (use for simple one-step tasks)
  -nobranch           Skip git worktree isolation, write directly to repo
  -token <word>       Custom completion token (default: ORCHESTRATION_COMPLETE)
  -cooldown <s>       Seconds between iterations (default: 5, use 0 to disable)
  -breaker <n>        Circuit breaker: pause after N stalled iterations (default: 10)
  -dryrun             Print the prompt that would be sent, then exit — no Claude call
  -profile <name>     Load a saved flag profile (CLI flags override)
  -agents <n>         Run N parallel Claude agents on independent subtasks (default: 1)
  -model <tier>       Force model: light (haiku), standard (sonnet), heavy (opus),
                      or a raw model ID
  -modelprofile <p>   Model preset: fast | balanced | quality | auto (default: auto)
  -budget <amount>    Pause and confirm if estimated cost exceeds this (e.g. -budget 0.50)
  -autowait           On usage limit: sleep in-process for -waittime minutes, then resume
  -autoschedule       On usage limit: create a Windows scheduled task and exit cleanly
  -waittime <min>     Minutes to wait after a usage limit hit (default: 300 = 5 hours)
  -n <number>         For orchclaude history — entries to show (default: 20)
```

---

## Commands

```
orchclaude run "<prompt>" -t <timeout> [flags]
orchclaude run -f <file>  -t <timeout> [flags]
orchclaude resume         [-d <path>]          continue an interrupted run
orchclaude status         [-d <path>]          show session state without resuming
orchclaude explain        [-d <path>]          read-only Claude explanation of a directory
orchclaude diff           [-d <path>] [-v]     git diff of everything changed in the last run
orchclaude history        [-n <count>]         table of past runs with cost, duration, status
orchclaude history clear                       wipe run history
orchclaude metrics        [-d <path>]          per-iteration model/token/cost breakdown
orchclaude dashboard      [-d <path>]          live web dashboard (localhost:7890)
orchclaude log            [-d <path>]          live log viewer (localhost:7891)
orchclaude profile save   <name> [flags]       save a flag combination for reuse
orchclaude profile list                        list all saved profiles
orchclaude profile delete <name>               remove a profile
```

---

## How it works

**Pre-planning phase** (runs first unless `-noplan`)
Claude breaks your task into a numbered subtask list with dependencies. The plan is saved to `orchclaude-plan.txt` and injected into every build iteration so Claude always knows what's next.

**Phase 1 — Build loop**
Your prompt goes to Claude Code with a strict contract: do not stop until everything is done, output `ORCHESTRATION_COMPLETE` when finished. After each iteration, every `PROGRESS:` line Claude printed is fed back so it knows what it already completed and doesn't redo it. Loops until token found or timeout.

**Phase 2 — QA pass** (automatic after build, skip with `-noqa`)
Claude switches to adversarial tester mode. Reads all output files, checks for edge cases (empty input, overflow, unicode, rapid actions, localStorage unavailable, invalid dates, async failures), fixes each issue directly in the files. Prints findings as `QA_FINDING:` lines.

**Smart model routing** (automatic)
First iteration always uses opus. Subsequent iterations are classified by a fast haiku call and routed to haiku / sonnet / opus based on complexity. If no progress is detected for 2 consecutive iterations, the model escalates (haiku → sonnet → opus). Override with `-model` or `-modelprofile`.

**Git worktree isolation** (automatic in git repos)
When running in a git repository, orchclaude creates a branch `orchclaude/<timestamp>` and a temporary worktree so all changes are isolated. At the end you're prompted to merge or discard. Use `-nobranch` to skip this and write directly.

**Parallel agents** (`-agents <n>`)
After planning, independent subtasks are split across N Claude agents running simultaneously. Each agent works in its own subdirectory. A final merge call integrates all outputs and handles conflicts.

---

## Usage limit handling

When Claude Code returns a usage limit error, orchclaude can handle it in three ways:

| Mode | Flag | Behavior |
|---|---|---|
| Manual (default) | _(none)_ | Saves session, prints resume time, exits. Run `orchclaude resume` when limit resets. |
| Auto-wait | `-autowait` | Sleeps in-process, prints countdown every 10 minutes, resumes automatically. Terminal must stay open. |
| Auto-schedule | `-autoschedule` | Creates a Windows scheduled task to resume at the reset time. Terminal can close. |

**Known issue:** Auto-resume after usage limit is functional but has rough edges. If the run hits the limit on iteration 1 (before any progress), the resume will retry the same full prompt from scratch. Detection of the usage limit message is pattern-matched and may miss unusual error formats. Overnight unattended runs with `-autowait` work but expect occasional manual intervention.

---

## Named profiles

Save flag combinations and reuse them:

```
orchclaude profile save bigrun -t 3h -i 80 -d "C:\Projects\MyApp"
orchclaude profile list
orchclaude run -f feature.md -profile bigrun
orchclaude run -f feature.md -profile bigrun -t 30m    # CLI flag overrides profile
```

---

## Output files

All written to the working directory (`-d` or current folder):

| File | Contents |
|---|---|
| `orchclaude-log.txt` | Full output from every iteration |
| `orchclaude-progress.txt` | `PROGRESS:` lines only — what Claude completed each step |
| `orchclaude-session.json` | Session state for crash recovery |
| `orchclaude-plan.txt` | Subtask plan from the pre-planning phase |
| `orchclaude-metrics.json` | Per-iteration model, tokens, cost, elapsed time |

---

## Examples

```
# Simple script
orchclaude run "Build a Python script that renames all files in a folder by date" -t 20m

# From a spec file
orchclaude run -f my-project.md -t 2h

# Verbose, skip QA, specific folder
orchclaude run "Refactor the auth module" -t 30m -v -noqa -d "C:\Projects\MyApp"

# Preview prompt without calling Claude
orchclaude run -f project.md -t 2h -dryrun

# Parallel agents for a large project
orchclaude run -f big-project.md -t 3h -agents 4

# Always use opus (best quality, highest cost)
orchclaude run -f project.md -t 2h -modelprofile quality

# Stay under $1
orchclaude run "Add dark mode" -t 1h -budget 1.00

# Unattended overnight — auto-resumes after 5-hour usage limit reset
orchclaude run -f project.md -t 2h -autowait -waittime 300

# Resume after a crash
orchclaude resume
orchclaude resume -d "C:\Projects\MyApp"

# Check what changed
orchclaude diff
orchclaude diff -v    # full line-by-line

# Live monitoring
orchclaude dashboard
orchclaude log
```

---

## Known issues

- **Usage limit auto-resume:** `-autowait` works but may lose the current iteration when it resumes (fix in progress). On first-iteration failures, the full prompt reruns from the start. Pattern matching for usage limit detection may miss some error message formats.
- **Session flag restore on resume:** Not all flags are saved to the session file. A run resumed after a crash may not have the same `-autowait`, `-budget`, or `-modelprofile` as the original (fix in progress as 9.2).
- **Windows only (tested):** All development and testing has been done exclusively on Windows. The Linux/macOS bash port (`orchclaude.sh`) is untested — it may work but treat it as experimental until confirmed otherwise.
- **Template and webhook commands:** Referenced in some documentation but not reliably available in all install versions.

---

## Project spec file format

For larger projects, write your requirements in a `.md` file:

```markdown
# Project: My App

## Goal
Build a REST API that...

## Acceptance Criteria
- [ ] Endpoint A returns correct data
- [ ] Input validation rejects bad requests
- [ ] Tests pass

## Tech Stack
Node.js, Express, SQLite
```

Then run:
```
orchclaude run -f my-project.md -t 2h
```

---

## Get help

```
orchclaude help
orchclaude --help
```
