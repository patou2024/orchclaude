# orchclaude - Claude Code Orchestrator CLI
# Usage: orchclaude run "prompt" -t30m
#        orchclaude run -f project.md -t2h
#        orchclaude run "prompt" -t1h -i 60 -v -d "C:\Projects\MyApp"

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
    [string]$token = "ORCHESTRATION_COMPLETE"  # custom completion token
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
        Write-Host "  Flags: -t -i -f -d -v -noqa -token"
    }
    exit 0
}

if ($Command -ne "run") {
    Write-Error "Unknown command '$Command'. Use: orchclaude run ... or orchclaude help"
    exit 1
}

# ---- Parse timeout ----
$timeoutSeconds = 1800  # default 30m
if ($t -match "^(\d+)(m|h)$") {
    $num = [int]$Matches[1]
    if ($Matches[2] -eq "m") { $timeoutSeconds = $num * 60 }
    else                      { $timeoutSeconds = $num * 3600 }
} else {
    Write-Error "Bad -t value '$t'. Use format like: 5m or 2h"
    exit 1
}

# ---- Load prompt ----
$basePrompt = ""
if ($f) {
    if (-not (Test-Path $f)) { Write-Error "File not found: $f"; exit 1 }
    $basePrompt = Get-Content $f -Raw
} elseif ($Prompt) {
    $basePrompt = $Prompt
} else {
    Write-Error "Provide a prompt: orchclaude run `"your prompt`" or use -f file.md"
    exit 1
}

# ---- Working directory ----
$workDir = if ($d) { $d } else { (Get-Location).Path }
if (-not (Test-Path $workDir)) { Write-Error "Directory not found: $workDir"; exit 1 }

# ---- Setup ----
$logFile      = Join-Path $workDir "orchclaude-log.txt"
$progressFile = Join-Path $workDir "orchclaude-progress.txt"
"" | Set-Content $progressFile
$startTime = Get-Date
$timeoutDisplay = $t

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

$qaToken = "QA_COMPLETE"

$qaPrompt = @"
## QA PHASE - Error Cases and Edge Case Evaluation

The build phase is complete. Your job now is to act as a QA engineer and adversarial tester.

### What to do:
1. Read every output file that was just produced.
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

function Invoke-Claude($prompt, $iterLabel) {
    $promptFile = Join-Path $env:TEMP "orchclaude_prompt_$iterLabel.txt"
    $prompt | Set-Content $promptFile -Encoding UTF8

    $output = & claude `
        -p (Get-Content $promptFile -Raw) `
        --allowedTools "Edit,Bash,Read,Write,Glob,Grep" `
        --max-turns 50 `
        2>&1

    Remove-Item $promptFile -ErrorAction SilentlyContinue
    return $output
}

# ---- Banner ----
Write-Banner "orchclaude"
Write-Log "Timeout   : $timeoutDisplay  ($timeoutSeconds s)" "Cyan"
Write-Log "Max iters : $i" "Cyan"
Write-Log "Work dir  : $workDir" "Cyan"
Write-Log "QA pass   : $(if ($noqa) { 'disabled (-noqa)' } else { 'enabled' })" "Cyan"
Write-Log "Log       : $logFile" "Cyan"

# ================================================================
# PHASE 1 - BUILD
# ================================================================
Write-Banner "PHASE 1 - BUILD" "Yellow"

$completed = $false

for ($iter = 1; $iter -le $i; $iter++) {

    $elapsed = ((Get-Date) - $startTime).TotalSeconds
    if ($elapsed -ge $timeoutSeconds) {
        Write-Banner "TIMEOUT in build phase after $([math]::Round($elapsed/60,1)) min" "Red"
        break
    }

    $remaining = [math]::Round(($timeoutSeconds - $elapsed) / 60, 1)
    Write-Banner "Build iteration $iter / $i  -  ${remaining}m left" "Yellow"

    $priorProgress = if (Test-Path $progressFile) { (Get-Content $progressFile -Raw).Trim() } else { "" }

    $fullPrompt = if ($priorProgress) {
@"
$basePrompt
$orchestrationInstructions

## PRIOR PROGRESS (completed in earlier iterations - do not redo):
$priorProgress

Continue from where you left off. Output $token when everything is done.
"@
    } else {
        $basePrompt + "`n" + $orchestrationInstructions
    }

    Write-Log "Calling Claude (build)..." "Yellow"
    $output = Invoke-Claude $fullPrompt "build_$iter"

    if ($v) { Write-Host $output }

    ($output -split "`n") | Where-Object { $_ -match "^PROGRESS:" } | ForEach-Object {
        Add-Content $progressFile $_
        Write-Log $_ "Green"
    }

    Add-Content $logFile "--- Build iteration $iter ---"
    Add-Content $logFile $output
    Add-Content $logFile ""

    if ($output -match [regex]::Escape($token)) {
        $buildTime = ((Get-Date) - $startTime).ToString("mm\:ss")
        Write-Banner "Build complete - $iter iteration(s)  |  $buildTime elapsed" "Green"
        $completed = $true
        break
    }

    Write-Log "Token not found. Looping..." "Magenta"
    Start-Sleep -Seconds 2
}

if (-not $completed) {
    Write-Banner "BUILD INCOMPLETE - did not finish. See log: $logFile" "Red"
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
        Write-Banner "TIMEOUT before QA phase could run" "Red"
        exit 1
    }

    $remaining = [math]::Round(($timeoutSeconds - $elapsed) / 60, 1)
    Write-Log "Running QA pass...  ${remaining}m remaining" "Magenta"

    $output = Invoke-Claude $qaPrompt "qa"

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
$totalTime = ((Get-Date) - $startTime).ToString("mm\:ss")
Write-Banner "ALL DONE  |  $totalTime total" "Green"
