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
    [switch]$noplan,           # -noplan        : skip pre-planning phase
    [switch]$nobranch,         # -nobranch      : skip git worktree isolation (write directly to working dir)
    [string]$profile = "",     # -profile <name>: load a saved profile's flags (CLI flags override)
    [int]$agents = 1,          # -agents <n>    : run N parallel Claude agents on independent subtasks (default: 1)
    [Parameter(Position=2)]
    [string]$SubArg = "",      # for: orchclaude profile save <name>
    [string]$model = "",        # -model <tier>: light, standard, heavy, or raw model ID (default: auto-classify)
    [double]$budget = 0,        # -budget <amount>: pause and confirm if estimated cost exceeds this (0 = disabled)
    [string]$modelprofile = "", # -modelprofile <preset>: fast | balanced | quality | auto
    [switch]$autowait,          # -autowait       : sleep in-process after usage limit and auto-resume (terminal must stay open)
    [switch]$autoschedule,      # -autoschedule   : create schtasks entry and exit after usage limit (terminal can close)
    [int]$waittime = 300,       # -waittime <min> : minutes to wait after usage limit (default 300 = 5 hours)
    [int]$n = 20                # -n <number>     : for 'orchclaude history' - entries to show (default 20)
)

# ---- 7.4: Model Profile Presets ----
$noEscalation = $false
if ($modelprofile -ne "") {
    switch ($modelprofile.ToLower()) {
        "fast"     { if (-not $model) { $model = "light"  } }
        "quality"  { if (-not $model) { $model = "heavy"  } }
        "balanced" { $noEscalation = $true }
        "auto"     { }   # classifier + escalation (default)
        default    {
            Write-Host "Unknown -modelprofile '$modelprofile'. Valid values: fast, balanced, quality, auto" -ForegroundColor Red
            exit 1
        }
    }
}

# ---- Help ----
if ($Command -eq "help" -or $Command -eq "-h" -or $help) {
    # Look for guide file next to the script, then in the repo root, then in user home
    $guideFile = ""
    $candidates = @(
        (Join-Path $PSScriptRoot "ORCHCLAUDE-GUIDE.md"),
        (Join-Path $PSScriptRoot "README.md"),
        (Join-Path $env:USERPROFILE "ORCHCLAUDE-GUIDE.md")
    )
    foreach ($c in $candidates) { if (Test-Path $c) { $guideFile = $c; break } }
    if ($guideFile) {
        Get-Content $guideFile | ForEach-Object { Write-Host $_ }
    } else {
        Write-Host "Guide file not found. Re-install orchclaude or run from the source directory." -ForegroundColor Red
        Write-Host "Quick reference:" -ForegroundColor Cyan
        Write-Host "  orchclaude run `"prompt`" -t 30m"
        Write-Host "  orchclaude run -f project.md -t 2h"
        Write-Host "  orchclaude resume              (continue interrupted run)"
        Write-Host "  orchclaude status              (show session state)"
        Write-Host "  Commands: run, resume, status, dashboard, log, explain, diff, history, metrics, help, profile"
        Write-Host "  Flags: -t -i -f -d -v -noqa -token -cooldown -breaker -dryrun -noplan -nobranch -profile -agents -model -budget -modelprofile -autowait -autoschedule -waittime -n"
        Write-Host "  Profiles: orchclaude profile save <name> [flags]"
        Write-Host "            orchclaude profile list"
        Write-Host "            orchclaude profile delete <name>"
    }
    exit 0
}

# ---- Profile helpers ----
$profilesDir  = Join-Path $env:USERPROFILE ".orchclaude"
$profilesFile = Join-Path $profilesDir "profiles.json"

function Get-Profiles {
    if (-not (Test-Path $profilesFile)) { return @{} }
    try {
        $raw  = Get-Content $profilesFile -Raw | ConvertFrom-Json
        $dict = @{}
        $raw.PSObject.Properties | ForEach-Object { $dict[$_.Name] = $_.Value }
        return $dict
    } catch { return @{} }
}

function Save-Profiles($dict) {
    if (-not (Test-Path $profilesDir)) { New-Item -ItemType Directory -Path $profilesDir | Out-Null }
    $dict | ConvertTo-Json -Depth 5 | Set-Content $profilesFile -Encoding UTF8
}

# ---- Profile command ----
if ($Command -eq "profile") {
    $subCmd = $Prompt.ToLower()

    if ($subCmd -eq "save") {
        if (-not $SubArg) {
            Write-Error "Usage: orchclaude profile save <name> [flags...]"
            exit 1
        }
        $profiles = Get-Profiles
        $profiles[$SubArg] = [ordered]@{
            t        = $t
            i        = $i
            d        = $d
            v        = [bool]$v
            noqa     = [bool]$noqa
            token    = $token
            cooldown = $cooldown
            breaker  = $breaker
            noplan   = [bool]$noplan
            nobranch = [bool]$nobranch
            agents   = $agents
        }
        Save-Profiles $profiles
        Write-Host "Profile '$SubArg' saved to $profilesFile" -ForegroundColor Green
        exit 0
    }
    elseif ($subCmd -eq "list") {
        $profiles = Get-Profiles
        if ($profiles.Count -eq 0) {
            Write-Host "No profiles saved. Use: orchclaude profile save <name> [flags...]" -ForegroundColor Yellow
        } else {
            Write-Host ""
            Write-Host "Saved profiles:" -ForegroundColor Cyan
            Write-Host ("-" * 45)
            foreach ($key in ($profiles.Keys | Sort-Object)) {
                $p = $profiles[$key]
                Write-Host "  $key" -ForegroundColor White
                $line = "    t=$($p.t)  i=$($p.i)  cooldown=$($p.cooldown)  breaker=$($p.breaker)  noqa=$($p.noqa)  noplan=$($p.noplan)"
                Write-Host $line -ForegroundColor DarkGray
                if ($p.d) { Write-Host "    d=$($p.d)" -ForegroundColor DarkGray }
            }
            Write-Host ""
        }
        exit 0
    }
    elseif ($subCmd -eq "delete") {
        if (-not $SubArg) {
            Write-Error "Usage: orchclaude profile delete <name>"
            exit 1
        }
        $profiles = Get-Profiles
        if (-not $profiles.ContainsKey($SubArg)) {
            Write-Error "Profile '$SubArg' not found. Use 'orchclaude profile list' to see available profiles."
            exit 1
        }
        $profiles.Remove($SubArg)
        Save-Profiles $profiles
        Write-Host "Profile '$SubArg' deleted." -ForegroundColor Green
        exit 0
    }
    else {
        Write-Error "Unknown profile subcommand '$subCmd'. Use: save, list, delete"
        exit 1
    }
}

# ---- Status command ----
if ($Command -eq "status") {
    $workDir    = if ($d) { $d } else { (Get-Location).Path }
    $sessionFile = Join-Path $workDir "orchclaude-session.json"

    if (-not (Test-Path $sessionFile)) {
        Write-Host "No session file found in $workDir" -ForegroundColor Yellow
        exit 0
    }

    try {
        $session = Get-Content $sessionFile -Raw | ConvertFrom-Json
    } catch {
        Write-Host "Session file is corrupt or unreadable: $_" -ForegroundColor Red
        exit 1
    }

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

# ---- Dashboard command ----
if ($Command -eq "dashboard") {
    $workDir     = if ($d) { $d } else { (Get-Location).Path }
    $sessionFile = Join-Path $workDir "orchclaude-session.json"
    $logFile     = Join-Path $workDir "orchclaude-log.txt"
    $dashHtml    = Join-Path $PSScriptRoot "dashboard.html"

    if (-not (Test-Path $dashHtml)) {
        Write-Error "dashboard.html not found at $dashHtml ÔÇö reinstall orchclaude or run from the source directory."
        exit 1
    }

    $port    = 7890
    $baseUrl = "http://localhost:$port/"
    $listener = [System.Net.HttpListener]::new()
    $listener.Prefixes.Add($baseUrl)

    try {
        $listener.Start()
    } catch {
        Write-Error "Could not start HTTP server on port $port. Is another process using it?`nError: $_"
        exit 1
    }

    Write-Host ""
    Write-Host ("=" * 50) -ForegroundColor Cyan
    Write-Host "  orchclaude dashboard" -ForegroundColor Cyan
    Write-Host ("=" * 50) -ForegroundColor Cyan
    Write-Host "  URL     : $baseUrl" -ForegroundColor Green
    Write-Host "  Session : $sessionFile" -ForegroundColor DarkGray
    Write-Host "  Log     : $logFile" -ForegroundColor DarkGray
    Write-Host "  Stop    : Ctrl+C" -ForegroundColor Yellow
    Write-Host ("=" * 50) -ForegroundColor Cyan
    Write-Host ""

    Start-Process $baseUrl

    try {
        while ($listener.IsListening) {
            $async = $listener.BeginGetContext($null, $null)
            while (-not $async.IsCompleted) {
                Start-Sleep -Milliseconds 100
            }
            if (-not $listener.IsListening) { break }

            $ctx  = $listener.EndGetContext($async)
            $req  = $ctx.Request
            $resp = $ctx.Response
            $path = $req.Url.AbsolutePath

            try {
                if ($path -eq "/" -or $path -eq "/index.html") {
                    $bytes = [System.IO.File]::ReadAllBytes($dashHtml)
                    $resp.ContentType     = "text/html; charset=utf-8"
                    $resp.ContentLength64 = $bytes.Length
                    $resp.OutputStream.Write($bytes, 0, $bytes.Length)
                }
                elseif ($path -eq "/api/session") {
                    $json  = if (Test-Path $sessionFile) { Get-Content $sessionFile -Raw } else { '{"status":"no session"}' }
                    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
                    $resp.ContentType     = "application/json; charset=utf-8"
                    $resp.ContentLength64 = $bytes.Length
                    $resp.OutputStream.Write($bytes, 0, $bytes.Length)
                }
                elseif ($path -eq "/api/log") {
                    $log   = if (Test-Path $logFile) { (Get-Content $logFile -Tail 200) -join "`n" } else { "(no log yet)" }
                    $bytes = [System.Text.Encoding]::UTF8.GetBytes($log)
                    $resp.ContentType     = "text/plain; charset=utf-8"
                    $resp.ContentLength64 = $bytes.Length
                    $resp.OutputStream.Write($bytes, 0, $bytes.Length)
                }
                else {
                    $resp.StatusCode      = 404
                    $bytes = [System.Text.Encoding]::UTF8.GetBytes("Not found")
                    $resp.ContentLength64 = $bytes.Length
                    $resp.OutputStream.Write($bytes, 0, $bytes.Length)
                }
            } finally {
                try { $resp.OutputStream.Close() } catch {}
            }
        }
    } finally {
        try { $listener.Stop() } catch {}
        Write-Host "Dashboard stopped." -ForegroundColor DarkGray
    }
    exit 0
}

