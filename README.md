# orchclaude

A lightweight Windows orchestrator that keeps Claude Code running on a project until the work is actually done — not until Claude decides it is.

Built in a single 20-minute session as a proof of concept. Works well enough to be useful. There is plenty of room to improve and I will update it as I find new use cases or run into limitations.

---

## The Problem

Claude Code stops when it thinks it is done. That is not always when you want it to stop. `orchclaude` flips that around — you define what "done" means, and Claude loops until it gets there.

---

## Platform

**Windows only.** Requires PowerShell and Claude Code CLI.

- Windows 10 / 11
- [Claude Code](https://claude.ai/code) installed and signed in
- PowerShell (built into Windows — no install needed)

---

## What It Does

**Phase 1 — Build**
Sends your prompt to Claude Code with a strict contract: make real file changes, report progress, and do not stop until all requirements are met. If Claude stops early, it gets the same prompt again with its prior progress attached so it picks up where it left off.

**Phase 2 — QA (automatic)**
Once the build is complete, runs a second pass where Claude acts as an adversarial tester. It reads every output file, checks for edge cases (empty input, special characters, rapid clicks, localStorage failures, invalid formats, leftover state, etc.), and fixes every issue it finds directly in the files. Every finding is printed and logged.

---

## Installation

**1. Clone or download this repo**

```
git clone https://github.com/patou2024/orchclaude.git
```

Or download `orchclaude.ps1` and `orchclaude.cmd` manually.

**2. Put the files in a folder**, for example:

```
C:\Users\YourName\bin\
```

**3. Add that folder to your PATH** (run once in PowerShell):

```powershell
[Environment]::SetEnvironmentVariable("PATH", $env:PATH + ";C:\Users\YourName\bin", "User")
```

Then close and reopen your terminal.

**4. Allow PowerShell scripts** (run once if not already done):

```powershell
Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
```

---

## Usage

```
orchclaude run "your prompt here" -t 30m
```

Claude runs, loops, and stops when it finishes — or when your timeout is hit.

### Syntax

```
orchclaude run "<prompt>"  -t <timeout>  [options]
orchclaude run -f <file>   -t <timeout>  [options]
```

### Flags

| Flag | Description | Default |
|------|-------------|---------|
| `-t <time>` | Timeout. Format: `30m`, `2h`, `90m` | `30m` |
| `-f <file>` | Load prompt from a `.md` or `.txt` file | — |
| `-i <number>` | Max iterations before giving up | `40` |
| `-d <path>` | Working directory for Claude to operate in | current folder |
| `-v` | Verbose — print Claude's full output each iteration | off |
| `-noqa` | Skip the automatic QA pass | off |
| `-token <word>` | Custom completion token | `ORCHESTRATION_COMPLETE` |
| `-test <cmd>` | Validation command. Run after each completion claim. Claude only finishes if exit code is 0. If tests fail, Claude is re-run with the failure output attached. | — |

### Examples

```powershell
# Inline prompt
orchclaude run "Build a Node.js REST API with /health and /users endpoints" -t 30m

# From a spec file
orchclaude run -f my-project.md -t 2h

# Specific folder, verbose output
orchclaude run "Add dark mode" -t 45m -d "C:\Projects\MyApp" -v

# Skip QA for quick fixes
orchclaude run "Fix the typo on the homepage" -t 10m -noqa

# Require tests to pass before completing
orchclaude run "Add the login feature" -t 1h -test "npm test"
orchclaude run -f project.md -t 2h -test "pytest"
orchclaude run "Implement sorting" -t 30m -test "cargo test"
```

---

## Project Spec Files

For larger projects, write your requirements in a markdown file:

```markdown
# Project: My App

## Goal
Build a ...

## Acceptance Criteria
- [ ] Feature A works
- [ ] Feature B works

## Tech Stack
- Node.js, Express
```

Then run:

```
orchclaude run -f my-project.md -t 1h
```

---

## Output Files

After each run, two files are created in your working directory:

| File | Contents |
|------|----------|
| `orchclaude-log.txt` | Full output from every build and QA iteration |
| `orchclaude-progress.txt` | Progress lines only — what Claude completed each step |

---

## Full Help

```
orchclaude --help
```

Prints the complete guide directly in your terminal.

---

## Current Limitations

- Windows only (no Mac / Linux support yet)
- Requires Claude Code CLI — does not work with the Claude Desktop chat app
- No parallel agents — runs one Claude session at a time
- QA pass is general purpose — it does not know your specific test suite
- Built in one session, so edge cases in the orchestrator itself likely exist

---

## Roadmap / Ideas

Things I may add depending on how I end up using this:

- Mac / Linux support
- `--dry-run` flag to preview the prompt before sending
- Named profiles to save common flag combinations
- Crash recovery (`orchclaude resume`)
- Rate limiting and circuit breaker for runaway loops
- Multi-file project spec with automatic context loading

---

## Contributing

This is a personal project but pull requests are welcome. If you find a bug or have a clear improvement, open an issue or PR.

---

## License

MIT
