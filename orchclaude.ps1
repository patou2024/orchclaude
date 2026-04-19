# orchclaude - Claude Code Orchestrator CLI
# Usage: orchclaude run "prompt" -t30m
#        orchclaude run -f project.md -t2h
#        orchclaude run "prompt" -t1h -i 60 -v -d "C:\Projects\MyApp"
#        orchclaude resume          (continue an interrupted run)
#        orchclaude status          (show current session state)

param(
    [Parameter(Position=0)]
    [string]$Command = "run",

    [Parameter(Position=1)]
    [string]$Prompt = "",

    [switch]$help,            # --help or -help

    [string]$f = "",          # -f <file>      : load prompt from file
    [string]$t = "30m",       # -t <time>      : timeout e.g. 5m, 2h (default 30m)
    [int]$i = 40,             # -i <number>    : max iterations (default 40)
    [switch]$v,               # -v             : verbose - show full Claude output
    [string]$d = "",          # -d <path>      : working directory (default: current)
    [switch]$noqa,            # -noqa          : skip QA pass
    [string]$token = "ORCHESTRATION_COMPLETE", # custom completion token
    [int]$cooldown = 5,       # -cooldown <s>  : seconds between iterations (default 5, 0=off)
    [int]$breaker = 10,       # -breaker <n>   : circuit breaker after N stalled iterations (default 10, 0=off)
    [switch]$dryrun,           # -dryrun        : print the prompt that would be sent and exit (no Claude call, no files)
    [switch]$noplan            # -noplan        : skip pre-planning phase
)

# ---- Help ----
if ($Command -eq "help" -or $Command -eq "-h" -or $help) {
    $guideFile = "C:\Users\pana5\ORCHCLAUDE-GUIDE.md"
    if (Test-Path $guideFile) {
        Get-Content $guideFile | ForEach-Object { Write-Host $_ }
    } else {
        Write-Host "Guide file not found at $guideFile" -ForegroundColor Red
        Write-Host "Quick reference:" -ForegroundColor Cyan
        Write-Host "  orchclaude run `"prompt`" -t 30m"
        Write-Host "  orchclaude run -f project.md -t 2h"
        Write-Host "  orchclaude resume              (continue interrupted run)"
        Write-Host "  orchclaude status              (show session state)"
        Write-Host "  Flags: -t -i -f -d -v -noqa -token -cooldown -breaker -dryrun -noplan"
    }
    exit 0
}

# ---- Status command ----
if ($Command -eq "status") {
    $workDir    = if ($d) { $d } else { (Get-Location).Path }
    $sessionFile = Join-Path $workDir "orchclaude-session.json"

    if (-not (Test-Path $sessionFile)) {
        Write-Host "No session file found in $workDir" -ForegroundColor Yellow
        exit 0
    }

    $session = Get-Content $sessionFile -Raw | ConvertFrom-Json

    $elapsed = [math]::Round(((Get-Date) - [datetime]$session.startTime).TotalMinutes, 1)
    $lastProgress = if ($session.progressLines.Count -gt 0) { $session.progressLines[-1] } else { "(none)" }
    $statusColor  = switch ($session.status) {
        "running"  { "Yellow" }
        "complete" { "Green"  }
        "timeout"  { "Red"    }
        default    { "White"  }
    }

    Write-Host ""
    Write-Host "orchclaude session status" -ForegroundColor Cyan
    Write-Host ("-" * 40)
    Write-Host ("Status        : " + $session.status)   -ForegroundColor $statusColor
    Write-Host "Started       : $($session.startTime)"
    Write-Host "Last updated  : $($session.lastUpdated)"
    Write-Host "Iteration     : $($session.currentIteration) / $($session.flags.i)"
    Write-Host "Elapsed total : ${elapsed}m"
    Write-Host "Last progress : $lastProgress"
    Write-Host ""
    exit 0
}

# ---- Resume command ----
$resumeMode = $false
$startIter  = 1
$savedProgressLines = @()

if ($Command -eq "resume") {
    $workDir     = if ($d) { $d } else { (Get-Location).Path }
    $sessionFile  = Join-Path $workDir "orchclaude-session.json"

    if (-not (Test-Path $sessionFile)) {
        Write-Host "No interrupted session found in $workDir" -ForegroundColor Yellow
        exit 0
    }

    $session = Get-Content $sessionFile -Raw | ConvertFrom-Json

    if ($session.status -eq "complete") {
        Write-Host "Last session already completed." -ForegroundColor Green
        exit 0
    }

    Write-Host "Interrupted session found (status: $($session.status)). Resuming from iteration $($session.currentIteration + 1)..." -ForegroundColor Cyan

    # Restore all flags from saved session
    $basePrompt  = $session.prompt
    $t           = $session.flags.t
    $i           = $session.flags.i
    $noqa        = [bool]$session.flags.noqa
    $token       = $session.flags.token
    $v           = [bool]$session.flags.v
    $cooldown    = [int]$session.flags.cooldown
    $breaker     = [int]$session.flags.breaker
    $startIter   = $session.currentIteration + 1
    $savedProgressLines = $session.progressLines

    $resumeMode = $true
}

# ---- Require "run" for non-resume/resume/status/help ----
if (-not $resumeMode -and $Command -ne "run") {
    Write-Error "Unknown command '$Command'. Use: orchclaude run, orchclaude resume, orchclaude status, orchclaude help"
    exit 1
}

# ---- Parse timeout ----
$timeoutSeconds = 1800  # default 30m
if ($t -match "^(\d+)(m|h)$") {
    $num = [int]$Matches[1]
    if ($num -eq 0) { Write-Error "Bad -t value '$t'. Timeout must be greater than zero."; exit 1 }
    if ($Matches[2] -eq "m") { $timeoutSeconds = $num * 60 }
    else                      { $timeoutSeconds = $num * 3600 }
} else {
    Write-Error "Bad -t value '$t'. Use format like: 5m or 2h"
    exit 1
}

# ---- Load prompt (only for fresh run) ----
if (-not $resumeMode) {
    $basePrompt = ""
    if ($f) {
        if (-not (Test-Path $f)) { Write-Error "File not found: $f"; exit 1 }
        $basePrompt = (Get-Content $f -Raw).Trim()
        if (-not $basePrompt) { Write-Error "File '$f' is empty. Provide a prompt file with content."; exit 1 }
    } elseif ($Prompt) {
        $basePrompt = $Prompt
    } else {
        Write-Error "Provide a prompt: orchclaude run `"your prompt`" or use -f file.md"
        exit 1
    }
}

