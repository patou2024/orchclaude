# orchclaude — Development Roadmap

This document defines every planned feature for orchclaude in priority order.
It is the single source of truth for what gets built, in what order, and what "done" means for each item.

Each session that works on orchclaude should:
1. Read STATUS.md to find the current position
2. Read this file to understand what comes next
3. Implement the next incomplete item fully
4. Test it (see acceptance criteria below each item)
5. Update STATUS.md
6. Commit with a clear message

---

## How Phases Work

- Phases are sequential. Do not start Phase 2 until Phase 1 is fully complete and all tests pass.
- Within a phase, items are ordered by priority. Work top to bottom.
- Each item has a checkbox. Check it off in STATUS.md (not here) when done.
- Windows support must be complete and stable before any cross-platform work begins.

---

## Phase 1 — Foundation Hardening (Windows)

Goal: make the core loop reliable and honest. Right now Claude self-reports completion.
That is not good enough. Phase 1 makes completion verifiable from the outside.

---

### 1.1 — External Validation Gate (`-test` flag)

**What it is:**
A `-test "<command>"` flag that runs a shell command after each iteration.
The loop only accepts ORCHESTRATION_COMPLETE if the test command also exits with code 0.
If the test fails, Claude is re-run with the test output attached so it can fix the failure.

**Why it matters:**
This is the single most important missing feature. Claude saying it is done means nothing.
Tests passing means something.

**Implementation:**
- Add `-test` string parameter to param block
- After each iteration where ORCHESTRATION_COMPLETE is detected:
  - Run the test command via Invoke-Expression
  - Capture stdout, stderr, and exit code
  - If exit code 0: proceed to QA phase (or finish if -noqa)
  - If exit code non-zero: re-run Claude with a new section appended to the prompt:
    "## TEST FAILURE — you output ORCHESTRATION_COMPLETE but tests failed. Fix the following and try again:"
    followed by the full test output
- Log all test runs with timestamp to orchclaude-log.txt
- Print test result clearly: TEST PASSED or TEST FAILED: <output summary>

**Acceptance Criteria:**
- `orchclaude run "..." -t 30m -test "npm test"` runs npm test after each completion claim
- If tests fail, Claude is re-run with the failure output
- If tests pass, the run completes normally
- Test output is visible in the terminal and in the log file
- Works with any command: npm test, pytest, cargo test, a custom .ps1 script, etc.
- Documented in README and --help output

---

### 1.2 — Crash Recovery (Resume Interrupted Runs)

**What it is:**
If orchclaude is interrupted mid-run (terminal closed, power loss, Ctrl+C),
a `orchclaude resume` command picks up exactly where it left off using saved state.

**Why it matters:**
Right now a crashed run is a total loss. For long runs this is unacceptable.

**Implementation:**
- At the start of each run, write a session file: orchclaude-session.json in the work directory
  Contents: { startTime, prompt, flags, currentIteration, progressLines[], status: "running" }
- Update the session file after every iteration
- On completion or timeout, set status to "complete" or "timeout"
- Add `orchclaude resume` command that:
  - Reads orchclaude-session.json
  - If status is "running": prints "Interrupted session found" and resumes from saved state
  - If status is "complete": prints "Last session already completed" and exits
  - If no session file: prints "No interrupted session found"
- Add `orchclaude status` command that prints the current session file contents in readable format

**Acceptance Criteria:**
- Interrupting a run with Ctrl+C and running `orchclaude resume` continues from the right iteration
- Progress lines from before the crash are preserved and fed back to Claude
- `orchclaude status` shows iteration count, elapsed time, and last progress line
- Session file is valid JSON and human-readable
- Documented in README and --help output

---

### 1.3 — Rate Limiting and Circuit Breaker

**What it is:**
Prevents orchclaude from hammering the API when something is clearly wrong.
Adds a cooldown between iterations and a circuit breaker that pauses after repeated failures.

**Why it matters:**
If Claude enters a bad loop (keeps outputting the same wrong thing), orchclaude currently
burns through your usage limit without making progress. This stops that.