# ---- Log Viewer command ----
if ($Command -eq "log") {
    $workDir    = if ($d) { $d } else { (Get-Location).Path }
    $logHtml    = Join-Path $PSScriptRoot "logviewer.html"

    if (-not (Test-Path $logHtml)) {
        Write-Error "logviewer.html not found at $logHtml ÔÇö reinstall orchclaude or run from the source directory."
        exit 1
    }

    $port    = 7891
    $baseUrl = "http://localhost:$port/"
    $listener = [System.Net.HttpListener]::new()
    $listener.Prefixes.Add($baseUrl)

    try {
        $listener.Start()
    } catch {
        Write-Error "Could not start HTTP server on port $port. Is another process using it?`nError: $_"
        exit 1
    }

    Write-Host ""
    Write-Host ("=" * 50) -ForegroundColor Cyan
    Write-Host "  orchclaude log viewer" -ForegroundColor Cyan
    Write-Host ("=" * 50) -ForegroundColor Cyan
    Write-Host "  URL     : $baseUrl" -ForegroundColor Green
    Write-Host "  Logs    : $workDir" -ForegroundColor DarkGray
    Write-Host "  Stop    : Ctrl+C" -ForegroundColor Yellow
    Write-Host ("=" * 50) -ForegroundColor Cyan
    Write-Host ""

    Start-Process $baseUrl

    try {
        while ($listener.IsListening) {
            $async = $listener.BeginGetContext($null, $null)
            while (-not $async.IsCompleted) {
                Start-Sleep -Milliseconds 100
            }
            if (-not $listener.IsListening) { break }

            $ctx  = $listener.EndGetContext($async)
            $req  = $ctx.Request
            $resp = $ctx.Response
            $path = $req.Url.AbsolutePath

            try {
                if ($path -eq "/" -or $path -eq "/index.html") {
                    $bytes = [System.IO.File]::ReadAllBytes($logHtml)
                    $resp.ContentType     = "text/html; charset=utf-8"
                    $resp.ContentLength64 = $bytes.Length
                    $resp.OutputStream.Write($bytes, 0, $bytes.Length)
                }
                elseif ($path -eq "/api/logs") {
                    # return list of orchclaude log files in workDir
                    $logFiles = Get-ChildItem -Path $workDir -Filter "orchclaude-log*.txt" -File -ErrorAction SilentlyContinue |
                                Sort-Object LastWriteTime -Descending |
                                Select-Object -ExpandProperty Name
                    $json  = ($logFiles | ConvertTo-Json -Compress)
                    if (-not $logFiles) { $json = '[]' }
                    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
                    $resp.ContentType     = "application/json; charset=utf-8"
                    $resp.ContentLength64 = $bytes.Length
                    $resp.OutputStream.Write($bytes, 0, $bytes.Length)
                }
                elseif ($path -eq "/api/log") {
                    $fileName = $req.QueryString["file"]
                    # sanitize: only allow orchclaude-log*.txt files, no path traversal
                    if ($fileName -and $fileName -match '^orchclaude-log[a-zA-Z0-9_\-]*\.txt$') {
                        $logFile = Join-Path $workDir $fileName
                        # limit to last 5000 lines to prevent browser hang on large files
                        $content = if (Test-Path $logFile) { (Get-Content $logFile -Tail 5000) -join "`n" } else { "(log file not found)" }
                    } else {
                        $content = "(invalid or missing file parameter)"
                    }
                    $bytes = [System.Text.Encoding]::UTF8.GetBytes($content)
                    $resp.ContentType     = "text/plain; charset=utf-8"
                    $resp.ContentLength64 = $bytes.Length
                    $resp.OutputStream.Write($bytes, 0, $bytes.Length)
                }
                else {
                    $resp.StatusCode      = 404
                    $bytes = [System.Text.Encoding]::UTF8.GetBytes("Not found")
                    $resp.ContentLength64 = $bytes.Length
                    $resp.OutputStream.Write($bytes, 0, $bytes.Length)
                }
            } finally {
                try { $resp.OutputStream.Close() } catch {}
            }
        }
    } finally {
        try { $listener.Stop() } catch {}
        Write-Host "Log viewer stopped." -ForegroundColor DarkGray
    }
    exit 0
}