# ---- Validate max iterations ----
if ($i -le 0) {
    Write-Error "Bad -i value '$i'. Must be a positive integer."
    exit 1
}

# ---- Working directory ----
$workDir = if ($d) { $d } else { (Get-Location).Path }
if (-not (Test-Path $workDir)) { Write-Error "Directory not found: $workDir"; exit 1 }

# ---- Setup ----
$logFile      = Join-Path $workDir "orchclaude-log.txt"
$progressFile = Join-Path $workDir "orchclaude-progress.txt"
$sessionFile  = Join-Path $workDir "orchclaude-session.json"
$planFile     = Join-Path $workDir "orchclaude-plan.txt"

if ($resumeMode) {
    # Restore progress file from session
    if ($savedProgressLines.Count -gt 0) {
        $savedProgressLines | Set-Content $progressFile -Encoding UTF8
    } else {
        "" | Set-Content $progressFile
    }
} elseif (-not $dryrun) {
    try {
        "" | Set-Content $progressFile -ErrorAction Stop
    } catch {
        Write-Error "Cannot write to working directory '$workDir': $_"
        exit 1
    }
}

$startTime      = Get-Date
$timeoutDisplay = $t

$totalInputWords  = 0
$totalOutputWords = 0

# ---- Session file helpers ----
function Write-Session($status, $currentIteration) {
    $progressLines = if (Test-Path $progressFile) {
        @(Get-Content $progressFile | Where-Object { $_ -match "\S" })
    } else { @() }

    $sessionData = [ordered]@{
        startTime        = $startTime.ToString("o")
        lastUpdated      = (Get-Date).ToString("o")
        status           = $status
        currentIteration = $currentIteration
        prompt           = $basePrompt
        flags            = [ordered]@{
            t        = $t
            i        = $i
            noqa     = [bool]$noqa
            token    = $token
            v        = [bool]$v
            cooldown = $cooldown
            breaker  = $breaker
        }
        progressLines    = $progressLines
    }

    $sessionData | ConvertTo-Json -Depth 5 | Set-Content $sessionFile -Encoding UTF8
}

$orchestrationInstructions = @"

---
## ORCHESTRATION CONTRACT (non-negotiable)
1. Do NOT stop early. You will be re-run until you output the completion token.
2. Read existing files before writing - you may have done parts already.
3. Make real file changes using your tools (Edit, Write, Bash).
4. After each major step print: PROGRESS: <what you just completed>
5. When ALL requirements are done, output exactly this on its own line:
   $token