**Implementation:**
- Add `-cooldown <seconds>` flag. Default: 5 seconds between iterations (currently 2).
- Track a "failure streak" counter: increments each iteration that ends without the completion token
- Add `-breaker <number>` flag. Default: 10. If failure streak hits this number:
  - Print a warning: "CIRCUIT BREAKER: Claude has not made progress in N iterations"
  - Print the last 3 PROGRESS lines so the user can see what state it is in
  - Pause and prompt the user: "Continue? (y/n/new prompt)"
  - If y: reset the streak counter and continue
  - If n: exit cleanly
  - If new prompt: append the new text to the base prompt and continue
- Reset the failure streak whenever a new PROGRESS line is detected

**Acceptance Criteria:**
- Default 5 second cooldown between iterations
- After 10 iterations with no new PROGRESS lines, circuit breaker fires
- User is shown last known progress and asked to continue, stop, or adjust
- `-cooldown 0` disables the cooldown entirely
- `-breaker 0` disables the circuit breaker entirely
- Documented in README and --help output

---

### 1.4 — Token / Cost Estimator

**What it is:**
After each run, print an estimated token count and approximate cost.

**Why it matters:**
Right now there is no feedback on how expensive a run was. Users have no idea.

**Implementation:**
- Count words in every prompt sent and every response received
- Multiply by 1.33 to get a rough token estimate (words * 1.33 is a common approximation)
- Use Anthropic's published rates for claude-sonnet-4-x to estimate cost in USD
  Input: $3 per 1M tokens, Output: $15 per 1M tokens (update these if rates change)
- Print at the end of every run:
  "Estimated usage: ~N tokens input, ~N tokens output | Estimated cost: ~$X.XX"
- Add to log file as well
- Note clearly that it is an estimate, not an exact figure

**Acceptance Criteria:**
- Cost estimate prints at end of every run
- Estimate is clearly labeled as approximate
- Works whether the run completes, times out, or hits the circuit breaker
- Documented in README

---

### 1.5 — `--dry-run` Flag

**What it is:**
Prints the full prompt that would be sent to Claude, then exits without actually running.

**Why it matters:**
Users need to verify their prompt looks correct before committing to a long run.
Also useful for debugging the orchestration instructions being injected.

**Implementation:**
- Add `-dryrun` switch parameter
- If set: build the full prompt exactly as it would be sent, print it to terminal, exit 0
- Label it clearly: "DRY RUN - prompt that would be sent to Claude:"
- Print the prompt in full, including the injected orchestration contract
- Do not create any log or session files

**Acceptance Criteria:**
- `orchclaude run "prompt" -t 30m -dryrun` prints the full prompt and exits
- No Claude call is made
- No files are created or modified
- Output is clearly labeled as a dry run

---

### 1.6 — Usage Limit Detection and Auto-Resume