# ---- Explain command ----
if ($Command -eq "explain") {
    $workDir     = if ($d) { $d } else { (Get-Location).Path }
    $sessionFile = Join-Path $workDir "orchclaude-session.json"

    Write-Host ""
    Write-Host ("=" * 55) -ForegroundColor Cyan
    Write-Host "  orchclaude explain" -ForegroundColor Cyan
    Write-Host ("=" * 55) -ForegroundColor Cyan
    Write-Host "  Directory : $workDir" -ForegroundColor DarkGray
    Write-Host "  Mode      : read-only (no file changes)" -ForegroundColor DarkGray
    Write-Host ("=" * 55) -ForegroundColor Cyan
    Write-Host ""

    $sessionContext = ""
    if (Test-Path $sessionFile) {
        try {
            $session = Get-Content $sessionFile -Raw | ConvertFrom-Json
            $sessionContext = "`n`n## Context from last orchclaude run`nStatus: $($session.status)  |  Iterations: $($session.currentIteration)"
            if ($session.progressLines -and $session.progressLines.Count -gt 0) {
                $sessionContext += "`nProgress logged:`n" + ($session.progressLines -join "`n")
            }
        } catch {}
    }

    $explainPrompt = @"
## EXPLAIN MODE ÔÇö read-only, no file changes

Your job is to explain what has been built in this directory: $workDir

Instructions:
1. Use Read, Glob, and Grep to explore the directory.
2. Write a clear, structured explanation covering:
   - What was built and what it does
   - How it is structured (key files and their roles)
   - How to use it (main entry points, commands, flags, or APIs)
   - Anything notable about the implementation
3. Keep it concise but complete. Write for a developer who is new to this project.
4. Do NOT create, edit, or delete any files.
$sessionContext
"@

    $promptFile = Join-Path $env:TEMP "orchclaude_explain_${PID}.txt"
    $explainPrompt | Set-Content $promptFile -Encoding UTF8

    Write-Host "Calling Claude (read-only)..." -ForegroundColor Cyan

    try {
        $output = & claude `
            -p (Get-Content $promptFile -Raw) `
            --allowedTools "Read,Glob,Grep" `
            --max-turns 20 `
            --dangerously-skip-permissions `
            2>&1
    } catch [System.Management.Automation.CommandNotFoundException] {
        Write-Host "'claude' command not found. Is Claude Code installed and in your PATH?" -ForegroundColor Red
        Remove-Item $promptFile -ErrorAction SilentlyContinue
        exit 1
    }

    Remove-Item $promptFile -ErrorAction SilentlyContinue

    Write-Host ""
    Write-Host ("=" * 55) -ForegroundColor Green
    Write-Host "  EXPLANATION" -ForegroundColor Green
    Write-Host ("=" * 55) -ForegroundColor Green
    Write-Host ""
    Write-Host $output
    Write-Host ""
    exit 0
}

# ---- Diff command ----
if ($Command -eq "diff") {
    $workDir     = if ($d) { $d } else { (Get-Location).Path }
    $sessionFile = Join-Path $workDir "orchclaude-session.json"

    Write-Host ""
    Write-Host ("=" * 55) -ForegroundColor Cyan
    Write-Host "  orchclaude diff" -ForegroundColor Cyan
    Write-Host ("=" * 55) -ForegroundColor Cyan

    if (-not (Test-Path $sessionFile)) {
        Write-Host "  No session file found in $workDir" -ForegroundColor Yellow
        Write-Host "  Run orchclaude first, then use orchclaude diff." -ForegroundColor DarkGray
        Write-Host ""
        exit 0
    }

    try {
        $session = Get-Content $sessionFile -Raw | ConvertFrom-Json
    } catch {
        Write-Host "Session file is corrupt or unreadable: $_" -ForegroundColor Red
        exit 1
    }

    $diffStartCommit  = $session.startCommit
    $diffOrigDir      = if ($session.originalWorkDir) { $session.originalWorkDir } else { $workDir }
    $diffBranch       = $session.worktreeBranch

    Write-Host "  Session   : $($session.status)  |  Iteration: $($session.currentIteration)" -ForegroundColor DarkGray
    if ($diffBranch) { Write-Host "  Branch    : $diffBranch" -ForegroundColor DarkGray }
    Write-Host ("=" * 55) -ForegroundColor Cyan
    Write-Host ""

    if (-not $diffStartCommit) {
        Write-Host "No git diff available ÔÇö this session was run without git tracking," -ForegroundColor Yellow
        Write-Host "or it was created with an older version of orchclaude." -ForegroundColor Yellow
        Write-Host ""
        if ($session.progressLines -and $session.progressLines.Count -gt 0) {
            Write-Host "PROGRESS from this run:" -ForegroundColor Cyan
            Write-Host ("-" * 55) -ForegroundColor Cyan
            $session.progressLines | ForEach-Object { Write-Host "  $_" -ForegroundColor White }
        }
        exit 0
    }

    # Verify git repo
    $null = & git -C $diffOrigDir rev-parse --git-dir 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Not a git repository: $diffOrigDir" -ForegroundColor Yellow
        exit 0
    }

    # Determine end ref: prefer worktree branch if it still exists; else HEAD
    $endRef = "HEAD"
    if ($diffBranch) {
        $null = & git -C $diffOrigDir rev-parse --verify $diffBranch 2>&1
        if ($LASTEXITCODE -eq 0) { $endRef = $diffBranch }
    }

    Write-Host "From : $diffStartCommit" -ForegroundColor DarkGray
    Write-Host "To   : $endRef" -ForegroundColor DarkGray
    Write-Host ""

    # Summary stat
    $diffStat = & git -C $diffOrigDir diff --stat "${diffStartCommit}..${endRef}" 2>&1
    if ($LASTEXITCODE -ne 0) {
        # Retry against HEAD in case branch was merged and deleted
        $diffStat = & git -C $diffOrigDir diff --stat "${diffStartCommit}" 2>&1
        $endRef = "HEAD"
    }

    $statText = ($diffStat -join "`n").Trim()
    if (-not $statText) {
        Write-Host "No changes detected between $diffStartCommit and $endRef." -ForegroundColor Yellow
        exit 0
    }

    Write-Host "FILES CHANGED:" -ForegroundColor Cyan
    Write-Host ("-" * 55) -ForegroundColor Cyan
    $diffStat | ForEach-Object { Write-Host "  $_" -ForegroundColor White }
    Write-Host ""

    if ($v) {
        Write-Host "FULL DIFF:" -ForegroundColor Cyan
        Write-Host ("-" * 55) -ForegroundColor Cyan
        $fullDiff = & git -C $diffOrigDir diff "${diffStartCommit}..${endRef}" 2>&1
        $fullDiff | ForEach-Object {
            if     ($_ -match "^\+[^+]")  { Write-Host $_ -ForegroundColor Green }
            elseif ($_ -match "^-[^-]")   { Write-Host $_ -ForegroundColor Red }
            elseif ($_ -match "^@@")      { Write-Host $_ -ForegroundColor Cyan }
            else                          { Write-Host $_ }
        }
    } else {
        Write-Host "(Run 'orchclaude diff -v' to see the full line-by-line diff)" -ForegroundColor DarkGray
    }
    Write-Host ""
    exit 0
}

# ---- History command ----
if ($Command -eq "history") {
    $historyDir  = Join-Path $env:USERPROFILE ".orchclaude"
    $historyFile = Join-Path $historyDir "history.json"
    $subCmd      = $Prompt.ToLower()

    if ($subCmd -eq "clear") {
        if (-not (Test-Path $historyFile)) {
            Write-Host "No history to clear." -ForegroundColor Yellow
            exit 0
        }
        $confirm = Read-Host "Clear all run history? (y/n)"
        if ($confirm -ieq "y") {
            Remove-Item $historyFile -Force
            Write-Host "History cleared." -ForegroundColor Green
        } else {
            Write-Host "Cancelled." -ForegroundColor DarkGray
        }
        exit 0
    }

    if (-not (Test-Path $historyFile)) {
        Write-Host "No history yet. History is recorded after each run." -ForegroundColor Yellow
        exit 0
    }

    try {
        $raw     = Get-Content $historyFile -Raw | ConvertFrom-Json
        $history = if ($raw -is [array]) { @($raw) } else { @($raw) }
    } catch {
        Write-Host "History file is corrupt or unreadable: $_" -ForegroundColor Red
        exit 1
    }

    $limit      = if ($n -gt 0) { $n } else { 20 }
    $totalCount = $history.Count
    # file layout is newest-first; just take the first N
    $toShow     = @(@($history) | Select-Object -First $limit)

    Write-Host ""
    Write-Host "orchclaude run history  (showing $($toShow.Count) of $totalCount runs, newest first)" -ForegroundColor Cyan
    Write-Host ("-" * 92) -ForegroundColor Cyan

    $num = 1
    foreach ($entry in $toShow) {
        $dateStr   = try { ([datetime]$entry.date).ToString("yyyy-MM-dd HH:mm") } catch { "$($entry.date)" }
        $statusStr = "$($entry.status)".ToUpper().PadRight(20)
        $wd        = if ($entry.workDir.Length -gt 40) { "..." + $entry.workDir.Substring($entry.workDir.Length - 37) } else { "$($entry.workDir)" }
        $wd        = $wd.PadRight(40)
        $durStr    = "$($entry.durationMinutes)m".PadLeft(6)
        $costStr   = "`$$($entry.estimatedCostUSD)".PadLeft(7)
        $iterStr   = "$($entry.iterations) iters".PadLeft(8)
        $excerpt   = if ($entry.promptExcerpt.Length -gt 35) { $entry.promptExcerpt.Substring(0, 32) + "..." } else { "$($entry.promptExcerpt)" }

        $statusColor = switch ($entry.status) {
            "complete"           { "Green"  }
            "timeout"            { "Red"    }
            "failed"             { "Red"    }
            "usage_limit_paused" { "Yellow" }
            default              { "White"  }
        }

        $prefix = "  #$("$num".PadLeft(3))  $dateStr  "
        Write-Host $prefix -NoNewline
        Write-Host $statusStr -ForegroundColor $statusColor -NoNewline
        Write-Host "  $wd  $durStr  $costStr  $iterStr  `"$excerpt`""
        $num++
    }

    Write-Host ""
    Write-Host "  Use 'orchclaude history -n 50' to show more entries." -ForegroundColor DarkGray
    Write-Host "  Use 'orchclaude history clear' to wipe the history." -ForegroundColor DarkGray
    Write-Host ""
    exit 0
}

# ---- 9.1: Metrics command ----
if ($Command -eq "metrics") {
    $workDir      = if ($d) { $d } else { (Get-Location).Path }
    $metricsFile  = Join-Path $workDir "orchclaude-metrics.json"

    if (-not (Test-Path $metricsFile)) {
        Write-Host "No metrics found. Metrics are recorded after each run in the work directory." -ForegroundColor Yellow
        exit 0
    }

    try {
        $raw     = Get-Content $metricsFile -Raw | ConvertFrom-Json
        $metrics = if ($raw -is [array]) { @($raw) } else { @($raw) }
    } catch {
        Write-Host "Metrics file is corrupt or unreadable: $_" -ForegroundColor Red
        exit 1
    }

    Write-Host ""
    Write-Host "Iteration Metrics for $workDir" -ForegroundColor Cyan
    Write-Host ("-" * 110) -ForegroundColor Cyan
    Write-Host "  Iter  Model     Elapsed  Input    Output   Cost     Progress  Status" -ForegroundColor Cyan
    Write-Host ("-" * 110) -ForegroundColor Cyan

    $totalSeconds = 0
    $totalCost    = 0
    $successCount = 0
    $retryCount   = 0
    $escalCount   = 0

    # metrics are newest-first on disk; sort by iteration number for display (oldest-first)
    $reversed = @($metrics) | Sort-Object -Property iterationNumber
    foreach ($entry in $reversed) {
        $iterStr    = "$($entry.iterationNumber)".PadLeft(4)
        $modelStr   = "$($entry.modelUsed)".PadRight(9)
        $elapStr    = "$([math]::Round($entry.elapsedSeconds, 1))s".PadLeft(8)
        $inStr      = "$($entry.inputTokens)".PadLeft(8)
        $outStr     = "$($entry.outputTokens)".PadLeft(8)
        $costStr    = "`$$([math]::Round($entry.estimatedCostUSD, 4))".PadLeft(8)
        $progStr    = if ($entry.hadProgress) { "$($entry.progressLines.Count) lines" } else { "none" }
        $progStr    = $progStr.PadLeft(9)
        $statusStr  = $entry.status.PadRight(9)

        $statusColor = switch ($entry.status) {
            "success"   { "Green"  }
            "escalated" { "Yellow" }
            "retry"     { "White"  }
            "failed"    { "Red"    }
            default     { "White"  }
        }

        $line = "  $iterStr  $modelStr  $elapStr  $inStr  $outStr  $costStr  $progStr  "
        Write-Host $line -NoNewline
        Write-Host $statusStr -ForegroundColor $statusColor

        $totalSeconds += $entry.elapsedSeconds
        $totalCost    += $entry.estimatedCostUSD
        if ($entry.status -eq "success")   { $successCount++ }
        elseif ($entry.status -eq "retry") { $retryCount++ }
        elseif ($entry.status -eq "escalated") { $escalCount++ }
    }

    Write-Host ("-" * 110) -ForegroundColor Cyan
    $avgTime = if ($metrics.Count -gt 0) { [math]::Round($totalSeconds / $metrics.Count, 1) } else { 0 }
    $summary = "  Summary: $($metrics.Count) iterations | $([math]::Round($totalSeconds, 1))s total | `$$([math]::Round($totalCost, 4)) total | $avgTime s avg/iter | $successCount success, $retryCount retry, $escalCount escalated"
    Write-Host $summary -ForegroundColor Cyan
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

    try {
        $session = Get-Content $sessionFile -Raw | ConvertFrom-Json
    } catch {
        Write-Host "Session file is corrupt or unreadable: $_" -ForegroundColor Red
        exit 1
    }

    if ($session.status -eq "complete") {
        Write-Host "Last session already completed." -ForegroundColor Green
        exit 0
    }

    if ($session.status -eq "usage_limit_paused") {
        $resumeAfterStr = $session.resumeAfter
        if ($resumeAfterStr) {
            $resumeAt = [datetime]$resumeAfterStr
            $now = Get-Date
            if ($now -lt $resumeAt) {
                $remaining = $resumeAt - $now
                $remH = [math]::Floor($remaining.TotalHours)
                $remM = $remaining.Minutes
                Write-Host "Not ready yet. Resume scheduled for $($resumeAt.ToString('HH:mm:ss')). ${remH}h ${remM}m remaining." -ForegroundColor Yellow
                Write-Host "Run 'orchclaude resume' again after the limit resets, or wait for autowait/autoschedule to fire." -ForegroundColor DarkGray
                exit 0
            }
            Write-Host "Usage limit has reset. Resuming now..." -ForegroundColor Cyan
        }
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

# ---- Load named profile (CLI flags take precedence) ----
if ($profile -and -not $resumeMode) {
    $profiles = Get-Profiles
    if (-not $profiles.ContainsKey($profile)) {
        Write-Error "Profile '$profile' not found. Use 'orchclaude profile list' to see available profiles."
        exit 1
    }
    $p = $profiles[$profile]
    if (-not $PSBoundParameters.ContainsKey('t'))        { $t        = $p.t }
    if (-not $PSBoundParameters.ContainsKey('i'))        { $i        = [int]$p.i }
    if (-not $PSBoundParameters.ContainsKey('d'))        { $d        = "$($p.d)" }
    if (-not $PSBoundParameters.ContainsKey('v'))        { $v        = [System.Management.Automation.SwitchParameter][bool]$p.v }
    if (-not $PSBoundParameters.ContainsKey('noqa'))     { $noqa     = [System.Management.Automation.SwitchParameter][bool]$p.noqa }
    if (-not $PSBoundParameters.ContainsKey('token'))    { $token    = $p.token }
    if (-not $PSBoundParameters.ContainsKey('cooldown')) { $cooldown = [int]$p.cooldown }
    if (-not $PSBoundParameters.ContainsKey('breaker'))  { $breaker  = [int]$p.breaker }
    if (-not $PSBoundParameters.ContainsKey('noplan'))   { $noplan   = [System.Management.Automation.SwitchParameter][bool]$p.noplan }
    if (-not $PSBoundParameters.ContainsKey('nobranch')) { $nobranch = [System.Management.Automation.SwitchParameter][bool]$p.nobranch }
    if (-not $PSBoundParameters.ContainsKey('agents'))   { $agents   = if ($p.agents) { [int]$p.agents } else { 1 } }
}

# ---- Validate agents flag ----
if ($agents -lt 1) {
    Write-Error "Bad -agents value '$agents'. Must be a positive integer."
    exit 1
}
if ($agents -gt 20) {
    Write-Error "Bad -agents value '$agents'. Maximum supported is 20 parallel agents."
    exit 1
}
if ($agents -gt 1 -and $noplan) {
    Write-Error "-agents requires the planning phase. Remove -noplan or set -agents 1."
    exit 1
}
if ($agents -gt 1 -and $resumeMode) {
    Write-Warning "-agents is not supported in resume mode. Running single-agent."
    $agents = 1
}

# ---- Require "run" for non-resume/resume/status/help ----
if (-not $resumeMode -and $Command -ne "run") {
    Write-Error "Unknown command '$Command'. Use: orchclaude run, orchclaude resume, orchclaude status, orchclaude dashboard, orchclaude log, orchclaude explain, orchclaude diff, orchclaude history, orchclaude metrics, orchclaude help, orchclaude profile"
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

# ---- Validate cooldown ----
if ($cooldown -lt 0) {
    Write-Error "Bad -cooldown value '$cooldown'. Must be >= 0 (use 0 to disable)."
    exit 1
}

# ---- Working directory ----
$workDir = if ($d) { $d } else { (Get-Location).Path }
if (-not (Test-Path $workDir)) { Write-Error "Directory not found: $workDir"; exit 1 }

# ---- Git Worktree Isolation ----
$isGitRepo       = $false
$useWorktree     = $false
$worktreePath    = ""
$worktreeBranch  = ""
$originalBranch  = ""
$originalWorkDir = $workDir
$startCommit     = ""

if (-not $nobranch -and -not $resumeMode -and -not $dryrun) {
    $null = & git -C $workDir rev-parse --git-dir 2>&1
    if ($LASTEXITCODE -eq 0) {
        $isGitRepo      = $true
        $startCommit    = (& git -C $workDir rev-parse HEAD 2>&1).Trim()
        $gitRoot        = (& git -C $workDir rev-parse --show-toplevel 2>&1).Trim().Replace('/', '\')
        $originalBranch = (& git -C $workDir branch --show-current 2>&1).Trim()
        if (-not $originalBranch) { $originalBranch = "HEAD" }

        $ts             = (Get-Date).ToString("yyyyMMdd-HHmmss")
        $worktreeBranch = "orchclaude/$ts"
        $wtRoot         = Join-Path $env:TEMP "orchclaude-wt-$ts"

        $wtOut = & git -C $workDir worktree add $wtRoot -b $worktreeBranch 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Could not create git worktree: $wtOut ÔÇö writing directly to $workDir"
        } else {
            $useWorktree  = $true
            $worktreePath = $wtRoot
            # Preserve subdir if workDir was not the repo root
            if ($workDir.TrimEnd('\') -ne $gitRoot.TrimEnd('\')) {
                $rel     = $workDir.Substring($gitRoot.Length).TrimStart('\')
                $workDir = Join-Path $wtRoot $rel
            } else {
                $workDir = $wtRoot
            }
        }
    } else {
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Not a git repository ÔÇö writing directly to $workDir (use -nobranch to suppress this message)" -ForegroundColor DarkGray
    }
}

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
        startCommit      = $startCommit
        originalWorkDir  = $originalWorkDir
        worktreeBranch   = $worktreeBranch
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

function Get-EstimatedCost {
    $inputTokens  = [math]::Round($totalInputWords  * 1.33)
    $outputTokens = [math]::Round($totalOutputWords * 1.33)
    $inputCost    = [math]::Round($inputTokens  / 1000000 * 3,  4)
    $outputCost   = [math]::Round($outputTokens / 1000000 * 15, 4)
    return [math]::Round($inputCost + $outputCost, 4)
}

function Show-CostEstimate {
    $inputTokens  = [math]::Round($totalInputWords  * 1.33)
    $outputTokens = [math]::Round($totalOutputWords * 1.33)
    $totalCost    = Get-EstimatedCost
    $line = "Estimated usage: ~$inputTokens tokens input, ~$outputTokens tokens output | Estimated cost: ~`$$totalCost (estimate only)"
    Write-Log $line "Cyan"
}

function Check-Budget($currentIter = 0) {
    if ($script:budget -le 0) { return }
    $currentCost = Get-EstimatedCost
    if ($currentCost -gt $script:budget) {
        Write-Host ""
        Write-Log "BUDGET EXCEEDED: estimated cost `$$currentCost exceeds budget `$$($script:budget)" "Red"
        if ($script:autowait -or $script:autoschedule) {
            Write-Log "BUDGET: unattended mode - auto-continuing and doubling budget threshold." "Yellow"
            $script:budget = [math]::Round($script:budget * 2, 4)
            Write-Log "Budget doubled to `$$($script:budget). Continuing." "Yellow"
            return
        }
        $choice = Read-Host "Continue? (y/n)"
        if ($choice -ieq "n") {
            Write-Log "User stopped run at budget limit (`$$currentCost > `$$($script:budget))." "Red"
            Show-CostEstimate
            Write-Session "timeout" $currentIter
            Write-History "failed" $currentIter
            Show-WorktreeBranchInfo
            exit 1
        } else {
            $script:budget = [math]::Round($script:budget * 2, 4)
            Write-Log "Budget doubled to `$$($script:budget). Continuing." "Yellow"
        }
    }
}

function Write-History($status, $iterCount) {
    try {
        $historyDir  = Join-Path $env:USERPROFILE ".orchclaude"
        $historyFile = Join-Path $historyDir "history.json"
        if (-not (Test-Path $historyDir)) { New-Item -ItemType Directory -Path $historyDir | Out-Null }

        $existing = @()
        if (Test-Path $historyFile) {
            try {
                $raw = Get-Content $historyFile -Raw | ConvertFrom-Json
                if ($raw -is [array]) { $existing = @($raw) } elseif ($raw) { $existing = @($raw) }
            } catch { $existing = @() }
        }

        $excerpt = if ($basePrompt.Length -gt 120) { $basePrompt.Substring(0, 120) } else { $basePrompt }
        $progressLines = if (Test-Path $progressFile) {
            @(Get-Content $progressFile | Where-Object { $_ -match "\S" })
        } else { @() }
        $lastProgress    = if ($progressLines.Count -gt 0) { $progressLines[-1] } else { "" }
        $durationMinutes = [math]::Round(((Get-Date) - $startTime).TotalMinutes, 1)

        # 9.1: aggregate per-iteration metrics into history summary fields
        $avgTokensPerIter   = 0
        $avgCostPerIter     = 0
        $avgElapsedPerIter  = 0
        $fastestIter        = $null
        $slowestIter        = $null
        $mostExpensiveIter  = $null
        $metricsFile        = Join-Path $workDir "orchclaude-metrics.json"
        if (Test-Path $metricsFile) {
            try {
                $rawMetrics = Get-Content $metricsFile -Raw | ConvertFrom-Json
                $metricsArr = if ($rawMetrics -is [array]) { @($rawMetrics) } else { @($rawMetrics) }
                if ($metricsArr.Count -gt 0) {
                    $sumTokens  = 0
                    $sumCost    = 0
                    $sumElapsed = 0
                    foreach ($m in $metricsArr) {
                        $sumTokens  += ([int]$m.inputTokens + [int]$m.outputTokens)
                        $sumCost    += [double]$m.estimatedCostUSD
                        $sumElapsed += [double]$m.elapsedSeconds
                    }
                    $avgTokensPerIter  = [math]::Round(($sumTokens  / $metricsArr.Count) / 100) * 100
                    $avgCostPerIter    = [math]::Round(($sumCost    / $metricsArr.Count), 3)
                    $avgElapsedPerIter = [math]::Round(($sumElapsed / $metricsArr.Count), 1)

                    $fast = $metricsArr | Sort-Object { [double]$_.elapsedSeconds }       | Select-Object -First 1
                    $slow = $metricsArr | Sort-Object { [double]$_.elapsedSeconds }       | Select-Object -Last  1
                    $exp  = $metricsArr | Sort-Object { [double]$_.estimatedCostUSD }     | Select-Object -Last  1
                    if ($fast) { $fastestIter       = [int]$fast.iterationNumber }
                    if ($slow) { $slowestIter       = [int]$slow.iterationNumber }
                    if ($exp)  { $mostExpensiveIter = [int]$exp.iterationNumber  }
                }
            } catch {}
        }

        $entry = [ordered]@{
            id                 = (Get-Date).ToString("yyyyMMdd-HHmmss")
            date               = (Get-Date).ToString("o")
            workDir            = $originalWorkDir
            promptExcerpt      = $excerpt
            status             = $status
            iterations         = $iterCount
            durationMinutes    = $durationMinutes
            estimatedCostUSD   = Get-EstimatedCost
            progressCount      = $progressLines.Count
            lastProgress       = $lastProgress
            avgTokensPerIter   = $avgTokensPerIter
            avgCostPerIter     = $avgCostPerIter
            avgElapsedPerIter  = $avgElapsedPerIter
            fastestIter        = $fastestIter
            slowestIter        = $slowestIter
            mostExpensiveIter  = $mostExpensiveIter
        }

        $merged = @($entry) + @($existing)
        if ($merged.Count -gt 200) { $merged = $merged | Select-Object -First 200 }
        $merged | ConvertTo-Json -Depth 5 | Set-Content $historyFile -Encoding UTF8
    } catch {
        Write-Host "[history] Warning: could not write history entry: $_" -ForegroundColor DarkGray
    }
}

# ---- 9.1: Per-Iteration Performance Metrics ----
function Write-Metrics($iterNum, $modelUsed, $iterStartTime, $iterElapsedSeconds, $inputWords, $outputWords, $hadProgress, $progressLines, $iterStatus) {
    try {
        $metricsFile = Join-Path $workDir "orchclaude-metrics.json"

        $inputTokens  = [math]::Round($inputWords * 1.33)
        $outputTokens = [math]::Round($outputWords * 1.33)
        $iterCostUSD  = [math]::Round(($inputTokens / 1000000 * 3) + ($outputTokens / 1000000 * 15), 4)

        $entry = [ordered]@{
            iterationNumber = $iterNum
            modelUsed       = $modelUsed
            startTime       = $iterStartTime.ToString("o")
            elapsedSeconds  = [math]::Round($iterElapsedSeconds, 2)
            inputTokens     = $inputTokens
            outputTokens    = $outputTokens
            estimatedCostUSD = $iterCostUSD
            hadProgress     = [bool]$hadProgress
            progressLines   = @($progressLines)
            status          = $iterStatus
        }

        $existing = @()
        if (Test-Path $metricsFile) {
            try {
                $raw = Get-Content $metricsFile -Raw | ConvertFrom-Json
                if ($raw -is [array]) { $existing = @($raw) } elseif ($raw) { $existing = @($raw) }
            } catch { $existing = @() }
        }

        $merged = @($entry) + @($existing)
        $merged | ConvertTo-Json -Depth 5 | Set-Content $metricsFile -Encoding UTF8

        # Log metrics line for readability
        $metricsLine = "[METRICS] Iter $iterNum : $modelUsed | $([math]::Round($iterElapsedSeconds,1))s | $inputTokens→$outputTokens tokens | `$$iterCostUSD | $($progressLines.Count) progress lines"
        Add-Content $logFile $metricsLine
    } catch {
        Write-Host "[metrics] Warning: could not write metrics entry: $_" -ForegroundColor DarkGray
    }
}

function Show-WorktreeBranchInfo {
    if (-not $useWorktree) { return }
    Write-Log "Worktree branch '$worktreeBranch' left intact for inspection." "Yellow"
    Write-Log "Worktree path  : $worktreePath" "Yellow"
    Write-Log "To merge later : git -C `"$originalWorkDir`" merge $worktreeBranch" "Yellow"
}

function Test-UsageLimitError($text) {
    if (-not $text) { return $false }
    # Join array output (stderr + stdout mixed) into one searchable string
    $flat = if ($text -is [array]) { $text -join "`n" } else { "$text" }
    # Strip ANSI escape codes so color-wrapped messages still match
    $flat = $flat -replace '\x1b\[[0-9;]*m', ''
    $patterns = @(
        "Claude AI usage limit reached",
        "rate_limit_error",
        "overloaded_error",
        "exceeded your current quota",
        "You have reached your usage limit",
        "out of extra usage",
        "extra usage",
        "Usage limit reached",
        "out of usage",
        "You're out of",
        "You are out of"
    )
    foreach ($p in $patterns) {
        if ($flat -imatch [regex]::Escape($p)) { return $true }
    }
    if ($flat -imatch "usage limit") { return $true }
    if ($flat -imatch "resets") { return $true }
    return $false
}

function Handle-UsageLimit($currentIter) {
    $now      = Get-Date
    $resumeAt = $now.AddMinutes($script:waittime)

    Write-Host ""
    Write-Log "USAGE LIMIT HIT: Claude usage limit detected at $($now.ToString('HH:mm:ss'))." "Red"
    Write-Log "Resume possible at $($resumeAt.ToString('HH:mm:ss')) ($($script:waittime) minutes from now)." "Yellow"

    # Save state with usage_limit_paused
    $progressLines = if (Test-Path $progressFile) {
        @(Get-Content $progressFile | Where-Object { $_ -match "\S" })
    } else { @() }

    $sessionData = [ordered]@{
        startTime        = $startTime.ToString("o")
        lastUpdated      = $now.ToString("o")
        status           = "usage_limit_paused"
        currentIteration = $currentIter
        prompt           = $basePrompt
        resumeAfter      = $resumeAt.ToString("o")
        pausedAt         = $now.ToString("o")
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
    Add-Content $logFile "[$($now.ToString('HH:mm:ss'))] USAGE_LIMIT_PAUSED: iteration $currentIter, resumeAfter=$($resumeAt.ToString('o'))"

    if ($script:autowait) {
        $totalWaitSecs   = $script:waittime * 60
        $intervalSecs    = 600  # 10 minutes
        $slept           = 0

        while ($slept -lt $totalWaitSecs) {
            $remaining = $totalWaitSecs - $slept
            $remH = [math]::Floor($remaining / 3600)
            $remM = [math]::Floor(($remaining % 3600) / 60)
            Write-Log "Resuming in ${remH}h ${remM}m... (Ctrl+C to interrupt ÔÇö session is saved)" "Yellow"
            $sleepFor = [math]::Min($intervalSecs, $remaining)
            Start-Sleep -Seconds $sleepFor
            $slept += $sleepFor
        }

        Write-Log "Resuming now..." "Green"
        return $true  # signal caller to continue the loop

    } elseif ($script:autoschedule) {
        $resumeTime = $resumeAt.ToString("HH:mm")
        $scriptPath = if ($MyInvocation.ScriptName) { $MyInvocation.ScriptName } else { $PSCommandPath }
        $resumeCmd  = "powershell.exe -ExecutionPolicy Bypass -File `"$scriptPath`" resume -d `"$workDir`""
        $taskName   = "orchclaude-resume-$($now.ToString('yyyyMMdd-HHmmss'))"

        $schtasksResult = & schtasks /create /tn $taskName /tr $resumeCmd /sc once /st $resumeTime /f 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Log "Scheduled resume at $resumeTime as task '$taskName'." "Green"
            Write-Log "Safe to close this terminal. The task will auto-run." "Green"
            Add-Content $logFile "[$($now.ToString('HH:mm:ss'))] AUTOSCHEDULE: task '$taskName' created for $resumeTime"
        } else {
            Write-Log "Failed to create scheduled task: $schtasksResult" "Red"
            Write-Log "Run manually after limit resets: orchclaude resume -d `"$workDir`"" "Yellow"
        }

        Show-CostEstimate
        Write-History "usage_limit_paused" $currentIter
        exit 0
    } else {
        Write-Log "Session saved. Run 'orchclaude resume' to continue once the limit resets (~$($script:waittime) min)." "Yellow"
        Write-Log "Expected reset at: $($resumeAt.ToString('HH:mm:ss'))" "Yellow"
        Show-CostEstimate
        Write-History "usage_limit_paused" $currentIter
        Show-WorktreeBranchInfo
        exit 0
    }
}

function Invoke-Claude($prompt, $iterLabel, $modelId = "") {
    $promptFile = Join-Path $env:TEMP "orchclaude_prompt_${PID}_$iterLabel.txt"
    $prompt | Set-Content $promptFile -Encoding UTF8

    $claudeArgs = @(
        "-p", (Get-Content $promptFile -Raw),
        "--allowedTools", "Edit,Bash,Read,Write,Glob,Grep",
        "--max-turns", "50",
        "--dangerously-skip-permissions"
    )
    if ($modelId) { $claudeArgs += "--model"; $claudeArgs += $modelId }

    try {
        $output = & claude @claudeArgs 2>&1
    } catch [System.Management.Automation.CommandNotFoundException] {
        Write-Error "'claude' command not found. Is Claude Code installed and in your PATH?"
        Remove-Item $promptFile -ErrorAction SilentlyContinue
        exit 1
    }

    Remove-Item $promptFile -ErrorAction SilentlyContinue
    return $output
}

# ---- Model tier map (7.1) ----
$script:modelMap = @{
    "light"    = "claude-haiku-4-5-20251001"
    "standard" = "claude-sonnet-4-6"
    "heavy"    = "claude-opus-4-7"
}
$script:tierLabel = @{
    "claude-haiku-4-5-20251001" = "haiku"
    "claude-sonnet-4-6"         = "sonnet"
    "claude-opus-4-7"           = "opus"
}

function Resolve-ModelId($tier) {
    if ($model) {
        if ($model -eq "light")    { return $script:modelMap["light"] }
        if ($model -eq "standard") { return $script:modelMap["standard"] }
        if ($model -eq "heavy")    { return $script:modelMap["heavy"] }
        return $model  # raw model ID passed directly
    }
    return $script:modelMap[$tier.ToLower()]
}

function Get-TaskTier($prompt, $iterNum, $hasPriorProgress) {
    # First iteration of a brand-new project ÔåÆ always heavy
    if ($iterNum -eq 1 -and -not $hasPriorProgress) { return "heavy" }

    # Run a lightweight haiku classifier
    $excerpt = $prompt.Substring(0, [math]::Min(600, $prompt.Length))
    $classifyPrompt = @"
Classify this software task as LIGHT, STANDARD, or HEAVY. Output only one word.

LIGHT = reading files / summarizing / generating plans or outlines / simple file writes with no logic
STANDARD = general feature implementation / most coding tasks / moderate reasoning
HEAVY = architecture decisions / complex multi-file debugging / security-sensitive code

Task:
$excerpt
"@
    try {
        $raw = (& claude -p $classifyPrompt --model claude-haiku-4-5-20251001 --max-turns 1 --dangerously-skip-permissions --output-format text 2>&1) -join " "
        if ($raw -match "\bHEAVY\b")    { return "heavy" }
        if ($raw -match "\bLIGHT\b")    { return "light" }
    } catch {}
    return "standard"
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
Write-Log "Ctx guard : enabled (compresses progress log when prompt exceeds ~150k tokens)" "Cyan"
Write-Log "Worktree  : $(if ($nobranch) { 'disabled (-nobranch)' } elseif ($useWorktree) { "branch $worktreeBranch" } elseif ($isGitRepo) { 'git repo detected but worktree creation failed ÔÇö writing directly' } else { 'not a git repo ÔÇö writing directly' })" "Cyan"
Write-Log "Agents    : $(if ($agents -gt 1) { "$agents parallel agents (independent tasks split from plan)" } else { '1 (sequential, default)' })" "Cyan"
$modelBannerVal = if ($modelprofile -ne "") {
    $profileDesc = switch ($modelprofile.ToLower()) {
        "fast"     { "fast (all iterations: haiku)" }
        "quality"  { "quality (all iterations: opus)" }
        "balanced" { "balanced (classifier, no escalation)" }
        "auto"     { "auto (classifier + adaptive escalation: haiku->sonnet->opus on stall)" }
        default    { $modelprofile }
    }
    "-modelprofile $profileDesc"
} elseif ($model) {
    "fixed override: $model"
} else {
    "auto (classifier + adaptive escalation: haiku->sonnet->opus on stall)"
}
Write-Log "Model     : $modelBannerVal" "Cyan"
Write-Log "Budget    : $(if ($budget -gt 0) { "`$$budget limit ÔÇö pause and confirm if cost exceeds threshold" } else { 'disabled (use -budget <amount> to set a limit)' })" "Cyan"
$usageLimitMode = if ($autowait) { "autowait (sleep in-process, $waittime min wait)" } elseif ($autoschedule) { "autoschedule (schtasks entry, $waittime min wait)" } else { "manual resume (orchclaude resume)" }
Write-Log "UsageLimit: $usageLimitMode" "Cyan"
if ($profile)  { Write-Log "Profile   : $profile (loaded from $profilesFile)" "Cyan" }
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
    Write-Log "MODEL: haiku (planning)" "DarkCyan"
    $planOutput = Invoke-Claude $planningPrompt "plan" (Resolve-ModelId "light")
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
# PARALLEL AGENTS MODE (4.1)
# ================================================================
if ($agents -gt 1 -and -not $resumeMode) {
    Write-Banner "PARALLEL AGENTS MODE  ($agents agents)" "Cyan"

    # Parse plan for independent tasks
    $allPlanLines      = @(Get-Content $planFile | Where-Object { $_ -match "^\d+" })
    $independentLines  = @($allPlanLines | Where-Object { $_ -match "depends:\s*none" })
    $dependentLines    = @($allPlanLines | Where-Object { $_ -match "depends:" -and $_ -notmatch "depends:\s*none" })

    if ($independentLines.Count -eq 0) {
        Write-Log "No independent tasks (depends: none) found in plan. Falling back to single-agent mode." "Yellow"
        $agents = 1
    } else {
        $numAgents = [math]::Min($agents, $independentLines.Count)
        if ($numAgents -lt $agents) {
            Write-Log "Only $($independentLines.Count) independent task(s) found ÔÇö using $numAgents agent(s)." "Yellow"
        }

        # Split independent tasks round-robin across agents
        $agentTaskGroups = @()
        for ($a = 0; $a -lt $numAgents; $a++) { $agentTaskGroups += ,@() }
        $tIdx = 0
        foreach ($task in $independentLines) {
            $agentTaskGroups[$tIdx % $numAgents] += $task
            $tIdx++
        }

        Write-Log "Independent tasks: $($independentLines.Count)  |  Dependent tasks: $($dependentLines.Count)  |  Agents: $numAgents" "Cyan"

        # Spawn one job per agent
        $agentJobs = @()
        for ($a = 1; $a -le $numAgents; $a++) {
            $agentIdx      = $a
            $agentLogFile  = Join-Path $workDir "orchclaude-log-agent$a.txt"
            $agentWorkSubDir = Join-Path $workDir "agent-$a"

            "orchclaude parallel agent $a log" | Set-Content $agentLogFile -Encoding UTF8
            Add-Content $agentLogFile "Started: $(Get-Date)"
            Add-Content $agentLogFile ""

            if (-not (Test-Path $agentWorkSubDir)) {
                New-Item -ItemType Directory -Path $agentWorkSubDir -Force | Out-Null
            }

            $taskListText = ($agentTaskGroups[$a-1] -join "`n")

            $agentFullPrompt = @"
## PARALLEL AGENT $a of $numAgents

You are one of $numAgents parallel Claude agents working on the same project simultaneously.
Work ONLY on the subtasks assigned to you below. Do NOT implement tasks assigned to other agents.

## YOUR ASSIGNED SUBTASKS:
$taskListText

## FULL PROJECT CONTEXT:
$basePrompt

## YOUR WORKING SUBDIRECTORY:
Create your output files under: $agentWorkSubDir
When referencing the project root, use: $workDir

$orchestrationInstructions

Remember: work ONLY on your assigned subtasks above.
"@

            $job = Start-Job -ScriptBlock {
                param($prompt, $logFile, $agentIdx, $workSubDir, $tokenStr)

                if (-not (Test-Path $workSubDir)) {
                    New-Item -ItemType Directory -Path $workSubDir -Force | Out-Null
                }

                $promptFile = Join-Path $env:TEMP "orchclaude_agent${agentIdx}_$PID.txt"
                $prompt | Set-Content $promptFile -Encoding UTF8

                try {
                    $out = & claude `
                        -p (Get-Content $promptFile -Raw) `
                        --allowedTools "Edit,Bash,Read,Write,Glob,Grep" `
                        --max-turns 50 `
                        --dangerously-skip-permissions `
                        2>&1
                } catch {
                    $out = "ERROR: claude not found ÔÇö $($_.Exception.Message)"
                }

                Remove-Item $promptFile -ErrorAction SilentlyContinue

                Add-Content $logFile "--- Agent $agentIdx Claude output ---"
                Add-Content $logFile $out
                Add-Content $logFile ""
                Add-Content $logFile "Finished: $(Get-Date)"

                return $out

            } -ArgumentList $agentFullPrompt, $agentLogFile, $agentIdx, $agentWorkSubDir, $token

            Write-Log "Agent $a started  |  subtasks: $($agentTaskGroups[$a-1].Count)  |  log: orchclaude-log-agent$a.txt" "Cyan"
            $agentJobs += [PSCustomObject]@{ Job = $job; AgentIdx = $a; LogFile = $agentLogFile; WorkDir = $agentWorkSubDir }
        }

        # Wait for all agents
        Write-Log "Waiting for $($agentJobs.Count) agent(s) to complete..." "Yellow"
        $agentOutputs = @{}
        foreach ($jobInfo in $agentJobs) {
            $elapsed   = ((Get-Date) - $startTime).TotalSeconds
            $remaining = [math]::Max(10, $timeoutSeconds - $elapsed)
            $done      = Wait-Job -Job $jobInfo.Job -Timeout $remaining
            if ($done) {
                $agentOut = Receive-Job -Job $jobInfo.Job
                $agentOutputs[$jobInfo.AgentIdx] = $agentOut
                $totalOutputWords += ([math]::Round(($agentOut -split '\s+' | Where-Object { $_ }).Count))
                Write-Log "Agent $($jobInfo.AgentIdx) finished." "Green"
            } else {
                $agentOutputs[$jobInfo.AgentIdx] = "(AGENT TIMED OUT)"
                Write-Log "Agent $($jobInfo.AgentIdx) timed out." "Red"
                Stop-Job -Job $jobInfo.Job
            }
            Remove-Job -Job $jobInfo.Job -Force
        }

        # Log all agent outputs
        foreach ($idx in ($agentOutputs.Keys | Sort-Object)) {
            Add-Content $logFile "--- Parallel agent $idx output ---"
            Add-Content $logFile $agentOutputs[$idx]
            Add-Content $logFile ""
        }

        # Build combined summary for merge
        $agentSummaryBlocks = ""
        foreach ($idx in ($agentOutputs.Keys | Sort-Object)) {
            $agentSummaryBlocks += "`n`n=== AGENT $idx OUTPUT ===`n$($agentOutputs[$idx])"
        }

        $dependentSection = if ($dependentLines.Count -gt 0) {
            "`n`n## REMAINING DEPENDENT TASKS (not yet done ÔÇö complete these now):`n$($dependentLines -join "`n")"
        } else { "" }

        # ---- Merge phase ----
        $elapsed = ((Get-Date) - $startTime).TotalSeconds
        if ($elapsed -ge $timeoutSeconds) {
            Write-Banner "TIMEOUT before merge phase" "Red"
            Write-Session "timeout" $i
            Show-CostEstimate
            Write-History "timeout" $i
            Show-WorktreeBranchInfo
            exit 1
        }

        Write-Banner "MERGE PHASE" "Cyan"
        Write-Log "Integrating agent outputs..." "Cyan"

        $mergePrompt = @"
## MERGE PHASE ÔÇö Parallel Agent Integration

You are integrating the work of $numAgents parallel agents that each completed different independent subtasks of the same project.

## ORIGINAL TASK:
$basePrompt

## AGENT OUTPUTS:
$agentSummaryBlocks
$dependentSection

## YOUR JOB:
1. Read all files in $workDir and its agent-* subdirectories.
2. Integrate each agent's output into the main project under $workDir.
3. Resolve any conflicts. For conflicts requiring human review, print: CONFLICT: <description>
4. Complete any remaining dependent tasks listed above (they depend on the agents' work).
5. Verify the integrated result is coherent and complete.
6. When done, output exactly: $token
"@

        $totalInputWords += ([math]::Round(($mergePrompt -split '\s+' | Where-Object { $_ }).Count))
        Write-Log "Calling Claude (merge)..." "Cyan"
        Write-Log "MODEL: sonnet (merge)" "DarkCyan"
        $mergeOutput = Invoke-Claude $mergePrompt "merge" (Resolve-ModelId "standard")
        $totalOutputWords += ([math]::Round(($mergeOutput -split '\s+' | Where-Object { $_ }).Count))

        if ($v) { Write-Host $mergeOutput }

        ($mergeOutput -split "`n") | Where-Object { $_ -match "^CONFLICT:" } | ForEach-Object {
            Write-Log $_ "Red"
        }
        ($mergeOutput -split "`n") | Where-Object { $_ -match "^PROGRESS:" } | ForEach-Object {
            Add-Content $progressFile $_
            Write-Log $_ "Green"
        }

        Add-Content $logFile "--- Merge phase ---"
        Add-Content $logFile $mergeOutput
        Add-Content $logFile ""

        if ($mergeOutput -match [regex]::Escape($token)) {
            Write-Banner "Parallel build complete ÔÇö agents merged" "Green"
            $completed = $true
            Write-Session "complete" $i
        } else {
            Write-Banner "Merge phase did not produce completion token — check log" "Red"
            Write-Session "timeout" $i
            Show-CostEstimate
            Write-History "failed" $i
            Show-WorktreeBranchInfo
            exit 1
        }

        # Skip the regular build loop by jumping to QA
        if (-not $noqa) {
            # 7.3: Budget check before QA phase
            Check-Budget $i

            Write-Banner "PHASE 2 - QA + EDGE CASE EVALUATION" "Magenta"
            $elapsed = ((Get-Date) - $startTime).TotalSeconds
            if ($elapsed -ge $timeoutSeconds) {
                Write-Session "timeout" $i
                Write-Banner "TIMEOUT before QA phase could run" "Red"
                Show-CostEstimate
                Write-History "timeout" $i
                Show-WorktreeBranchInfo
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
            $totalInputWords += ([math]::Round(($qaPrompt -split '\s+' | Where-Object { $_ }).Count))
            Write-Log "MODEL: sonnet (QA)" "DarkCyan"
            $qaOut = Invoke-Claude $qaPrompt "qa_parallel" (Resolve-ModelId "standard")
            $totalOutputWords += ([math]::Round(($qaOut -split '\s+' | Where-Object { $_ }).Count))

            if ($v) { Write-Host $qaOut }
            ($qaOut -split "`n") | Where-Object { $_ -match "^QA_FINDING:" }  | ForEach-Object { Write-Log $_ "DarkYellow" }
            ($qaOut -split "`n") | Where-Object { $_ -match "^QA_SUMMARY:" }  | ForEach-Object { Write-Log $_ "Cyan" }
            Add-Content $logFile "--- QA pass (parallel mode) ---"
            Add-Content $logFile $qaOut
            Add-Content $logFile ""
            if ($qaOut -match [regex]::Escape($qaToken)) {
                Write-Log "QA pass complete." "Green"
            } else {
                Write-Log "QA pass did not output $qaToken - check log for details." "Red"
            }
        } else {
            Write-Banner "QA skipped (-noqa flag)" "DarkGray"
        }

        Write-Session "complete" $i
        $totalTime = ((Get-Date) - $startTime).ToString("mm\:ss")
        Show-CostEstimate
        Write-History "complete" $i
        Write-Banner "ALL DONE  |  $totalTime total" "Green"

        if ($useWorktree) {
            Write-Host ""
            $mergeChoice = if ($autowait -or $autoschedule) { Write-Log "Unattended mode - skipping worktree merge, branch preserved." "Yellow"; "n" } else { Read-Host "Merge branch '$worktreeBranch' into '$originalBranch'? (y/n)" }
            if ($mergeChoice -ieq "y") {
                Write-Log "Removing worktree and merging $worktreeBranch into $originalBranch..." "Cyan"
                & git -C $originalWorkDir worktree remove $worktreePath --force 2>&1 | Out-Null
                $mergeResult = & git -C $originalWorkDir merge $worktreeBranch --no-ff -m "orchclaude: merge $worktreeBranch" 2>&1
                if ($LASTEXITCODE -eq 0) {
                    Write-Log "Merge complete. Branch '$worktreeBranch' merged into '$originalBranch'." "Green"
                    & git -C $originalWorkDir branch -d $worktreeBranch 2>&1 | Out-Null
                } else {
                    Write-Log "Merge failed: $mergeResult" "Red"
                    Write-Log "Branch '$worktreeBranch' preserved. Merge manually: git -C `"$originalWorkDir`" merge $worktreeBranch" "Yellow"
                }
            } else {
                Write-Log "Merge skipped. Branch '$worktreeBranch' preserved." "Yellow"
                Write-Log "To merge later: git -C `"$originalWorkDir`" merge $worktreeBranch" "Yellow"
                & git -C $originalWorkDir worktree remove $worktreePath --force 2>&1 | Out-Null
            }
        }
        exit 0
    }
}

# ================================================================
# PHASE 1 - BUILD
# ================================================================
Write-Banner "PHASE 1 - BUILD" "Yellow"

$completed = $false
$failureStreak = 0

# 7.2 ÔÇö Adaptive Escalation state
$escalationFloor     = ""     # "" / "standard" / "heavy"
$escalatedToStandard = $false
$escalatedToHeavy    = $false
$noProgressStreak    = 0      # resets on progress or on each escalation event

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

    # ---- Context Window Guard ----
    $estimatedTokens = [math]::Round((Get-WordCount $fullPrompt) * 1.33)
    if ($estimatedTokens -gt 150000 -and $priorProgress) {
        Write-Log "CONTEXT GUARD: prompt is ~$estimatedTokens tokens - compressing progress log..." "DarkYellow"

        $compressionPrompt = "Summarize these progress notes in 10 concise bullet points. Output only the bullet points, no preamble, no explanation:`n`n$priorProgress"
        $totalInputWords += Get-WordCount $compressionPrompt
        Write-Log "MODEL: haiku (context compression)" "DarkCyan"
        $compressedRaw = Invoke-Claude $compressionPrompt "compress_$iter" (Resolve-ModelId "light")
        $totalOutputWords += Get-WordCount $compressedRaw

        $compressedLines = @($compressedRaw -split "`n" | Where-Object { $_ -match "\S" })
        if ($compressedLines.Count -gt 0) {
            $compressedRaw.Trim() | Set-Content $progressFile -Encoding UTF8
            Write-Log "CONTEXT GUARD: progress compressed to $($compressedLines.Count) lines. Continuing." "DarkYellow"
            Add-Content $logFile "--- Context Guard compression at iteration $iter ---"
            Add-Content $logFile $compressedRaw
            Add-Content $logFile ""

            # Rebuild fullPrompt with compressed progress
            $priorProgress = (Get-Content $progressFile -Raw).Trim()
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
        } else {
            Write-Log "CONTEXT GUARD: compression returned empty result - continuing with original." "Red"
        }
    }

    $buildTier    = if ($model) { $model } else { Get-TaskTier $fullPrompt $iter ($priorProgress -ne "") }

    # 7.2: Apply escalation floor (never let tier drop below floor)
    if (-not $model -and -not $noEscalation) {
        if     ($escalationFloor -eq "heavy"    -and $buildTier -ne "heavy")   { $buildTier = "heavy" }
        elseif ($escalationFloor -eq "standard" -and $buildTier -eq "light")   { $buildTier = "standard" }
    }

    $buildModelId = Resolve-ModelId $buildTier
    $buildLabel   = if ($script:tierLabel.ContainsKey($buildModelId)) { $script:tierLabel[$buildModelId] } else { $buildModelId }
    Write-Log "MODEL: $buildLabel (build iter $iter)" "DarkCyan"
    Add-Content $logFile "[$((Get-Date).ToString('HH:mm:ss'))] MODEL: $buildLabel (build iter $iter)"
    Write-Log "Calling Claude (build)..." "Yellow"

    # 9.1: Capture iteration metrics start
    $iterStartTime = Get-Date
    $iterInputWordCount = Get-WordCount $fullPrompt

    $totalInputWords += Get-WordCount $fullPrompt
    $output = Invoke-Claude $fullPrompt "build_$iter" $buildModelId
    $iterOutputWordCount = Get-WordCount $output
    $totalOutputWords += Get-WordCount $output

    # 9.1: Calculate iteration elapsed time
    $iterElapsedSeconds = ((Get-Date) - $iterStartTime).TotalSeconds

    # ---- 1.6: Usage Limit Detection ----
    if (Test-UsageLimitError $output) {
        $shouldResume = Handle-UsageLimit $iter
        if ($shouldResume) {
            $iter--  # re-run same iteration (for-loop increments before continue)
            continue
        }
        break  # Handle-UsageLimit already exited for non-autowait paths
    }

    if ($v) { Write-Host $output }

    # 9.1: Capture PROGRESS lines from this iteration
    $iterProgressLines = @()
    ($output -split "`n") | Where-Object { $_ -match "^PROGRESS:" } | ForEach-Object {
        Add-Content $progressFile $_
        Write-Log $_ "Green"
        $iterProgressLines += $_
    }

    Add-Content $logFile "--- Build iteration $iter ---"
    Add-Content $logFile $output
    Add-Content $logFile ""

    # Track failure streak (resets when new PROGRESS lines appear)
    $progressCountAfter = if (Test-Path $progressFile) {
        @(Get-Content $progressFile | Where-Object { $_ -match "\S" }).Count
    } else { 0 }

    if ($progressCountAfter -gt $progressCountBefore) {
        $failureStreak    = 0
        $noProgressStreak = 0

        # Auto-Commit Checkpoint (3.2): commit after each iteration with new progress
        if ($useWorktree) {
            $gitStatus = & git -C $worktreePath status --porcelain 2>&1
            if ($gitStatus -match '\S') {
                $allProgressLines = @(Get-Content $progressFile | Where-Object { $_ -match "\S" })
                $lastProgressLine = if ($allProgressLines.Count -gt 0) { $allProgressLines[-1] } else { "iteration $iter" }
                $commitMsg = "orchclaude checkpoint: $lastProgressLine"
                & git -C $worktreePath add -A 2>&1 | Out-Null
                $commitOut = & git -C $worktreePath commit -m $commitMsg 2>&1
                if ($LASTEXITCODE -eq 0) {
                    $commitHash = (& git -C $worktreePath rev-parse --short HEAD 2>&1).Trim()
                    Write-Log "Checkpoint committed [$commitHash]: $lastProgressLine" "DarkCyan"
                    Add-Content $logFile "--- Checkpoint commit $commitHash (iter $iter) ---"
                    Add-Content $logFile $commitOut
                    Add-Content $logFile ""
                } else {
                    Write-Log "Checkpoint commit failed: $commitOut" "DarkYellow"
                }
            }
        }
    } else {
        $failureStreak++
        $noProgressStreak++

        # 7.2: Adaptive Escalation ÔÇö escalate after 2 consecutive no-progress iterations
        if (-not $model -and -not $noEscalation -and $noProgressStreak -ge 2) {
            if ($buildTier -eq "light" -and -not $escalatedToStandard) {
                $escalatedToStandard = $true
                $escalationFloor     = "standard"
                $noProgressStreak    = 0
                $escMsg = "ESCALATED: haiku -> sonnet (no progress after 2 iterations)"
                Write-Log $escMsg "Yellow"
                Add-Content $logFile "[$((Get-Date).ToString('HH:mm:ss'))] $escMsg"
            } elseif ($buildTier -eq "standard" -and -not $escalatedToHeavy) {
                $escalatedToHeavy = $true
                $escalationFloor  = "heavy"
                $noProgressStreak = 0
                $escMsg = "ESCALATED: sonnet -> opus (no progress after 2 iterations)"
                Write-Log $escMsg "Yellow"
                Add-Content $logFile "[$((Get-Date).ToString('HH:mm:ss'))] $escMsg"
            }
        }
    }

    # 9.1: Write iteration metrics
    $iterStatus = if ($progressCountAfter -gt $progressCountBefore) {
        "success"
    } elseif ($escalatedToStandard -and $buildTier -eq "light") {
        "escalated"
    } elseif ($escalatedToHeavy -and $buildTier -eq "standard") {
        "escalated"
    } else {
        "retry"
    }
    Write-Metrics $iter $buildLabel $iterStartTime $iterElapsedSeconds $iterInputWordCount $iterOutputWordCount ($progressCountAfter -gt $progressCountBefore) $iterProgressLines $iterStatus

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

        if ($autowait -or $autoschedule) {
            Write-Log "CIRCUIT BREAKER: unattended mode - auto-continuing." "Yellow"
            $failureStreak = 0
        } else {

        $userChoice = Read-Host "Continue? (y/n/new prompt)"

        if ($userChoice -eq "n") {
            Write-Log "User stopped run at circuit breaker." "Red"
            Write-Session "timeout" $iter
            Show-CostEstimate
            Write-History "failed" $iter
            Show-WorktreeBranchInfo
            exit 1
        } elseif ($userChoice -eq "" -or $userChoice -eq "y") {
            Write-Log "User chose to continue. Resetting failure streak." "Cyan"
            $failureStreak = 0
        } else {
            $basePrompt = $basePrompt + "`n`n## Additional instruction from user:`n" + $userChoice
            Write-Log "User added prompt: $userChoice" "Cyan"
            $failureStreak = 0
        }
        } # end else (not unattended)
    }

    # 7.3: Budget check before next iteration
    Check-Budget $iter

    Write-Log "Token not found. Looping..." "Magenta"
    if ($cooldown -gt 0) { Start-Sleep -Seconds $cooldown }
}

if (-not $completed) {
    Write-Session "timeout" $i
    Write-Banner "BUILD INCOMPLETE - did not finish. See log: $logFile" "Red"
    Show-CostEstimate
    Write-History "timeout" $i
    Show-WorktreeBranchInfo
    Write-Host "  Run 'orchclaude resume' to continue this session." -ForegroundColor Yellow
    exit 1
}

# ================================================================
# PHASE 2 - QA
# ================================================================
if ($noqa) {
    Write-Banner "QA skipped (-noqa flag)" "DarkGray"
} else {
    # 7.3: Budget check before QA phase
    Check-Budget $i

    Write-Banner "PHASE 2 - QA + EDGE CASE EVALUATION" "Magenta"

    $elapsed = ((Get-Date) - $startTime).TotalSeconds
    if ($elapsed -ge $timeoutSeconds) {
        Write-Session "timeout" $i
        Write-Banner "TIMEOUT before QA phase could run" "Red"
        Show-CostEstimate
        Write-History "timeout" $i
        Show-WorktreeBranchInfo
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
    Write-Log "MODEL: sonnet (QA)" "DarkCyan"
    $output = Invoke-Claude $qaPrompt "qa" (Resolve-ModelId "standard")
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
Write-History "complete" $i
Write-Banner "ALL DONE  |  $totalTime total" "Green"

if ($useWorktree) {
    Write-Host ""
    $mergeChoice = if ($autowait -or $autoschedule) { Write-Log "Unattended mode - skipping worktree merge, branch preserved." "Yellow"; "n" } else { Read-Host "Merge branch '$worktreeBranch' into '$originalBranch'? (y/n)" }
    if ($mergeChoice -ieq "y") {
        Write-Log "Removing worktree and merging $worktreeBranch into $originalBranch..." "Cyan"
        & git -C $originalWorkDir worktree remove $worktreePath --force 2>&1 | Out-Null
        $mergeResult = & git -C $originalWorkDir merge $worktreeBranch --no-ff -m "orchclaude: merge $worktreeBranch" 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Log "Merge complete. Branch '$worktreeBranch' merged into '$originalBranch'." "Green"
            & git -C $originalWorkDir branch -d $worktreeBranch 2>&1 | Out-Null
        } else {
            Write-Log "Merge failed: $mergeResult" "Red"
            Write-Log "Branch '$worktreeBranch' preserved. Merge manually: git -C `"$originalWorkDir`" merge $worktreeBranch" "Yellow"
        }
    } else {
        Write-Log "Merge skipped. Branch '$worktreeBranch' preserved." "Yellow"
        Write-Log "To merge later: git -C `"$originalWorkDir`" merge $worktreeBranch" "Yellow"
        & git -C $originalWorkDir worktree remove $worktreePath --force 2>&1 | Out-Null
    }
}