---
"@

# ---- Dry run ----
if ($dryrun) {
    $dryPrompt = $basePrompt + "`n" + $orchestrationInstructions
    Write-Host ""
    Write-Host "DRY RUN - prompt that would be sent to Claude:" -ForegroundColor Cyan
    Write-Host ("=" * 55) -ForegroundColor Cyan
    Write-Host $dryPrompt
    Write-Host ("=" * 55) -ForegroundColor Cyan
    Write-Host ""
    Write-Host "No Claude call made. No files created or modified." -ForegroundColor DarkGray
    exit 0
}

$qaToken = "QA_COMPLETE"

function Write-Log($msg, $color="White") {
    $ts   = (Get-Date).ToString("HH:mm:ss")
    $line = "[$ts] $msg"
    Write-Host $line -ForegroundColor $color
    Add-Content $logFile $line
}

function Write-Banner($text, $color="Cyan") {
    Write-Host ""
    Write-Host ("=" * 55) -ForegroundColor $color
    Write-Host "  $text" -ForegroundColor $color
    Write-Host ("=" * 55) -ForegroundColor $color
    Write-Host ""
}

function Get-WordCount($text) {
    if (-not $text) { return 0 }
    return ($text -split '\s+' | Where-Object { $_ -ne '' }).Count
}

function Show-CostEstimate {
    $inputTokens  = [math]::Round($totalInputWords  * 1.33)
    $outputTokens = [math]::Round($totalOutputWords * 1.33)
    $inputCost    = [math]::Round($inputTokens  / 1000000 * 3,  4)
    $outputCost   = [math]::Round($outputTokens / 1000000 * 15, 4)
    $totalCost    = [math]::Round($inputCost + $outputCost, 4)
    $line = "Estimated usage: ~$inputTokens tokens input, ~$outputTokens tokens output | Estimated cost: ~`$$totalCost (estimate only)"
    Write-Log $line "Cyan"
}

function Invoke-Claude($prompt, $iterLabel) {
    $promptFile = Join-Path $env:TEMP "orchclaude_prompt_${PID}_$iterLabel.txt"
    $prompt | Set-Content $promptFile -Encoding UTF8

    try {
        $output = & claude `
            -p (Get-Content $promptFile -Raw) `
            --allowedTools "Edit,Bash,Read,Write,Glob,Grep" `
            --max-turns 50 `
            2>&1
    } catch [System.Management.Automation.CommandNotFoundException] {
        Write-Error "'claude' command not found. Is Claude Code installed and in your PATH?"
        Remove-Item $promptFile -ErrorAction SilentlyContinue
        exit 1
    }

    Remove-Item $promptFile -ErrorAction SilentlyContinue
    return $output
}

# ---- Banner ----
Write-Banner "orchclaude$(if ($resumeMode) { ' [RESUME]' })"
Write-Log "Timeout   : $timeoutDisplay  ($timeoutSeconds s)" "Cyan"
Write-Log "Max iters : $i" "Cyan"
Write-Log "Work dir  : $workDir" "Cyan"
Write-Log "QA pass   : $(if ($noqa) { 'disabled (-noqa)' } else { 'enabled' })" "Cyan"
Write-Log "Cooldown  : $(if ($cooldown -eq 0) { 'disabled (-cooldown 0)' } else { "${cooldown}s between iterations" })" "Cyan"
Write-Log "Breaker   : $(if ($breaker -eq 0) { 'disabled (-breaker 0)' } else { "fires after ${breaker} stalled iterations" })" "Cyan"
Write-Log "Planning  : $(if ($noplan) { 'disabled (-noplan)' } else { 'enabled (use -noplan to skip)' })" "Cyan"
Write-Log "Log       : $logFile" "Cyan"
if ($resumeMode) {
    Write-Log "Resuming  : starting at iteration $startIter" "Cyan"
}

# ---- Write initial session (status: running) ----
Write-Session "running" ($startIter - 1)