**What it is:**
Detects when a Claude Code run hits the usage/rate limit, saves state cleanly, and automatically
resumes the run after a configurable wait (default 5 hours, matching Claude's reset window).
Two modes: `-autowait` keeps the terminal open and resumes in-process; `-autoschedule` creates
a Windows Task Scheduler entry and exits so the machine can be left unattended.

**Why it matters:**
Without this, hitting the usage limit kills the run silently and the user loses their session.
This is the most disruptive real-world problem with long orchclaude builds.
With this, hitting the limit is just a pause — the build continues automatically.

**Usage limit error patterns to detect (in Claude's output):**
- "Claude AI usage limit reached"
- "rate_limit_error"
- "overloaded_error"
- "exceeded your current quota"
- "You have reached your usage limit"
- Any output containing "usage limit" (case-insensitive)

**Implementation:**

Detection:
- After each Invoke-Claude call, scan output for the above patterns
- If matched: set $usageLimitHit = $true, print warning in Red, save state

State save on limit hit:
- Write/update orchclaude-session.json with status "usage_limit_paused"
- Include: timestamp of pause, resumeAfter (now + waitSeconds), iteration number, full prompt, progress lines
- Print: "Usage limit hit at [time]. Will resume at [time+5h]."

Add flags:
- `-autowait` switch — sleep in-process and auto-resume (terminal must stay open)
- `-autoschedule` switch — create a schtasks entry and exit cleanly (terminal can close)
- `-waittime <minutes>` — override the wait duration. Default: 300 (5 hours)
- Neither flag set: save state and exit with a clear message telling the user to run `orchclaude resume`

autowait mode:
- Print a countdown every 10 minutes: "Resuming in Xh Ym..."
- After wait completes: print "Resuming now..." and continue the loop from current iteration
- If interrupted during wait: session file preserves the resumeAfter timestamp
  so `orchclaude resume` can calculate remaining wait and sleep the rest

autoschedule mode:
- Build the resume command: `powershell.exe -ExecutionPolicy Bypass -File "<path>\orchclaude.ps1" resume -d "<workDir>"`
- Run: `schtasks /create /tn "orchclaude-resume-<timestamp>" /tr "<command>" /sc once /st <HH:MM> /f`
- Where /st is current time + waittime
- Print: "Scheduled resume at [time]. Safe to close this terminal."
- Exit cleanly

`orchclaude resume` must also handle "usage_limit_paused" status:
- Check if current time >= resumeAfter
- If not yet: print "Not ready yet. Resume scheduled for [resumeAfter]. Xh Ym remaining."
- If ready: proceed with normal resume flow

**Additional requirements (added after initial spec):**

Auto-confirm prompts:
- During `-autowait` mode, any prompt Claude outputs that expects a y/n response must be
  automatically answered "y" so the run never stalls waiting for human input.
- This includes merge prompts, branch prompts, budget confirmation, and circuit breaker prompts.
- Add an internal `$unattended` flag that is automatically set to `$true` when `-autowait` or
  `-autoschedule` is active. All interactive prompts check `$unattended` and skip to "y" if set.
- Print a notice when auto-confirm fires: "AUTO: confirmed '<prompt>' (unattended mode)"

Resume state check:
- On resume after a usage-limit pause, orchclaude must re-read STATUS.md (if the work dir is
  the orchclaude repo) or re-read orchclaude-progress.txt to confirm where it left off before
  sending the next iteration. This prevents re-doing already-completed work.
- Print on resume: "Resuming from iteration N. Last progress: <last PROGRESS line>"

**Acceptance Criteria:**
- Usage limit errors are detected and do not crash the run with an unhelpful message
- `-autowait` sleeps and resumes automatically without user interaction
- `-autoschedule` creates a valid schtasks entry visible in Task Scheduler and exits
- `orchclaude resume` on a paused session correctly waits if time has not elapsed
- `-waittime 10` overrides to a 10-minute wait (useful for testing)
- State is fully preserved across the pause: prompt, progress, iteration count
- In `-autowait`/`-autoschedule` mode, all y/n prompts are auto-confirmed and logged
- On resume, iteration count and last progress line are printed before the next Claude call
- Documented in README and --help with examples

---

## Phase 2 — Planning and Intelligence

Goal: make orchclaude smarter about how it approaches tasks, not just how it loops.

---

### 2.1 — Pre-Planning Phase

**What it is:**
Before the build loop starts, run one Claude call that breaks the task into a numbered
list of subtasks with dependencies. This plan is saved and shown to Claude at the start
of each build iteration.

**Why it matters:**
Right now Claude receives a big prompt and self-organizes in its head. Making the plan
explicit and persistent means each iteration has a clear map of what to do next.
Making the plan explicit and persistent is a more reliable approach than leaving Claude to self-organize.

**Implementation:**
- Add `-plan` switch (on by default, use `-noplan` to skip)
- Planning call: send a stripped-down version of the prompt with instructions to output
  a numbered task list only. No code, no files. Just the plan.
  Format Claude must follow:
  PLAN:
  1. [task description] | depends: none
  2. [task description] | depends: 1
  3. [task description] | depends: 1,2
  etc.
- Save the plan to orchclaude-plan.txt in the work directory
- Inject the plan at the top of every subsequent build iteration prompt:
  "## PROJECT PLAN (follow this order):" followed by the saved plan
- Add a `-noplan` switch to skip this phase for simple/quick tasks

**Acceptance Criteria:**
- Planning call runs before the first build iteration
- Plan is saved to orchclaude-plan.txt
- Plan is visible in the terminal before build starts
- Each build iteration receives the plan in its prompt
- `-noplan` skips the planning phase entirely
- Documented in README

---

### 2.2 — Context Window Guard

**What it is:**
Detects when the accumulated prompt (base + progress + plan) is getting too large
and compresses the progress section before the next iteration.

**Why it matters:**
On long runs, the progress log grows and eventually the prompt hits Claude's context limit.
When that happens the run silently degrades. This prevents it.

**Implementation:**
- Estimate token count of the full prompt before each iteration (use the word * 1.33 formula)
- If estimated tokens exceed 150,000 (safe buffer below the 200k limit):
  - Print warning: "CONTEXT GUARD: prompt is getting large, compressing progress log"
  - Run a quick Claude call: "Summarize these progress notes in 10 bullet points: [progress]"
  - Replace orchclaude-progress.txt with the summary
  - Continue with the compressed version
- Log when compression happens

**Acceptance Criteria:**
- Compression triggers automatically when prompt exceeds threshold
- Compressed progress is still meaningful (not empty)
- Run continues normally after compression
- Compression event is logged

---

### 2.3 — Named Profiles

**What it is:**
Save and reuse common flag combinations under a name.

**Why it matters:**
Users who always run with the same flags (same -test command, same -d directory, same -i limit)
should not have to type them every time.

**Implementation:**
- Add `orchclaude profile save <name>` — saves current flags to a profile
- Add `orchclaude profile list` — lists saved profiles
- Add `orchclaude profile delete <name>` — removes a profile
- Add `-profile <name>` flag to `orchclaude run` — loads a saved profile's flags
  (flags on the command line override the profile)
- Profiles stored in: C:\Users\<user>\.orchclaude\profiles.json

**Acceptance Criteria:**
- Can save, list, delete, and load profiles
- Command-line flags override profile flags
- Profile file is human-readable JSON
- Error message if profile name not found

---

## Phase 3 — Safety and Isolation

Goal: make runs safe by default. No more writing directly to the working directory without a safety net.

---

### 3.1 — Git Worktree Isolation

**What it is:**
Each run creates a new git branch and worktree, operates there, and only merges back
to the original branch if the run succeeds (all tests pass, QA passes).

**Why it matters:**
Right now orchclaude writes directly to your working directory. A bad run can corrupt
your files. This is the safest way to let an AI agent modify a codebase.

**Implementation:**
- At run start, check if the work directory is a git repo (git rev-parse --git-dir)
- If it is: create a new branch named orchclaude/<timestamp> and a worktree for it
- Run the entire build and QA in the worktree
- On success: offer to merge back to the original branch (prompt user: "Merge to main? y/n")
- On failure/timeout: leave the branch for inspection, print its name
- Add `-nobranch` flag to skip this behavior and write directly (current behavior)
- If not a git repo: skip silently and write directly (warn the user)

**Acceptance Criteria:**
- Runs in a git repo create a new branch automatically
- Successful runs offer a merge back
- Failed runs leave the branch intact for inspection
- `-nobranch` disables this
- Non-git directories work exactly as before

---

### 3.2 — Auto-Commit Checkpoints

**What it is:**
After each successful iteration (new PROGRESS lines detected), automatically commit
the current state of changed files to the orchclaude branch.

**Why it matters:**
Combined with worktree isolation, this means every meaningful step is recoverable.
You can git log the orchclaude branch and see the project being built step by step.

**Implementation:**
- After each iteration that produces at least one PROGRESS line:
  - git add -A in the worktree
  - git commit -m "orchclaude checkpoint: [last PROGRESS line]"
- Only commit if files actually changed (check git status first)
- Log the commit hash

**Acceptance Criteria:**
- Each iteration with progress creates a commit
- Commit message includes the last PROGRESS line
- No empty commits (only commit when files changed)
- Commit history is clean and readable

---

## Phase 4 — Multi-Agent Execution

Goal: run multiple Claude sessions in parallel on different parts of the project.

---

### 4.1 — Parallel Agents

**What it is:**
Split a task into N independent subtasks (from the plan phase) and run them as
simultaneous Claude sessions, each in its own worktree branch.

**Why it matters:**
Independent tasks do not need to be sequential. Running them in parallel cuts total
time dramatically for large projects.

**Implementation:**
- Add `-agents <number>` flag. Default: 1 (current behavior).
- Requires Phase 2.1 (planning phase) to be complete first.
- Parse the plan for tasks with `depends: none` — these can run in parallel.
- Spawn N PowerShell jobs, each running a scoped version of the build loop.
- Each agent gets only its assigned subtask(s), its own worktree, its own log file.
- Orchestrator waits for all agents to complete, then runs a merge phase.
- Merge phase: Claude is given all agent outputs and asked to integrate them.
- Conflicts are flagged for human review.

**Acceptance Criteria:**
- `-agents 2` runs two Claude sessions in parallel on independent subtasks
- Each agent has its own log file: orchclaude-log-agent1.txt etc.
- Orchestrator waits for all agents before proceeding
- Merge phase produces a single coherent output
- Documented clearly — this is a power feature with real complexity

---

## Phase 5 — Cross-Platform

Do not start this phase until every Phase 1-4 item is complete and stable on Windows.

---

### 5.1 — Linux / macOS Port

**What it is:**
A bash/zsh equivalent of orchclaude.ps1 that provides identical functionality on Unix systems.

**Implementation:**
- Write orchclaude.sh with the same flags, same phases, same logic
- No PowerShell dependency
- Test on Ubuntu 22.04 and macOS 13+
- Add install instructions for both platforms to README

### 5.2 — Package Distribution

- Publish to npm as `orchclaude` so users can install with `npm install -g orchclaude`
- The package detects OS at install time and installs the right script
- Windows: .ps1 + .cmd wrapper
- Unix: .sh with chmod +x

---

## Phase 6 — GUI (stretch goal)

Do not start this phase until Phase 5 is complete.

### 6.1 — Status Dashboard

A single HTML file (like the pomodoro timer, no install) that reads orchclaude-session.json
and orchclaude-log.txt and displays live run status, progress, and history.

### 6.2 — Log Viewer

Renders the log file with color coding: PROGRESS lines green, QA_FINDING lines yellow,
errors red. Makes long runs easy to review.

---

## Phase 7 — Smart Model Mode

Goal: automatically route each part of a run to the right Claude model based on what the task actually needs.
Not every iteration requires the most powerful and expensive model. This phase makes orchclaude cost-aware and intelligent about model selection.

---

### 7.1 — Task Classifier

**What it is:**
Before each Claude call, run a lightweight classification step that reads the current task
and decides which model tier is appropriate: light, standard, or heavy.

**Why it matters:**
A planning call, a progress check, or a simple file write does not need Opus.
Routing cheap work to Haiku and expensive reasoning to Opus can cut run costs dramatically
without affecting output quality.

**Classification tiers:**

  LIGHT (use claude-haiku-4-5)
  - Reading files and summarizing what exists
  - Generating a task plan or outline
  - Progress compression (context window guard)
  - QA finding summaries
  - Simple file writes with no logic (README, config files, plain text)

  STANDARD (use claude-sonnet-4-6)
  - General feature implementation
  - Most build iterations
  - QA edge case evaluation and fixes
  - Moderate reasoning tasks

  HEAVY (use claude-opus-4-6)
  - Architecture decisions
  - Complex debugging across multiple files
  - Security-sensitive code
  - First iteration of a completely new project (needs the strongest understanding)
  - Any iteration where the previous iteration failed the -test validation gate

**Implementation:**
- Add a classifier prompt that receives the current task description and outputs one of: LIGHT / STANDARD / HEAVY
- Map each tier to a model ID
- Pass the selected model to the claude call via --model flag
- Print the selected tier at the start of each iteration: MODEL: haiku / sonnet / opus
- Add `-model <tier>` flag to override: light, standard, heavy, or a raw model ID
- Log model used per iteration in orchclaude-log.txt

---

### 7.2 — Adaptive Escalation

**What it is:**
Automatically escalate the model tier when an iteration fails to make progress.

**Why it matters:**
If two iterations in a row produce no new PROGRESS lines, the task may be too complex
for the current model. Escalating to a stronger model often unblocks it.

**Rules:**
- 2 consecutive iterations with no new PROGRESS lines on LIGHT: escalate to STANDARD
- 2 consecutive iterations with no new PROGRESS lines on STANDARD: escalate to HEAVY
- Once escalated, do not de-escalate within the same run
- Log escalation events: ESCALATED: haiku -> sonnet (no progress after 2 iterations)

---

### 7.3 — Cost-Aware Budget Mode

**What it is:**
Extends the cost estimator from Phase 1.4 to actively gate the run.
If estimated spend exceeds a `-budget` threshold, pause and ask the user before continuing.

**Flags:**
- `-budget <amount>` — e.g. `-budget 0.50` for 50 cents
- When estimated cost exceeds the budget, print a warning and prompt: "Continue? (y/n)"
- If y: double the budget and continue
- If n: exit cleanly with a summary of what was completed

---

### 7.4 — Model Profile Presets

**What it is:**
Named model strategies the user can apply with a single flag.

  -modelprofile fast      All iterations use Haiku. Fastest and cheapest. Good for simple tasks.
  -modelprofile balanced  Smart routing (7.1 classifier). Default when Phase 7 is enabled.
  -modelprofile quality   All iterations use Opus. Slowest and most expensive. Best output.
  -modelprofile auto      Adaptive (7.1 + 7.2 escalation). Starts cheap, escalates when stuck.

---

## Phase 8 — Run History

Goal: give users a persistent record of every orchclaude run so they can review what was built,
how long it took, how much it cost, and whether it succeeded.

---

### 8.1 — Run History Log (`orchclaude history`)

**What it is:**
After every run (complete, timeout, or failed), append a summary entry to a persistent history
file at `~/.orchclaude/history.json`. A new `orchclaude history` command displays the log in a
clean, readable format.

**Why it matters:**
Right now every run disappears from memory the moment the terminal closes. Users have no way to
review what was built last week, compare run durations, or audit cost across a project. A history
log makes orchclaude a proper tool with an audit trail.

**Implementation:**

History file location: `~/.orchclaude/history.json`
Each entry is a JSON object appended to an array:
```json
{
  "id": "<timestamp-based unique ID>",
  "date": "<ISO 8601 datetime>",
  "workDir": "<absolute path>",
  "promptExcerpt": "<first 120 chars of prompt>",
  "status": "complete | timeout | failed | usage_limit_paused",
  "iterations": 7,
  "durationMinutes": 4.2,
  "estimatedCostUSD": 0.03,
  "progressCount": 5,
  "lastProgress": "<last PROGRESS line or empty string>"
}
```

Write the history entry:
- Call a `Write-History` function at every exit point where a run ends (same places `Send-Webhook` is called).
- The function reads the existing history array, appends the new entry, and writes it back.
- Cap the history at 200 entries (drop oldest if over limit).
- Errors in history writing must be non-fatal (catch and warn, never crash the run).

`orchclaude history` command:
- Reads `~/.orchclaude/history.json`.
- Displays the last 20 entries by default, newest first.
- Each entry shows: index, date, status (color-coded), workDir (truncated to 40 chars), duration, cost, iterations, prompt excerpt.
- `-n <number>` flag shows more entries (e.g. `orchclaude history -n 50`).
- `orchclaude history clear` subcommand wipes the history file after confirmation.
- If history file does not exist: print "No history yet. History is recorded after each run."

Display format (one line per run):
```
  #1  2026-04-20 14:32  COMPLETE    ~/projects/myapp          4.2m  $0.03  7 iters  "Create a REST API..."
  #2  2026-04-20 11:15  TIMEOUT     ~/projects/myapp          30.0m $0.18  40 iters "Build a full..."
  #3  2026-04-19 22:04  COMPLETE    C:\Users\pana5\orchclaude  1.1m  $0.01  3 iters  "Add a flag..."
```

**Acceptance Criteria:**
- Every run completion writes a history entry (complete, timeout, failed, usage_limit_paused)
- `orchclaude history` displays entries newest-first with status color coding
- `orchclaude history -n 50` shows up to 50 entries
- `orchclaude history clear` wipes the history after a "Are you sure? (y/n)" confirmation
- If history file is missing or empty, a friendly message is shown (no error)
- History write errors do not crash or interrupt the run
- Documented in README and --help output

---

## Phase 9 — Advanced Metrics and Observability

Goal: give users deep insights into run performance, cost breakdown by iteration, and historical trends.
This phase transforms raw history data into actionable insights.

---

### 9.1 — Per-Iteration Performance Metrics

**What it is:**
Track detailed metrics for every iteration: elapsed time, input/output tokens, estimated cost,
success/failure status. Save these metrics to a per-run file and aggregate them in history.

**Why it matters:**
Users need to understand where time and money are being spent. Which iterations are expensive?
Which ones made progress? This data helps optimize future runs.

**Implementation:**

Metrics per iteration:
- `iterationNumber`: numeric index (1, 2, 3...)
- `modelUsed`: the model tier/ID used (haiku, sonnet, opus, or specific model ID)
- `startTime`: ISO 8601 timestamp when iteration started
- `elapsedSeconds`: wall-clock time from start to Claude response received
- `inputTokens`: estimated input tokens sent to Claude
- `outputTokens`: estimated output tokens received from Claude
- `estimatedCostUSD`: cost for this iteration alone
- `hadProgress`: boolean (true if PROGRESS lines were detected)
- `progressLines`: array of PROGRESS strings detected in output
- `status`: "success" | "retry" | "failed" | "escalated"

Metrics file: `orchclaude-metrics.json` (per run, in work directory)
Format: JSON array of iteration objects, newest-first on append.

Capture metrics:
- Start time: before Invoke-Claude call
- Elapsed: difference between Claude response received and start time
- Tokens: from existing cost estimator (word * 1.33)
- Cost: use existing rate calculation
- Progress: scan output for new PROGRESS lines
- Model: from current iteration's model selection
- Status: derive from whether run continues, escalates, fails, etc.

Integration points:
- Call `Write-Metrics` at each iteration completion (after all logs are written)
- `Write-Metrics` appends the iteration record to `orchclaude-metrics.json`
- Make it non-fatal: catch errors and warn but do not crash
- Also append a metrics line to `orchclaude-log.txt` for readability:
  `[METRICS] Iter 3: opus | 18s elapsed | 2400→512 tokens | $0.018 | 3 PROGRESS lines`

History integration:
- When writing a history entry (in Write-History), calculate:
  - Average tokens per iteration (from metrics file)
  - Average cost per iteration
  - Average elapsed per iteration
  - Iteration with highest cost
  - Total success/failure breakdown by model
- Add these summary fields to the history entry:
  - `avgTokensPerIter`: rounded to nearest 100
  - `avgCostPerIter`: rounded to nearest $0.001
  - `avgElapsedPerIter`: seconds
  - `fastestIter` / `slowestIter`: iteration numbers
  - `mostExpensiveIter`: iteration number

Dashboard/display:
- `orchclaude metrics [-d <path>]` command: reads `orchclaude-metrics.json` and displays:
  - Table format: iter | model | elapsed | tokens | cost | progress | status
  - Summary at bottom: total time, total cost, avg per iter, success rate
  - Example:
    ```
    Iteration Metrics for /path/to/work:
    
    Iter  Model    Elapsed  Input   Output  Cost    Progress  Status
    ----  -------  -------  ------  ------  ------  --------  ---------
    1     sonnet   12.5s    1200    680     $0.013  1 line    success
    2     sonnet   8.2s     950     420     $0.009  2 lines   success
    3     opus     22.1s    2100    1200    $0.045  1 line    escalated
    4     opus     15.3s    1800    950     $0.038  2 lines   success
    
    Summary: 58.1s total, $0.105 total, 3 iters with progress, 1 escalation
    ```

**Acceptance Criteria:**
- Every iteration writes metrics to `orchclaude-metrics.json`
- Metrics file is valid JSON and human-readable
- `orchclaude metrics` displays iteration table with color coding
- History entries include aggregated metrics (avg tokens, avg cost, etc.)
- Metrics errors never crash a run (caught and warned)
- Metrics work on both Windows (PS1) and Unix (SH)
- Documented in README and --help

---

## Feature Backlog (unscheduled)

These are ideas with no phase assigned yet. They get promoted to a phase when the time is right.

- `orchclaude analytics` — visualize trends over historical runs (cost over time, success rate, etc.)
- `orchclaude compare <run1> <run2>` — compare metrics and outcomes between two runs
- Custom exit handlers — let users run cleanup scripts after runs complete
- Slack thread notifications — reply in Slack threads for better conversation threading
- Model cost estimator hints — let users test prompts on cheaper models before committing to full run
