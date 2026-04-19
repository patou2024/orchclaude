# orchclaude - Guide

Keeps Claude running on a project until it finishes - not until Claude decides it's done.
After the build, automatically runs a QA pass that checks edge cases and fixes issues.

---

## One-Time Setup

1. Add orchclaude to your PATH (run once in PowerShell):

    [Environment]::SetEnvironmentVariable("PATH", $env:PATH + ";C:\Users\pana5\bin", "User")

   Then close and reopen your terminal.

2. Allow PowerShell scripts (run once if not already done):

    Set-ExecutionPolicy RemoteSigned -Scope CurrentUser

---

## Basic Usage

    orchclaude run "your prompt here" -t 30m

Claude runs, loops, and stops when it's finished - or when time runs out.

If the terminal is closed or power is lost mid-run:

    orchclaude resume          (continue where it left off)
    orchclaude status          (show current session state)

---

## Syntax

    orchclaude run "<prompt>"  -t <timeout>  [options]
    orchclaude run -f <file>   -t <timeout>  [options]
    orchclaude resume          [-d <path>]
    orchclaude status          [-d <path>]

---

## Flags

  REQUIRED
    "prompt"        Describe what to build. Be as detailed as you want.
    -t <time>       Timeout. Number + m or h. Examples: -t 5m  -t 2h  -t 90m

  OPTIONAL
    -f <file>       Load prompt from a .md or .txt file instead of typing inline
    -i <number>     Max iterations (loops) before giving up. Default: 40
    -d <path>       Working directory - where Claude reads and writes files. Default: current folder
    -v              Verbose - print Claude's full output every iteration
    -noqa           Skip the automatic QA + edge case evaluation pass
    -token <word>   Custom word Claude must say to finish. Default: ORCHESTRATION_COMPLETE
    -cooldown <s>   Seconds to wait between iterations. Default: 5. Use 0 to disable.
    -breaker <n>    Pause and ask if Claude stalls for N iterations with no new progress.
                    Default: 10. Use 0 to disable.
    -dryrun         Print the full prompt that would be sent to Claude and exit.
                    No Claude call is made. No files are created or modified.
                    Use this to verify your prompt before committing to a long run.

  COST ESTIMATION
    After every run (completion, timeout, or circuit breaker) orchclaude prints:
      Estimated usage: ~N tokens input, ~N tokens output | Estimated cost: ~$X.XXXX (estimate only)
    Token count is estimated from word count × 1.33. Cost uses Anthropic's published
    rates: $3/M input tokens, $15/M output tokens. The estimate is also written to the
    log file. It is always labeled as an estimate, not an exact figure.

  CRASH RECOVERY
    resume          Continue an interrupted run (Ctrl+C, power loss, terminal close).
                    Reads orchclaude-session.json in the work dir and picks up from the
                    last completed iteration. Progress lines are preserved and fed back.
    status          Show iteration count, elapsed time, and last progress line for the
                    current session without resuming it.

  COMING SOON (Phase 1.3+)
    -test <cmd>     Validation command to run after each completion claim.

---

## Examples

  Quick one-liner:
    orchclaude run "Build a Python script that renames all files in a folder by date" -t 20m

  From a project spec file:
    orchclaude run -f my-project.md -t 2h

  Longer project with higher iteration cap:
    orchclaude run -f big-project.md -t 3h -i 80

  Specific working directory:
    orchclaude run "Add dark mode to the frontend" -t 45m -d "C:\Projects\MyApp"

  See what Claude is doing in real time:
    orchclaude run "Refactor the auth module" -t 30m -v

  Skip QA for a quick one-off fix:
    orchclaude run "Fix the typo in homepage" -t 10m -noqa

  Preview what will be sent to Claude without running:
    orchclaude run "Build a login form" -t 30m -dryrun
    orchclaude run -f project.md -t 2h -dryrun

  Require tests to pass before finishing (coming in Phase 1.1):
    orchclaude run "Add the login feature" -t 1h -test "npm test"
    orchclaude run -f project.md -t 2h -test "pytest"
    orchclaude run "Implement sorting" -t 30m -test "cargo test"

---

## How It Works

  PHASE 1 - BUILD
    1. Your prompt is sent to Claude Code with a strict contract:
       "Do not stop until all requirements are met. Output ORCHESTRATION_COMPLETE when done."
    2. After each iteration, PROGRESS lines Claude printed are collected and fed back
       so Claude knows exactly what it already did and picks up where it left off.
    3. Loop repeats until Claude outputs the completion token OR timeout is hit.

  PHASE 2 - QA (automatic, runs after build)
    1. Claude switches to adversarial tester mode and reads all output files.
    2. It checks for edge cases across these categories:
       - Empty, null, or missing input
       - Extremely long strings
       - Special characters and unicode
       - Rapid repeated actions / button spam
       - localStorage full or unavailable
       - Negative numbers, zero, invalid date formats
       - State left over from a previous session
       - Async failures if any fetch code exists
    3. Every issue found is fixed directly in the files (not just reported).
    4. Findings print as:  QA_FINDING: <issue and fix applied>
    5. Summary prints as:  QA_SUMMARY: <N issues found, N fixed>

  Use -noqa to skip Phase 2 entirely.

---

## Token and Cost Estimate

  At the end of every run, orchclaude prints an estimated token count and cost:

    Estimated usage: ~4200 tokens input, ~1800 tokens output | Estimated cost: ~$0.0393 (estimate only)

  This uses Anthropic's published rates for claude-sonnet-4-x:
    Input:  $3.00 per 1M tokens
    Output: $15.00 per 1M tokens

  Token count is approximated as words x 1.33 — it is a rough guide, not a billing figure.
  The estimate prints whether the run completes, times out, or hits the circuit breaker.
  It is also written to orchclaude-log.txt.

---

## Output Files

  orchclaude-log.txt       Full output from every build and QA iteration
  orchclaude-progress.txt  PROGRESS lines only - what Claude completed each step
  orchclaude-session.json  Session state (iteration, status, flags) for crash recovery

All files are created in the working directory (-d flag or current folder).

---

## Project Spec File Format

For bigger projects write your requirements in a .md file:

    # Project: My App

    ## Goal
    Build a ...

    ## Acceptance Criteria
    - [ ] Feature A works
    - [ ] Feature B works
    - [ ] Tests pass

    ## Tech Stack
    - Node.js, Express, ...

Then run:
    orchclaude run -f my-project.md -t 1h

---

## Get Help

    orchclaude help
    orchclaude --help