# ================================================================
# PLANNING PHASE
# ================================================================
if (-not $noplan -and -not $resumeMode) {
    Write-Banner "PLANNING PHASE" "Blue"
    Write-Log "Running pre-planning call..." "Blue"

    $planningPrompt = @"
## PLANNING PHASE

Break the following task into a numbered list of subtasks with dependencies.
Output ONLY the plan in the exact format below. No code, no files, no preamble, no explanations.

Format (strict):
PLAN:
1. [task description] | depends: none
2. [task description] | depends: 1
3. [task description] | depends: 1,2

Task:
$basePrompt
"@

    $totalInputWords += Get-WordCount $planningPrompt
    $planOutput = Invoke-Claude $planningPrompt "plan"
    $totalOutputWords += Get-WordCount $planOutput

    # Extract from PLAN: onwards if Claude added preamble
    $planContent = $planOutput
    if ($planOutput -match "(?s)(PLAN:.*)")  {
        $planContent = $Matches[1].Trim()
    }

    $planContent | Set-Content $planFile -Encoding UTF8
    Add-Content $logFile "--- Planning phase ---"
    Add-Content $logFile $planContent
    Add-Content $logFile ""

    Write-Host ""
    Write-Host "PROJECT PLAN:" -ForegroundColor Blue
    Write-Host ("-" * 55) -ForegroundColor Blue
    ($planContent -split "`n") | ForEach-Object { Write-Host "  $_" -ForegroundColor White }
    Write-Host ("-" * 55) -ForegroundColor Blue
    Write-Host ""
    Write-Log "Plan saved to: $planFile" "Blue"
} elseif ($resumeMode -and (Test-Path $planFile)) {
    Write-Log "Planning  : using saved plan from previous session ($planFile)" "Blue"
} elseif ($noplan) {
    Write-Log "Planning phase skipped (-noplan)." "DarkGray"
}

# ================================================================
# PHASE 1 - BUILD
# ================================================================
Write-Banner "PHASE 1 - BUILD" "Yellow"

$completed = $false
$failureStreak = 0

for ($iter = $startIter; $iter -le $i; $iter++) {

    $elapsed = ((Get-Date) - $startTime).TotalSeconds
    if ($elapsed -ge $timeoutSeconds) {
        Write-Banner "TIMEOUT in build phase after $([math]::Round($elapsed/60,1)) min" "Red"
        Write-Session "timeout" $iter
        Show-CostEstimate
        break
    }

    $remaining = [math]::Round(($timeoutSeconds - $elapsed) / 60, 1)
    Write-Banner "Build iteration $iter / $i  -  ${remaining}m left" "Yellow"

    $priorProgress = if (Test-Path $progressFile) { (Get-Content $progressFile -Raw).Trim() } else { "" }
    $progressCountBefore = if (Test-Path $progressFile) {
        @(Get-Content $progressFile | Where-Object { $_ -match "\S" }).Count
    } else { 0 }

    $savedPlan = if (Test-Path $planFile) { (Get-Content $planFile -Raw).Trim() } else { "" }
    $planSection = if ($savedPlan) { "## PROJECT PLAN (follow this order):`n$savedPlan`n`n" } else { "" }

    $fullPrompt = if ($priorProgress) {
@"
${planSection}$basePrompt
$orchestrationInstructions

## PRIOR PROGRESS (completed in earlier iterations - do not redo):
$priorProgress

Continue from where you left off. Output $token when everything is done.
"@
    } else {
        "${planSection}${basePrompt}`n${orchestrationInstructions}"
    }

    Write-Log "Calling Claude (build)..." "Yellow"
    $totalInputWords += Get-WordCount $fullPrompt
    $output = Invoke-Claude $fullPrompt "build_$iter"
    $totalOutputWords += Get-WordCount $output

    if ($v) { Write-Host $output }

    ($output -split "`n") | Where-Object { $_ -match "^PROGRESS:" } | ForEach-Object {
        Add-Content $progressFile $_
        Write-Log $_ "Green"
    }

    Add-Content $logFile "--- Build iteration $iter ---"
    Add-Content $logFile $output
    Add-Content $logFile ""

    # Track failure streak (resets when new PROGRESS lines appear)
    $progressCountAfter = if (Test-Path $progressFile) {
        @(Get-Content $progressFile | Where-Object { $_ -match "\S" }).Count
    } else { 0 }

    if ($progressCountAfter -gt $progressCountBefore) {
        $failureStreak = 0
    } else {
        $failureStreak++
    }

    # Update session file after every iteration
    Write-Session "running" $iter

    if ($output -match [regex]::Escape($token)) {
        $buildTime = ((Get-Date) - $startTime).ToString("mm\:ss")
        Write-Banner "Build complete - $iter iteration(s)  |  $buildTime elapsed" "Green"
        $completed = $true
        break
    }

    # Circuit breaker
    if ($breaker -gt 0 -and $failureStreak -ge $breaker) {
        Write-Banner "CIRCUIT BREAKER: Claude has not made progress in $failureStreak iterations" "Red"

        $allProgress = if (Test-Path $progressFile) {
            @(Get-Content $progressFile | Where-Object { $_ -match "\S" })
        } else { @() }

        Write-Host "Last known progress:" -ForegroundColor Yellow
        $last3 = $allProgress | Select-Object -Last 3
        if ($last3.Count -eq 0) {
            Write-Host "  (no progress lines logged yet)" -ForegroundColor DarkGray
        } else {
            $last3 | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
        }
        Write-Host ""

        $userChoice = Read-Host "Continue? (y/n/new prompt)"

        if ($userChoice -eq "n") {
            Write-Log "User stopped run at circuit breaker." "Red"
            Write-Session "timeout" $iter
            Show-CostEstimate
            exit 1
        } elseif ($userChoice -eq "" -or $userChoice -eq "y") {
            Write-Log "User chose to continue. Resetting failure streak." "Cyan"
            $failureStreak = 0
        } else {
            $basePrompt = $basePrompt + "`n`n## Additional instruction from user:`n" + $userChoice
            Write-Log "User added prompt: $userChoice" "Cyan"
            $failureStreak = 0
        }
    }

    Write-Log "Token not found. Looping..." "Magenta"
    if ($cooldown -gt 0) { Start-Sleep -Seconds $cooldown }
}

