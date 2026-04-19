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

---

## Syntax

    orchclaude run "<prompt>"  -t <timeout>  [options]
    orchclaude run -f <file>   -t <timeout>  [options]

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

## Output Files

  orchclaude-log.txt       Full output from every build and QA iteration
  orchclaude-progress.txt  PROGRESS lines only - what Claude completed each step

Both files are created in the working directory (-d flag or current folder).

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