if (-not $completed) {
    Write-Session "timeout" $i
    Write-Banner "BUILD INCOMPLETE - did not finish. See log: $logFile" "Red"
    Show-CostEstimate
    Write-Host "  Run 'orchclaude resume' to continue this session." -ForegroundColor Yellow
    exit 1
}

# ================================================================
# PHASE 2 - QA
# ================================================================
if ($noqa) {
    Write-Banner "QA skipped (-noqa flag)" "DarkGray"
} else {
    Write-Banner "PHASE 2 - QA + EDGE CASE EVALUATION" "Magenta"

    $elapsed = ((Get-Date) - $startTime).TotalSeconds
    if ($elapsed -ge $timeoutSeconds) {
        Write-Session "timeout" $i
        Write-Banner "TIMEOUT before QA phase could run" "Red"
        Show-CostEstimate
        exit 1
    }

    $remaining = [math]::Round(($timeoutSeconds - $elapsed) / 60, 1)
    Write-Log "Running QA pass...  ${remaining}m remaining" "Magenta"

    $qaPrompt = @"
## QA PHASE - Error Cases and Edge Case Evaluation

The build phase is complete. Working directory: $workDir

Your job now is to act as a QA engineer and adversarial tester.

### What to do:
1. Read every output file that was just produced in: $workDir
2. Think through error cases and edge cases - things a normal user or bad input could trigger.
3. For EACH issue found: fix it directly in the file(s). Do not just report - fix.
4. Print each finding as: QA_FINDING: <description of issue and fix applied>

### Edge case categories to check (apply what is relevant to the project):
- Empty input / no input at all
- Extremely long input (performance, overflow, truncation)
- Special characters, unicode, emojis in text fields
- Rapid repeated actions (double-click, spam)
- localStorage full or unavailable
- Browser back/forward navigation mid-flow
- Missing or deleted elements (DOM manipulation)
- Negative numbers, zero, non-numeric input where numbers expected
- Dates in the past, far future, invalid formats
- Network-style failures if any fetch/async code exists
- State left over from a previous session loading incorrectly

### When done:
- Summarize all findings in one block: QA_SUMMARY: <n issues found, n fixed>
- Output exactly this on its own line:
  $qaToken
"@

    $totalInputWords += Get-WordCount $qaPrompt
    $output = Invoke-Claude $qaPrompt "qa"
    $totalOutputWords += Get-WordCount $output

    if ($v) { Write-Host $output }

    ($output -split "`n") | Where-Object { $_ -match "^QA_FINDING:" } | ForEach-Object {
        Write-Log $_ "DarkYellow"
    }

    ($output -split "`n") | Where-Object { $_ -match "^QA_SUMMARY:" } | ForEach-Object {
        Write-Log $_ "Cyan"
    }

    Add-Content $logFile "--- QA pass ---"
    Add-Content $logFile $output
    Add-Content $logFile ""

    if ($output -match [regex]::Escape($qaToken)) {
        Write-Log "QA pass complete." "Green"
    } else {
        Write-Log "QA pass did not output $qaToken - check log for details." "Red"
    }
}

# ================================================================
# DONE
# ================================================================
Write-Session "complete" $i
$totalTime = ((Get-Date) - $startTime).ToString("mm\:ss")
Show-CostEstimate
Write-Banner "ALL DONE  |  $totalTime total" "Green"
