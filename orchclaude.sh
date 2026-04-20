#!/usr/bin/env bash
# orchclaude.sh - Claude Code Orchestrator CLI (Linux / macOS)
# Usage: orchclaude run "prompt" -t 30m
#        orchclaude run -f project.md -t 2h
#        orchclaude run "prompt" -t 1h -i 60 -v -d "/path/to/project"
#        orchclaude resume          (continue an interrupted run)
#        orchclaude status          (show current session state)
#
# Requires: bash 3.2+, python3 (for JSON), claude (Claude Code CLI)
# Optional: git (for worktree isolation)

# ------------------------------------------------------------------ #
# ANSI colour codes
# ------------------------------------------------------------------ #
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
DGRAY='\033[0;90m'
DYELLOW='\033[0;33m'
DCYAN='\033[0;36m'
NC='\033[0m'

# ------------------------------------------------------------------ #
# Utility functions
# ------------------------------------------------------------------ #
LOG_FILE="/dev/null"   # overwritten once work dir is known

write_log() {
    local msg="$1" color="${2:-}"
    local ts line
    ts=$(date '+%H:%M:%S')
    line="[$ts] $msg"
    if [[ -n "$color" ]]; then
        printf "${color}%s${NC}\n" "$line"
    else
        printf "%s\n" "$line"
    fi
    echo "$line" >> "$LOG_FILE"
}

write_banner() {
    local text="$1" color="${2:-$CYAN}"
    printf "\n"
    printf "${color}%s${NC}\n" "======================================================="
    printf "${color}  %s${NC}\n" "$text"
    printf "${color}%s${NC}\n" "======================================================="
    printf "\n"
}

get_word_count() {
    echo "${1:-}" | wc -w | tr -d '[:space:]'
}

get_estimated_cost() {
    python3 - <<PYEOF
iw = $TOTAL_INPUT_WORDS
ow = $TOTAL_OUTPUT_WORDS
it = round(iw * 1.33)
ot = round(ow * 1.33)
ic = round(it / 1_000_000 * 3,  4)
oc = round(ot / 1_000_000 * 15, 4)
print(round(ic + oc, 4))
PYEOF
}

show_cost_estimate() {
    python3 - <<PYEOF
iw = $TOTAL_INPUT_WORDS
ow = $TOTAL_OUTPUT_WORDS
it = round(iw * 1.33)
ot = round(ow * 1.33)
ic = round(it / 1_000_000 * 3,  4)
oc = round(ot / 1_000_000 * 15, 4)
tc = round(ic + oc, 4)
print(f"Estimated usage: ~{it} tokens input, ~{ot} tokens output | Estimated cost: ~\${tc} (estimate only)")
PYEOF
}

check_budget() {
    local current_iter="${1:-0}"
    [[ "$BUDGET" == "0" || -z "$BUDGET" ]] && return
    local current_cost over
    current_cost=$(get_estimated_cost)
    over=$(python3 -c "print('yes' if $current_cost > $BUDGET else 'no')" 2>/dev/null || echo "no")
    if [[ "$over" == "yes" ]]; then
        printf "\n"
        write_log "BUDGET EXCEEDED: estimated cost \$$current_cost exceeds budget \$$BUDGET" "$RED"
        read -r -p "Continue? (y/n): " budget_choice
        if [[ "${budget_choice,,}" == "n" ]]; then
            write_log "User stopped run at budget limit (\$$current_cost > \$$BUDGET)." "$RED"
            show_cost_estimate
            write_session "timeout" "$current_iter"
            show_worktree_branch_info
            send_webhook "failed"
            write_history "failed"
            exit 1
        else
            BUDGET=$(python3 -c "print(round($BUDGET * 2, 4))" 2>/dev/null || echo "$(( ${BUDGET%.*} * 2 ))")
            write_log "Budget doubled to \$$BUDGET. Continuing." "$YELLOW"
        fi
    fi
}

invoke_claude() {
    local prompt="$1" label="$2" model_id="${3:-}"
    local pfile
    pfile=$(mktemp "/tmp/orchclaude_prompt_$$_${label}.XXXXXX")
    printf '%s' "$prompt" > "$pfile"
    local model_args=()
    [[ -n "$model_id" ]] && model_args=(--model "$model_id")
    local out
    out=$(claude -p "$(cat "$pfile")" \
        --allowedTools "Edit,Bash,Read,Write,Glob,Grep" \
        --max-turns 50 "${model_args[@]}" 2>&1) || true
    rm -f "$pfile"
    printf '%s' "$out"
}

# ---- Model tier map (7.1) ----
MODEL_LIGHT="claude-haiku-4-5-20251001"
MODEL_STANDARD="claude-sonnet-4-6"
MODEL_HEAVY="claude-opus-4-7"

resolve_model_id() {
    local tier="$1"
    if [[ -n "$MODEL_OVERRIDE" ]]; then
        case "$MODEL_OVERRIDE" in
            light)    printf '%s' "$MODEL_LIGHT";    return ;;
            standard) printf '%s' "$MODEL_STANDARD"; return ;;
            heavy)    printf '%s' "$MODEL_HEAVY";    return ;;
            *)        printf '%s' "$MODEL_OVERRIDE"; return ;;
        esac
    fi
    case "$tier" in
        light)    printf '%s' "$MODEL_LIGHT" ;;
        heavy)    printf '%s' "$MODEL_HEAVY" ;;
        *)        printf '%s' "$MODEL_STANDARD" ;;
    esac
}

tier_label() {
    local model_id="$1"
    case "$model_id" in
        claude-haiku-4-5*) printf "haiku" ;;
        claude-sonnet-4-6) printf "sonnet" ;;
        claude-opus-4-7)   printf "opus" ;;
        *)                 printf "%s" "$model_id" ;;
    esac
}

get_task_tier() {
    local prompt="$1" iter_num="$2" has_prior="$3"
    # First iteration of brand-new project
    if [[ "$iter_num" -eq 1 && "$has_prior" == "false" ]]; then
        printf "heavy"; return
    fi
    local excerpt="${prompt:0:600}"
    local classify_prompt="Classify this software task as LIGHT, STANDARD, or HEAVY. Output only one word.
LIGHT=reading/planning/summarizing/simple files. STANDARD=general coding. HEAVY=architecture/complex debugging/security.
Task: $excerpt"
    local raw
    raw=$(claude -p "$classify_prompt" --model "$MODEL_LIGHT" --max-turns 1 2>&1) || true
    if echo "$raw" | grep -qw "HEAVY"; then printf "heavy"; return; fi
    if echo "$raw" | grep -qw "LIGHT";  then printf "light";  return; fi
    printf "standard"
}

show_worktree_branch_info() {
    [[ "$USE_WORKTREE" != "true" ]] && return
    write_log "Worktree branch '$WORKTREE_BRANCH' left intact for inspection." "$YELLOW"
    write_log "Worktree path  : $WORKTREE_PATH" "$YELLOW"
    write_log "To merge later : git -C \"$ORIGINAL_WORK_DIR\" merge $WORKTREE_BRANCH" "$YELLOW"
}

send_webhook() {
    local status="$1"
    [[ -z "$WEBHOOK_URL" ]] && return
    [[ "$WEBHOOK_SENT" == "true" ]] && return
    WEBHOOK_SENT=true

    local elapsed_min last_prog prog_count cost msg payload
    elapsed_min=$(python3 -c "import time; print(round((time.time() - $START_EPOCH) / 60, 1))" 2>/dev/null || echo "?")
    cost=$(python3 -c "
iw=$TOTAL_INPUT_WORDS; ow=$TOTAL_OUTPUT_WORDS
it=round(iw*1.33); ot=round(ow*1.33)
print(round(it/1000000*3 + ot/1000000*15, 4))
" 2>/dev/null || echo "?")
    last_prog="(none)"
    prog_count=0
    if [[ -f "$PROGRESS_FILE" ]]; then
        prog_count=$(grep -c '\S' "$PROGRESS_FILE" 2>/dev/null || echo 0)
        last_prog=$(grep '\S' "$PROGRESS_FILE" 2>/dev/null | tail -1 || echo "(none)")
    fi

    case "$status" in
        complete) emoji=":white_check_mark:" ;;
        timeout)  emoji=":hourglass:" ;;
        *)        emoji=":x:" ;;
    esac

    msg="$emoji orchclaude run $status
Work dir: $WORK_DIR
Elapsed: ${elapsed_min}m
Progress lines: $prog_count
Estimated cost: \$$cost
Last progress: $last_prog"

    if echo "$WEBHOOK_URL" | grep -q "discord"; then
        payload=$(python3 -c "import json,sys; print(json.dumps({'content': sys.argv[1]}))" "$msg" 2>/dev/null || echo '{"content":"orchclaude run finished"}')
    else
        payload=$(python3 -c "import json,sys; print(json.dumps({'text': sys.argv[1]}))" "$msg" 2>/dev/null || echo '{"text":"orchclaude run finished"}')
    fi

    if command -v curl &>/dev/null; then
        curl -s -X POST -H "Content-Type: application/json; charset=utf-8" -d "$payload" "$WEBHOOK_URL" >/dev/null 2>&1 &&             write_log "Webhook sent ($status)." "$DGRAY" ||             write_log "Webhook send failed." "$YELLOW"
    else
        write_log "Webhook skipped: curl not available." "$YELLOW"
    fi
}

WEBHOOK_SENT=false

write_history() {
    local status="$1"
    local hist_dir="$HOME/.orchclaude"
    local hist_file="$hist_dir/history.json"
    mkdir -p "$hist_dir" 2>/dev/null || true
    OC_STATUS="$status" \
    OC_HIST_FILE="$hist_file" \
    OC_START_EPOCH="$START_EPOCH" \
    OC_INPUT_WORDS="$TOTAL_INPUT_WORDS" \
    OC_OUTPUT_WORDS="$TOTAL_OUTPUT_WORDS" \
    OC_PROGRESS_FILE="$PROGRESS_FILE" \
    OC_SESSION_FILE="$SESSION_FILE" \
    OC_WORK_DIR="$WORK_DIR" \
    OC_BASE_PROMPT="$BASE_PROMPT" \
    python3 - <<'PYEOF' 2>/dev/null || true
import json, os
from datetime import datetime, timezone

start_epoch = float(os.environ.get("OC_START_EPOCH", "0") or "0")
elapsed_min = round((datetime.now(timezone.utc).timestamp() - start_epoch) / 60, 1) if start_epoch else 0

iw = float(os.environ.get("OC_INPUT_WORDS",  "0") or "0")
ow = float(os.environ.get("OC_OUTPUT_WORDS", "0") or "0")
it = round(iw * 1.33); ot = round(ow * 1.33)
cost = round(it / 1_000_000 * 3 + ot / 1_000_000 * 15, 4)

last_prog = ""; prog_count = 0
progress_file = os.environ.get("OC_PROGRESS_FILE", "")
if progress_file and os.path.exists(progress_file):
    with open(progress_file, encoding="utf-8", errors="replace") as f:
        lines = [l.rstrip("\n") for l in f if l.strip()]
    prog_count = len(lines)
    last_prog = lines[-1] if lines else ""

iter_count = 0
session_file = os.environ.get("OC_SESSION_FILE", "")
if session_file and os.path.exists(session_file):
    try:
        with open(session_file, encoding="utf-8") as f:
            s = json.load(f)
        iter_count = int(s.get("currentIteration", 0))
    except Exception:
        pass

base_prompt = os.environ.get("OC_BASE_PROMPT", "") or ""
excerpt = base_prompt[:120] + ("..." if len(base_prompt) > 120 else "")
excerpt = excerpt.replace("\n", " ").replace("\r", "")

run_id = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S") + "-" + os.urandom(3).hex()

entry = {
    "id": run_id,
    "date": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "workDir": os.environ.get("OC_WORK_DIR", ""),
    "promptExcerpt": excerpt,
    "status": os.environ.get("OC_STATUS", "unknown"),
    "iterations": iter_count,
    "durationMinutes": elapsed_min,
    "estimatedCostUSD": cost,
    "progressCount": prog_count,
    "lastProgress": last_prog,
}

hist_file = os.environ["OC_HIST_FILE"]
history = []
if os.path.exists(hist_file):
    try:
        with open(hist_file, encoding="utf-8") as f:
            raw = json.load(f)
        history = raw if isinstance(raw, list) else [raw]
    except Exception:
        pass

history = [entry] + history
if len(history) > 200:
    history = history[:200]

with open(hist_file, "w", encoding="utf-8") as f:
    json.dump(history, f, indent=2, ensure_ascii=False)
PYEOF
}

test_usage_limit_error() {
    local text="$1"
    [[ -z "$text" ]] && return 1
    if echo "$text" | grep -qF "Claude AI usage limit reached"; then return 0; fi
    if echo "$text" | grep -qF "rate_limit_error"; then return 0; fi
    if echo "$text" | grep -qF "overloaded_error"; then return 0; fi
    if echo "$text" | grep -qF "exceeded your current quota"; then return 0; fi
    if echo "$text" | grep -qF "You have reached your usage limit"; then return 0; fi
    if echo "$text" | grep -qi "usage limit"; then return 0; fi
    return 1
}

handle_usage_limit() {
    local current_iter="$1"
    local now_ts resume_ts
    now_ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    resume_ts=$(python3 -c "
from datetime import datetime, timezone, timedelta
now = datetime.now(timezone.utc)
resume = now + timedelta(minutes=$WAITTIME)
print(resume.strftime('%Y-%m-%dT%H:%M:%SZ'))
" 2>/dev/null || echo "")
    local resume_time_display
    resume_time_display=$(python3 -c "
from datetime import datetime, timezone, timedelta
now = datetime.now(timezone.utc)
resume = now + timedelta(minutes=$WAITTIME)
print(resume.strftime('%H:%M:%S'))
" 2>/dev/null || echo "?")

    printf "\n"
    write_log "USAGE LIMIT HIT: Claude usage limit detected at $(date +%H:%M:%S)." "$RED"
    write_log "Resume possible at $resume_time_display ($WAITTIME minutes from now)." "$YELLOW"

    # Save state
    local progress_json="[]"
    if [[ -f "$PROGRESS_FILE" ]]; then
        progress_json=$(grep -E '\S' "$PROGRESS_FILE" 2>/dev/null \
            | python3 -c "import sys,json; print(json.dumps([l.rstrip('\n') for l in sys.stdin]))" \
            2>/dev/null || echo "[]")
    fi
    local prompt_json
    prompt_json=$(printf '%s' "$BASE_PROMPT" | json_dumps_string 2>/dev/null || echo '""')
    local token_json
    token_json=$(printf '%s' "$TOKEN" | json_dumps_string 2>/dev/null || echo '"ORCHESTRATION_COMPLETE"')

    python3 - > "$SESSION_FILE" 2>/dev/null <<PYEOF
import json
data = {
    "startTime": "$START_TIME",
    "lastUpdated": "$now_ts",
    "status": "usage_limit_paused",
    "currentIteration": $current_iter,
    "prompt": $prompt_json,
    "resumeAfter": "$resume_ts",
    "pausedAt": "$now_ts",
    "flags": {
        "t": "$T",
        "i": $I,
        "noqa": $( [[ "$NOQA" == "true" ]] && echo "True" || echo "False"),
        "token": $token_json,
        "v": $( [[ "$V" == "true" ]] && echo "True" || echo "False"),
        "cooldown": $COOLDOWN,
        "breaker": $BREAKER,
    },
    "progressLines": $progress_json,
}
print(json.dumps(data, indent=2))
PYEOF
    echo "[$(date +%H:%M:%S)] USAGE_LIMIT_PAUSED: iteration $current_iter, resumeAfter=$resume_ts" >> "$LOG_FILE"

    if [[ "$AUTOWAIT" == "true" ]]; then
        local total_wait_secs=$(( WAITTIME * 60 ))
        local interval_secs=600
        local slept=0
        while [[ "$slept" -lt "$total_wait_secs" ]]; do
            local remaining=$(( total_wait_secs - slept ))
            local rem_h=$(( remaining / 3600 ))
            local rem_m=$(( (remaining % 3600) / 60 ))
            write_log "Resuming in ${rem_h}h ${rem_m}m... (Ctrl+C to interrupt — session is saved)" "$YELLOW"
            local sleep_for=$interval_secs
            [[ "$sleep_for" -gt "$remaining" ]] && sleep_for=$remaining
            sleep "$sleep_for"
            slept=$(( slept + sleep_for ))
        done
        write_log "Resuming now..." "$GREEN"
        return 0  # signal: continue the loop
    elif [[ "$AUTOSCHEDULE" == "true" ]]; then
        local script_path
        script_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/orchclaude.sh"
        # On Linux/macOS use 'at' if available, otherwise inform user
        if command -v at > /dev/null 2>&1; then
            local at_time
            at_time=$(python3 -c "
from datetime import datetime, timezone, timedelta
resume = datetime.now(timezone.utc) + timedelta(minutes=$WAITTIME)
print(resume.strftime('%H:%M'))
" 2>/dev/null || echo "now + ${WAITTIME} minutes")
            echo "bash \"$script_path\" resume -d \"$WORK_DIR\"" | at "$at_time" 2>/dev/null
            if [[ $? -eq 0 ]]; then
                write_log "Scheduled resume at $at_time via 'at'. Safe to close this terminal." "$GREEN"
            else
                write_log "Failed to schedule with 'at'. Run manually: orchclaude resume -d \"$WORK_DIR\"" "$YELLOW"
            fi
        else
            write_log "'at' command not found. Add a cron entry or run manually: orchclaude resume -d \"$WORK_DIR\"" "$YELLOW"
        fi
        show_cost_estimate
        exit 0
    else
        write_log "Session saved. Run 'orchclaude resume' to continue once the limit resets (~$WAITTIME min)." "$YELLOW"
        write_log "Expected reset at: $resume_time_display" "$YELLOW"
        show_cost_estimate
        show_worktree_branch_info
        exit 0
    fi
}

# ------------------------------------------------------------------ #
# JSON helpers (requires python3)
# ------------------------------------------------------------------ #
json_dumps_string() {
    # Emit a JSON-encoded string for the value passed on stdin
    python3 -c "import sys,json; print(json.dumps(sys.stdin.read().rstrip('\n')))"
}

write_session() {
    local status="$1" current_iter="$2"
    local progress_json="[]"
    if [[ -f "$PROGRESS_FILE" ]]; then
        progress_json=$(grep -E '\S' "$PROGRESS_FILE" 2>/dev/null \
            | python3 -c "import sys,json; print(json.dumps([l.rstrip('\n') for l in sys.stdin]))" \
            2>/dev/null || echo "[]")
    fi
    local prompt_json
    prompt_json=$(printf '%s' "$BASE_PROMPT" | json_dumps_string 2>/dev/null || echo '""')
    local token_json
    token_json=$(printf '%s' "$TOKEN" | json_dumps_string 2>/dev/null || echo '"ORCHESTRATION_COMPLETE"')

    python3 - > "$SESSION_FILE" 2>/dev/null <<PYEOF
import json
from datetime import datetime, timezone
now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
data = {
    "startTime": "$START_TIME",
    "lastUpdated": now,
    "status": "$status",
    "currentIteration": $current_iter,
    "prompt": $prompt_json,
    "flags": {
        "t": "$T",
        "i": $I,
        "noqa": $( [[ "$NOQA" == "true" ]] && echo "True" || echo "False"),
        "token": $token_json,
        "v": $( [[ "$V" == "true" ]] && echo "True" || echo "False"),
        "cooldown": $COOLDOWN,
        "breaker": $BREAKER,
    },
    "progressLines": $progress_json,
    "startCommit": "$START_COMMIT",
    "originalWorkDir": "$ORIGINAL_WORK_DIR",
    "worktreeBranch": "$WORKTREE_BRANCH",
}
print(json.dumps(data, indent=2))
PYEOF
}

# ------------------------------------------------------------------ #
# Profile helpers
# ------------------------------------------------------------------ #
PROFILES_DIR="$HOME/.orchclaude"
PROFILES_FILE="$PROFILES_DIR/profiles.json"

get_profiles_json() {
    if [[ ! -f "$PROFILES_FILE" ]]; then echo "{}"; return; fi
    python3 -c "import json; print(json.dumps(json.load(open('$PROFILES_FILE'))))" 2>/dev/null || echo "{}"
}

save_profiles_json() {
    local json="$1"
    mkdir -p "$PROFILES_DIR"
    printf '%s\n' "$json" > "$PROFILES_FILE"
}

profile_exists() {
    local name="$1"
    ORCHCLAUDE_PROFILE_NAME="$name" python3 -c "
import json, sys, os
pf = os.environ.get('PROFILES_FILE', '')
d = json.load(open('$PROFILES_FILE')) if __import__('os').path.exists('$PROFILES_FILE') else {}
sys.exit(0 if os.environ.get('ORCHCLAUDE_PROFILE_NAME','') in d else 1)
" 2>/dev/null
}

# ------------------------------------------------------------------ #
# Parse command and arguments
# ------------------------------------------------------------------ #
COMMAND="${1:-run}"
[[ $# -gt 0 ]] && shift || true

# Defaults
PROMPT_ARG=""
F=""
T="30m"
I=40
V=false
D=""
NOQA=false
TOKEN="ORCHESTRATION_COMPLETE"
COOLDOWN=5
BREAKER=10
DRYRUN=false
NOPLAN=false
NOBRANCH=false
PROFILE_NAME=""
AGENTS=1
MODEL_OVERRIDE=""
BUDGET=0
MODEL_PROFILE=""
SUBARG=""
SHOW_HELP=false
AUTOWAIT=false
AUTOSCHEDULE=false
WAITTIME=300
WEBHOOK_URL=""
HISTORY_N=20

# CLI tracking: true when flag was explicitly passed on command line
_CLI_T=false; _CLI_I=false; _CLI_V=false; _CLI_D=false; _CLI_NOQA=false
_CLI_TOKEN=false; _CLI_COOLDOWN=false; _CLI_BREAKER=false; _CLI_NOPLAN=false
_CLI_NOBRANCH=false; _CLI_AGENTS=false; _CLI_MODEL=false; _CLI_BUDGET=false
_CLI_MODELPROFILE=false; _CLI_AUTOWAIT=false; _CLI_AUTOSCHEDULE=false
_CLI_WAITTIME=false; _CLI_WEBHOOK=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        -f)        F="${2:-}";                         shift 2 ;;
        -t)        T="${2:-}"; _CLI_T=true;            shift 2 ;;
        -i)        I="${2:-}"; _CLI_I=true;            shift 2 ;;
        -v)        V=true;     _CLI_V=true;            shift   ;;
        -d)        D="${2:-}"; _CLI_D=true;            shift 2 ;;
        -noqa)     NOQA=true;  _CLI_NOQA=true;         shift   ;;
        -token)    TOKEN="${2:-}";    _CLI_TOKEN=true;  shift 2 ;;
        -cooldown) COOLDOWN="${2:-}"; _CLI_COOLDOWN=true; shift 2 ;;
        -breaker)  BREAKER="${2:-}";  _CLI_BREAKER=true;  shift 2 ;;
        -dryrun)   DRYRUN=true;                        shift   ;;
        -noplan)   NOPLAN=true;  _CLI_NOPLAN=true;     shift   ;;
        -nobranch) NOBRANCH=true; _CLI_NOBRANCH=true;  shift   ;;
        -profile)  PROFILE_NAME="${2:-}";              shift 2 ;;
        -agents)   AGENTS="${2:-}";    _CLI_AGENTS=true;      shift 2 ;;
        -model)        MODEL_OVERRIDE="${2:-}"; _CLI_MODEL=true;        shift 2 ;;
        -budget)       BUDGET="${2:-}";         _CLI_BUDGET=true;       shift 2 ;;
        -modelprofile) MODEL_PROFILE="${2:-}";  _CLI_MODELPROFILE=true; shift 2 ;;
        -autowait)     AUTOWAIT=true;           _CLI_AUTOWAIT=true;     shift   ;;
        -autoschedule) AUTOSCHEDULE=true;       _CLI_AUTOSCHEDULE=true; shift   ;;
        -waittime)     WAITTIME="${2:-300}";    _CLI_WAITTIME=true;     shift 2 ;;
        -webhook)      WEBHOOK_URL="${2:-}";    _CLI_WEBHOOK=true;      shift 2 ;;
        -n)            HISTORY_N="${2:-20}";                            shift 2 ;;
        --help|-help|-h) SHOW_HELP=true; shift   ;;
        -*)
            printf "${RED}Unknown flag: %s${NC}\n" "$1" >&2
            exit 1
            ;;
        *)
            if [[ -z "$PROMPT_ARG" ]]; then
                PROMPT_ARG="$1"
            elif [[ -z "$SUBARG" ]]; then
                SUBARG="$1"
            fi
            shift ;;
    esac
done

# ------------------------------------------------------------------ #
# Help
# ------------------------------------------------------------------ #
if [[ "$COMMAND" == "help" || "$COMMAND" == "-h" || "$SHOW_HELP" == "true" ]]; then
    GUIDE="$HOME/ORCHCLAUDE-GUIDE.md"
    if [[ -f "$GUIDE" ]]; then
        cat "$GUIDE"
    else
        printf "${CYAN}orchclaude — Claude Code Orchestrator${NC}\n"
        printf "\nUsage:\n"
        printf "  orchclaude run \"prompt\" -t 30m\n"
        printf "  orchclaude run -f project.md -t 2h\n"
        printf "  orchclaude resume\n"
        printf "  orchclaude status\n"
        printf "\nCommands: run, resume, status, explain, diff, template, history, help, profile\n"
        printf "Flags: -t -i -f -d -v -noqa -token -cooldown -breaker -dryrun -noplan -nobranch -profile -agents -model -budget -modelprofile -autowait -autoschedule -waittime -webhook\n"
        printf "Profiles: orchclaude profile save <name> [flags]\n"
        printf "          orchclaude profile list\n"
        printf "          orchclaude profile delete <name>\n"
    fi
    exit 0
fi

# ------------------------------------------------------------------ #
# Profile command
# ------------------------------------------------------------------ #
if [[ "$COMMAND" == "profile" ]]; then
    subcmd="${PROMPT_ARG,,}"  # lowercase
    case "$subcmd" in
        save)
            if [[ -z "$SUBARG" ]]; then
                printf "${RED}Usage: orchclaude profile save <name> [flags...]${NC}\n" >&2
                exit 1
            fi
            profiles_json=$(get_profiles_json)
            updated=$(ORCHCLAUDE_PROFILE_NAME="$SUBARG" python3 - <<PYEOF
import json, sys, os
d = $profiles_json
name = os.environ.get('ORCHCLAUDE_PROFILE_NAME', '')
d[name] = {
    "t": "$T",
    "i": $I,
    "d": "$D",
    "v": $( [[ "$V" == "true" ]] && echo "True" || echo "False"),
    "noqa": $( [[ "$NOQA" == "true" ]] && echo "True" || echo "False"),
    "token": $(printf '%s' "$TOKEN" | json_dumps_string),
    "cooldown": $COOLDOWN,
    "breaker": $BREAKER,
    "noplan": $( [[ "$NOPLAN" == "true" ]] && echo "True" || echo "False"),
    "nobranch": $( [[ "$NOBRANCH" == "true" ]] && echo "True" || echo "False"),
    "agents": $AGENTS,
    "webhook": $(printf '%s' "$WEBHOOK_URL" | json_dumps_string),
}
print(json.dumps(d, indent=2))
PYEOF
)
            save_profiles_json "$updated"
            printf "${GREEN}Profile '%s' saved to %s${NC}\n" "$SUBARG" "$PROFILES_FILE"
            exit 0
            ;;
        list)
            profiles_json=$(get_profiles_json)
            python3 - <<PYEOF
import json
d = $profiles_json
if not d:
    print("No profiles saved. Use: orchclaude profile save <name> [flags...]")
else:
    print("\nSaved profiles:")
    print("-" * 45)
    for name in sorted(d):
        p = d[name]
        print(f"  {name}")
        print(f"    t={p.get('t','30m')}  i={p.get('i',40)}  cooldown={p.get('cooldown',5)}  breaker={p.get('breaker',10)}  noqa={p.get('noqa',False)}  noplan={p.get('noplan',False)}")
        if p.get('d'):
            print(f"    d={p['d']}")
    print()
PYEOF
            exit 0
            ;;
        delete)
            if [[ -z "$SUBARG" ]]; then
                printf "${RED}Usage: orchclaude profile delete <name>${NC}\n" >&2
                exit 1
            fi
            if ! profile_exists "$SUBARG"; then
                printf "${RED}Profile '%s' not found.${NC}\n" "$SUBARG" >&2
                exit 1
            fi
            profiles_json=$(get_profiles_json)
            updated=$(ORCHCLAUDE_PROFILE_NAME="$SUBARG" python3 -c "
import json, os
d = $profiles_json
d.pop(os.environ.get('ORCHCLAUDE_PROFILE_NAME',''), None)
print(json.dumps(d, indent=2))
")
            save_profiles_json "$updated"
            printf "${GREEN}Profile '%s' deleted.${NC}\n" "$SUBARG"
            exit 0
            ;;
        *)
            printf "${RED}Unknown profile subcommand '%s'. Use: save, list, delete${NC}\n" "$subcmd" >&2
            exit 1
            ;;
    esac
fi

# ------------------------------------------------------------------ #
# Status command
# ------------------------------------------------------------------ #
if [[ "$COMMAND" == "status" ]]; then
    WORK_DIR="${D:-$(pwd)}"
    SESSION_FILE="$WORK_DIR/orchclaude-session.json"
    if [[ ! -f "$SESSION_FILE" ]]; then
        printf "${YELLOW}No session file found in %s${NC}\n" "$WORK_DIR"
        exit 0
    fi
    python3 - <<PYEOF
import json
from datetime import datetime, timezone
d = json.load(open("$SESSION_FILE"))
started = d.get("startTime","")
status  = d.get("status","unknown")
cur_i   = d.get("currentIteration", 0)
max_i   = d.get("flags",{}).get("i",40)
lines   = d.get("progressLines",[])
last_p  = lines[-1] if lines else "(none)"
try:
    dt = datetime.fromisoformat(started.replace("Z","+00:00"))
    elapsed = round((datetime.now(timezone.utc) - dt).total_seconds() / 60, 1)
except:
    elapsed = "?"
colors = {"running":"\033[1;33m","complete":"\033[0;32m","timeout":"\033[0;31m"}
c = colors.get(status,"\033[1;37m")
NC = "\033[0m"
print()
print(f"\033[0;36morchclaude session status{NC}")
print("-" * 40)
print(f"{c}Status        : {status}{NC}")
print(f"Started       : {started}")
print(f"Iteration     : {cur_i} / {max_i}")
print(f"Elapsed total : {elapsed}m")
print(f"Last progress : {last_p}")
print()
PYEOF
    exit 0
fi

# ------------------------------------------------------------------ #
# Explain command
# ------------------------------------------------------------------ #
if [[ "$COMMAND" == "explain" ]]; then
    WORK_DIR="${D:-$(pwd)}"
    SESSION_FILE="$WORK_DIR/orchclaude-session.json"

    printf "\n${CYAN}%s${NC}\n" "======================================================="
    printf "${CYAN}  orchclaude explain${NC}\n"
    printf "${CYAN}%s${NC}\n" "======================================================="
    printf "  Directory : %s\n" "$WORK_DIR"
    printf "  Mode      : read-only (no file changes)\n"
    printf "${CYAN}%s${NC}\n\n" "======================================================="

    SESSION_CONTEXT=""
    if [[ -f "$SESSION_FILE" ]]; then
        SESSION_CONTEXT=$(python3 - <<PYEOF 2>/dev/null
import json
try:
    d = json.load(open("$SESSION_FILE"))
    status = d.get("status","unknown")
    iters  = d.get("currentIteration", 0)
    lines  = d.get("progressLines", [])
    ctx = f"\n\n## Context from last orchclaude run\nStatus: {status}  |  Iterations: {iters}"
    if lines:
        ctx += "\nProgress logged:\n" + "\n".join(lines)
    print(ctx)
except:
    pass
PYEOF
)
    fi

    EXPLAIN_PROMPT="## EXPLAIN MODE — read-only, no file changes

Your job is to explain what has been built in this directory: $WORK_DIR

Instructions:
1. Use Read, Glob, and Grep to explore the directory.
2. Write a clear, structured explanation covering:
   - What was built and what it does
   - How it is structured (key files and their roles)
   - How to use it (main entry points, commands, flags, or APIs)
   - Anything notable about the implementation
3. Keep it concise but complete. Write for a developer who is new to this project.
4. Do NOT create, edit, or delete any files.
$SESSION_CONTEXT"

    PROMPT_FILE=$(mktemp /tmp/orchclaude_explain_$$.txt)
    printf '%s' "$EXPLAIN_PROMPT" > "$PROMPT_FILE"

    printf "${CYAN}Calling Claude (read-only)...${NC}\n"

    OUTPUT=$(claude -p "$(cat "$PROMPT_FILE")" --allowedTools "Read,Glob,Grep" --max-turns 20 2>&1)
    rm -f "$PROMPT_FILE"

    printf "\n${GREEN}%s${NC}\n" "======================================================="
    printf "${GREEN}  EXPLANATION${NC}\n"
    printf "${GREEN}%s${NC}\n\n" "======================================================="
    printf '%s\n' "$OUTPUT"
    printf "\n"
    exit 0
fi

# ------------------------------------------------------------------ #
# Diff command
# ------------------------------------------------------------------ #
if [[ "$COMMAND" == "diff" ]]; then
    WORK_DIR="${D:-$(pwd)}"
    SESSION_FILE="$WORK_DIR/orchclaude-session.json"

    printf "\n${CYAN}%s${NC}\n" "======================================================="
    printf "${CYAN}  orchclaude diff${NC}\n"
    printf "${CYAN}%s${NC}\n" "======================================================="

    if [[ ! -f "$SESSION_FILE" ]]; then
        printf "${YELLOW}  No session file found in %s${NC}\n" "$WORK_DIR"
        printf "${DGRAY}  Run orchclaude first, then use orchclaude diff.${NC}\n\n"
        exit 0
    fi

    DIFF_START_COMMIT=$(python3 -c "import json; print(json.load(open('$SESSION_FILE')).get('startCommit',''))" 2>/dev/null || echo "")
    DIFF_ORIG_DIR=$(python3 -c "import json; print(json.load(open('$SESSION_FILE')).get('originalWorkDir','$WORK_DIR'))" 2>/dev/null || echo "$WORK_DIR")
    DIFF_BRANCH=$(python3 -c "import json; print(json.load(open('$SESSION_FILE')).get('worktreeBranch',''))" 2>/dev/null || echo "")
    DIFF_STATUS=$(python3 -c "import json; d=json.load(open('$SESSION_FILE')); print(d.get('status','?'), d.get('currentIteration',0))" 2>/dev/null || echo "? 0")

    printf "${DGRAY}  Session   : %s${NC}\n" "$DIFF_STATUS"
    [[ -n "$DIFF_BRANCH" ]] && printf "${DGRAY}  Branch    : %s${NC}\n" "$DIFF_BRANCH"
    printf "${CYAN}%s${NC}\n\n" "======================================================="

    if [[ -z "$DIFF_START_COMMIT" ]]; then
        printf "${YELLOW}No git diff available — this session was run without git tracking,${NC}\n"
        printf "${YELLOW}or it was created with an older version of orchclaude.${NC}\n\n"
        PROGRESS_LINES=$(python3 -c "
import json
d = json.load(open('$SESSION_FILE'))
lines = d.get('progressLines', [])
for l in lines:
    print(l)
" 2>/dev/null || true)
        if [[ -n "$PROGRESS_LINES" ]]; then
            printf "${CYAN}PROGRESS from this run:${NC}\n"
            printf "${CYAN}%s${NC}\n" "-------------------------------------------------------"
            echo "$PROGRESS_LINES" | while IFS= read -r line; do
                printf "  %s\n" "$line"
            done
        fi
        exit 0
    fi

    # Verify git repo
    if ! git -C "$DIFF_ORIG_DIR" rev-parse --git-dir > /dev/null 2>&1; then
        printf "${YELLOW}Not a git repository: %s${NC}\n" "$DIFF_ORIG_DIR"
        exit 0
    fi

    # Determine end ref
    END_REF="HEAD"
    if [[ -n "$DIFF_BRANCH" ]]; then
        if git -C "$DIFF_ORIG_DIR" rev-parse --verify "$DIFF_BRANCH" > /dev/null 2>&1; then
            END_REF="$DIFF_BRANCH"
        fi
    fi

    printf "${DGRAY}From : %s${NC}\n" "$DIFF_START_COMMIT"
    printf "${DGRAY}To   : %s${NC}\n\n" "$END_REF"

    # Summary stat
    DIFF_STAT=$(git -C "$DIFF_ORIG_DIR" diff --stat "${DIFF_START_COMMIT}..${END_REF}" 2>&1)
    if [[ $? -ne 0 || -z "$(echo "$DIFF_STAT" | tr -d '[:space:]')" ]]; then
        DIFF_STAT=$(git -C "$DIFF_ORIG_DIR" diff --stat "${DIFF_START_COMMIT}" 2>&1)
        END_REF="HEAD"
    fi

    if [[ -z "$(echo "$DIFF_STAT" | tr -d '[:space:]')" ]]; then
        printf "${YELLOW}No changes detected between %s and %s.${NC}\n" "$DIFF_START_COMMIT" "$END_REF"
        exit 0
    fi

    printf "${CYAN}FILES CHANGED:${NC}\n"
    printf "${CYAN}%s${NC}\n" "-------------------------------------------------------"
    echo "$DIFF_STAT" | while IFS= read -r line; do printf "  %s\n" "$line"; done
    printf "\n"

    if [[ "$V" == "true" ]]; then
        printf "${CYAN}FULL DIFF:${NC}\n"
        printf "${CYAN}%s${NC}\n" "-------------------------------------------------------"
        git -C "$DIFF_ORIG_DIR" diff "${DIFF_START_COMMIT}..${END_REF}" 2>&1 | while IFS= read -r line; do
            if [[ "$line" =~ ^\+[^\+] ]]; then
                printf "${GREEN}%s${NC}\n" "$line"
            elif [[ "$line" =~ ^-[^-] ]]; then
                printf "${RED}%s${NC}\n" "$line"
            elif [[ "$line" =~ ^@@ ]]; then
                printf "${CYAN}%s${NC}\n" "$line"
            else
                printf "%s\n" "$line"
            fi
        done
    else
        printf "${DGRAY}(Run 'orchclaude diff -v' to see the full line-by-line diff)${NC}\n"
    fi
    printf "\n"
    exit 0
fi

# ------------------------------------------------------------------ #
# Template command
# ------------------------------------------------------------------ #
if [[ "$COMMAND" == "template" ]]; then
    # Resolve orchclaude.sh's own directory (works whether invoked directly,
    # via a symlink, or through npm's bin shim).
    _src="${BASH_SOURCE[0]}"
    while [[ -h "$_src" ]]; do
        _dir=$(cd -P "$(dirname "$_src")" && pwd)
        _src=$(readlink "$_src")
        [[ "$_src" != /* ]] && _src="$_dir/$_src"
    done
    SCRIPT_DIR=$(cd -P "$(dirname "$_src")" && pwd)
    BUILTIN_TPL_DIR="$SCRIPT_DIR/templates"
    USER_TPL_DIR="$HOME/.orchclaude/templates"

    SUB_CMD=$(printf '%s' "${PROMPT_ARG:-}" | tr '[:upper:]' '[:lower:]')
    TPL_NAME="${SUBARG:-}"

    # Resolve a template name to its full path; prefers user override.
    resolve_template_path() {
        local name="$1"
        [[ -z "$name" ]] && return 1
        if [[ -f "$USER_TPL_DIR/$name.md"    ]]; then printf '%s\n' "$USER_TPL_DIR/$name.md";    return 0; fi
        if [[ -f "$BUILTIN_TPL_DIR/$name.md" ]]; then printf '%s\n' "$BUILTIN_TPL_DIR/$name.md"; return 0; fi
        return 1
    }

    resolve_template_source() {
        local name="$1"
        if   [[ -f "$USER_TPL_DIR/$name.md"    ]]; then printf 'custom\n'
        elif [[ -f "$BUILTIN_TPL_DIR/$name.md" ]]; then printf 'built-in\n'
        else                                            printf 'unknown\n'
        fi
    }

    list_templates() {
        # Print every template name once; user-dir entries silently shadow built-ins.
        {
            [[ -d "$BUILTIN_TPL_DIR" ]] && find "$BUILTIN_TPL_DIR" -maxdepth 1 -name '*.md' -type f 2>/dev/null
            [[ -d "$USER_TPL_DIR"    ]] && find "$USER_TPL_DIR"    -maxdepth 1 -name '*.md' -type f 2>/dev/null
        } | awk -F/ '{ n=$NF; sub(/\.md$/, "", n); print n }' | sort -u
    }

    case "$SUB_CMD" in
        list)
            printf "\n${CYAN}%s${NC}\n" "======================================================="
            printf "${CYAN}  orchclaude templates${NC}\n"
            printf "${CYAN}%s${NC}\n" "======================================================="
            names=$(list_templates)
            if [[ -z "$names" ]]; then
                printf "${YELLOW}  No templates found.${NC}\n"
                printf "${DGRAY}  Built-in templates should be in: %s${NC}\n" "$BUILTIN_TPL_DIR"
            else
                printf "\n"
                while IFS= read -r n; do
                    [[ -z "$n" ]] && continue
                    path=$(resolve_template_path "$n")
                    src=$(resolve_template_source "$n")
                    tag=""
                    [[ "$src" == "custom" ]] && tag=" [custom]"
                    # Pull the first non-empty line and strip "# orchclaude template:" prefix
                    first=$(grep -m1 -v '^\s*$' "$path" 2>/dev/null | sed -E 's/^#+[[:space:]]*orchclaude template:[[:space:]]*//')
                    printf "  ${WHITE}%-20s${NC} %s%s\n" "$n" "$first" "$tag"
                done <<< "$names"
            fi
            printf "\n"
            printf "${DGRAY}  Usage:${NC}\n"
            printf "${DGRAY}    orchclaude template show <name>           -- view the prompt${NC}\n"
            printf "${DGRAY}    orchclaude template run  <name> [flags]   -- run with this template${NC}\n"
            printf "\n"
            printf "${DGRAY}  Add custom templates: place .md files in %s${NC}\n\n" "$USER_TPL_DIR"
            exit 0
            ;;
        show)
            if [[ -z "$TPL_NAME" ]]; then
                printf "${RED}Usage: orchclaude template show <name>${NC}\n" >&2
                exit 1
            fi
            tpl_path=$(resolve_template_path "$TPL_NAME") || {
                printf "${RED}Template '%s' not found. Run 'orchclaude template list' to see available templates.${NC}\n" "$TPL_NAME" >&2
                exit 1
            }
            src=$(resolve_template_source "$TPL_NAME")
            printf "\n${CYAN}%s${NC}\n" "======================================================="
            printf "${CYAN}  Template: %s  (%s)${NC}\n" "$TPL_NAME" "$src"
            printf "${CYAN}%s${NC}\n\n" "======================================================="
            cat "$tpl_path"
            printf "\n${DGRAY}%s${NC}\n" "======================================================="
            printf "${DGRAY}  Run it: orchclaude template run %s -t 1h -d <project-dir>${NC}\n\n" "$TPL_NAME"
            exit 0
            ;;
        run)
            if [[ -z "$TPL_NAME" ]]; then
                printf "${RED}Usage: orchclaude template run <name> [flags]${NC}\n" >&2
                exit 1
            fi
            tpl_path=$(resolve_template_path "$TPL_NAME") || {
                printf "${RED}Template '%s' not found. Run 'orchclaude template list' to see available templates.${NC}\n" "$TPL_NAME" >&2
                exit 1
            }
            src=$(resolve_template_source "$TPL_NAME")
            PROMPT_ARG=$(cat "$tpl_path")
            SUBARG=""
            COMMAND="run"
            printf "\n"
            printf "${CYAN}Template  : %s (%s)${NC}\n" "$TPL_NAME" "$src"
            printf "${DGRAY}Prompt    : loaded from %s${NC}\n\n" "$tpl_path"
            # fall through to run logic below
            ;;
        *)
            printf "${RED}Unknown template subcommand '%s'. Use: list, show, run${NC}\n" "$SUB_CMD" >&2
            exit 1
            ;;
    esac
fi

# ------------------------------------------------------------------ #
# History command
# ------------------------------------------------------------------ #
if [[ "$COMMAND" == "history" ]]; then
    HIST_DIR="$HOME/.orchclaude"
    HIST_FILE="$HIST_DIR/history.json"
    SUBCMD="${PROMPT_ARG:-}"

    if [[ "${SUBCMD,,}" == "clear" ]]; then
        if [[ ! -f "$HIST_FILE" ]]; then
            printf "${YELLOW}No history to clear.${NC}\n"
            exit 0
        fi
        read -r -p "Clear all orchclaude history? This cannot be undone. (y/n): " confirm
        if [[ "${confirm,,}" == "y" ]]; then
            rm -f "$HIST_FILE"
            printf "${GREEN}History cleared.${NC}\n"
        else
            printf "${DGRAY}Cancelled.${NC}\n"
        fi
        exit 0
    fi

    if [[ ! -f "$HIST_FILE" ]]; then
        printf "${YELLOW}No history yet. History is recorded after each run.${NC}\n"
        exit 0
    fi

    python3 - <<PYEOF
import json, os, sys
from datetime import datetime, timezone

hist_file = "$HIST_FILE"
show_n    = $HISTORY_N

try:
    raw = json.load(open(hist_file))
    history = raw if isinstance(raw, list) else ([raw] if raw else [])
except:
    print("\033[0;31mHistory file is corrupt or unreadable.\033[0m")
    sys.exit(1)

if not history:
    print("\033[1;33mNo history yet. History is recorded after each run.\033[0m")
    sys.exit(0)

entries = history[:show_n]
total   = len(history)

NC      = "\033[0m"
CYAN    = "\033[0;36m"
DGRAY   = "\033[0;90m"
GRAY    = "\033[0;37m"
GREEN   = "\033[0;32m"
YELLOW  = "\033[1;33m"
RED     = "\033[0;31m"
MAGENTA = "\033[0;35m"

status_colors = {
    "complete":           GREEN,
    "timeout":            YELLOW,
    "failed":             RED,
    "usage_limit_paused": MAGENTA,
}

print()
print(f"{CYAN}{'=' * 90}{NC}")
print(f"{CYAN}  orchclaude run history  (showing {len(entries)} of {total} runs){NC}")
print(f"{CYAN}{'=' * 90}{NC}")
print()

for idx, e in enumerate(entries, 1):
    status = e.get("status", "unknown")
    sc     = status_colors.get(status, "\033[1;37m")
    try:
        dt     = datetime.fromisoformat(e["date"].replace("Z", "+00:00"))
        ds     = dt.strftime("%Y-%m-%d %H:%M")
    except:
        ds = e.get("date", "?")

    work_dir = e.get("workDir", "?")
    home     = os.path.expanduser("~")
    if work_dir.startswith(home):
        work_dir = "~" + work_dir[len(home):]
    if len(work_dir) > 40:
        work_dir = "..." + work_dir[-37:]

    dur   = e.get("durationMinutes", 0)
    cost  = e.get("estimatedCostUSD", 0)
    iters = e.get("iterations", 0)
    exc   = e.get("promptExcerpt", "").replace("\n", " ").replace("\r", "")
    if len(exc) > 50:
        exc = exc[:50] + "..."

    label = f"{status.upper():<8}"
    print(f"  {DGRAY}#{idx:<4} {ds}  {NC}{sc}{label}{NC}{GRAY}  {work_dir:<40}  {dur:>5.1f}m  \${cost:.2f}  {iters:>3} iters{NC}")
    print(f'        {DGRAY}"{exc}"{NC}')

print()
if total > show_n:
    print(f"  {DGRAY}Use 'orchclaude history -n {total}' to see all entries.{NC}")
print(f"  {DGRAY}Use 'orchclaude history clear' to wipe history.{NC}")
print()
PYEOF
    exit 0
fi

# ------------------------------------------------------------------ #
# Resume command
# ------------------------------------------------------------------ #
RESUME_MODE=false
START_ITER=1
SAVED_PROGRESS_LINES=()

if [[ "$COMMAND" == "resume" ]]; then
    WORK_DIR="${D:-$(pwd)}"
    SESSION_FILE="$WORK_DIR/orchclaude-session.json"
    if [[ ! -f "$SESSION_FILE" ]]; then
        printf "${YELLOW}No interrupted session found in %s${NC}\n" "$WORK_DIR"
        exit 0
    fi
    session_status=$(python3 -c "import json; print(json.load(open('$SESSION_FILE')).get('status',''))" 2>/dev/null)
    if [[ "$session_status" == "complete" ]]; then
        printf "${GREEN}Last session already completed.${NC}\n"
        exit 0
    fi
    if [[ "$session_status" == "usage_limit_paused" ]]; then
        resume_after=$(python3 -c "import json; print(json.load(open('$SESSION_FILE')).get('resumeAfter',''))" 2>/dev/null || echo "")
        if [[ -n "$resume_after" ]]; then
            now_epoch=$(date +%s)
            resume_epoch=$(python3 -c "from datetime import datetime, timezone; dt=datetime.fromisoformat('$resume_after'.replace('Z','+00:00')); print(int(dt.timestamp()))" 2>/dev/null || echo 0)
            if [[ "$now_epoch" -lt "$resume_epoch" ]]; then
                remaining_secs=$((resume_epoch - now_epoch))
                rem_h=$((remaining_secs / 3600))
                rem_m=$(((remaining_secs % 3600) / 60))
                printf "${YELLOW}Not ready yet. Resume scheduled for $(python3 -c "from datetime import datetime,timezone; print(datetime.fromisoformat('$resume_after'.replace('Z','+00:00')).strftime('%H:%M:%S'))" 2>/dev/null). ${rem_h}h ${rem_m}m remaining.${NC}\n"
                printf "${DGRAY}Run 'orchclaude resume' again after the limit resets.${NC}\n"
                exit 0
            fi
            printf "${CYAN}Usage limit has reset. Resuming now...${NC}\n"
        fi
    fi
    printf "${CYAN}Interrupted session found (status: %s). Resuming...${NC}\n" "$session_status"
    eval "$(python3 - <<PYEOF
import json, shlex
d = json.load(open("$SESSION_FILE"))
f = d.get("flags", {})
print(f"BASE_PROMPT={shlex.quote(d.get('prompt',''))}")
print(f"T={shlex.quote(str(f.get('t','30m')))}")
print(f"I={int(f.get('i',40))}")
print(f"NOQA={'true' if f.get('noqa') else 'false'}")
print(f"TOKEN={shlex.quote(str(f.get('token','ORCHESTRATION_COMPLETE')))}")
print(f"V={'true' if f.get('v') else 'false'}")
print(f"COOLDOWN={int(f.get('cooldown',5))}")
print(f"BREAKER={int(f.get('breaker',10))}")
print(f"START_ITER={int(d.get('currentIteration',0)) + 1}")
PYEOF
)"
    # Restore progress lines
    python3 -c "
import json
d = json.load(open('$SESSION_FILE'))
lines = d.get('progressLines', [])
for l in lines:
    print(l)
" > "$WORK_DIR/orchclaude-progress-restore.tmp" 2>/dev/null || true
    RESUME_MODE=true
fi

# ------------------------------------------------------------------ #
# Load .orchclauderc from project root (profile overrides RC; CLI overrides both)
# ------------------------------------------------------------------ #
RC_LOADED=false
RC_DIR="${D:-$(pwd)}"
RC_FILE="$RC_DIR/.orchclauderc"
if [[ -f "$RC_FILE" && "$RESUME_MODE" != "true" ]]; then
    eval "$(python3 - <<PYEOF
import json, shlex, sys
try:
    rc = json.load(open("$RC_FILE"))
except Exception as e:
    print(f'printf "WARNING: .orchclauderc parse error: {e}\\n" >&2')
    sys.exit(0)
def q(v): return shlex.quote(str(v))
def b(v): return 'true' if v else 'false'
pairs = [
    ('T',            rc.get('t'),            q),
    ('I',            rc.get('i'),            lambda v: str(int(v))),
    ('V',            rc.get('v'),            b),
    ('NOQA',         rc.get('noqa'),         b),
    ('TOKEN',        rc.get('token'),        q),
    ('COOLDOWN',     rc.get('cooldown'),     lambda v: str(int(v))),
    ('BREAKER',      rc.get('breaker'),      lambda v: str(int(v))),
    ('NOPLAN',       rc.get('noplan'),       b),
    ('NOBRANCH',     rc.get('nobranch'),     b),
    ('AGENTS',       rc.get('agents'),       lambda v: str(int(v))),
    ('WEBHOOK_URL',  rc.get('webhook'),      q),
    ('MODEL_OVERRIDE', rc.get('model'),      q),
    ('BUDGET',       rc.get('budget'),       lambda v: str(float(v))),
    ('MODEL_PROFILE', rc.get('modelprofile'), q),
    ('AUTOWAIT',     rc.get('autowait'),     b),
    ('AUTOSCHEDULE', rc.get('autoschedule'), b),
    ('WAITTIME',     rc.get('waittime'),     lambda v: str(int(v))),
]
for var, val, fmt in pairs:
    if val is not None:
        print(f'_RC_{var}={fmt(val)}')
print('RC_LOADED=true')
PYEOF
)"
    [[ "$_CLI_T"            != "true" && -n "${_RC_T:-}"              ]] && T="$_RC_T"
    [[ "$_CLI_I"            != "true" && -n "${_RC_I:-}"              ]] && I="$_RC_I"
    [[ "$_CLI_V"            != "true" && -n "${_RC_V:-}"              ]] && V="$_RC_V"
    [[ "$_CLI_NOQA"         != "true" && -n "${_RC_NOQA:-}"           ]] && NOQA="$_RC_NOQA"
    [[ "$_CLI_TOKEN"        != "true" && -n "${_RC_TOKEN:-}"          ]] && TOKEN="$_RC_TOKEN"
    [[ "$_CLI_COOLDOWN"     != "true" && -n "${_RC_COOLDOWN:-}"       ]] && COOLDOWN="$_RC_COOLDOWN"
    [[ "$_CLI_BREAKER"      != "true" && -n "${_RC_BREAKER:-}"        ]] && BREAKER="$_RC_BREAKER"
    [[ "$_CLI_NOPLAN"       != "true" && -n "${_RC_NOPLAN:-}"         ]] && NOPLAN="$_RC_NOPLAN"
    [[ "$_CLI_NOBRANCH"     != "true" && -n "${_RC_NOBRANCH:-}"       ]] && NOBRANCH="$_RC_NOBRANCH"
    [[ "$_CLI_AGENTS"       != "true" && -n "${_RC_AGENTS:-}"         ]] && AGENTS="$_RC_AGENTS"
    [[ "$_CLI_WEBHOOK"      != "true" && -n "${_RC_WEBHOOK_URL:-}"    ]] && WEBHOOK_URL="$_RC_WEBHOOK_URL"
    [[ "$_CLI_MODEL"        != "true" && -n "${_RC_MODEL_OVERRIDE:-}" ]] && MODEL_OVERRIDE="$_RC_MODEL_OVERRIDE"
    [[ "$_CLI_BUDGET"       != "true" && -n "${_RC_BUDGET:-}"         ]] && BUDGET="$_RC_BUDGET"
    [[ "$_CLI_MODELPROFILE" != "true" && -n "${_RC_MODEL_PROFILE:-}"  ]] && MODEL_PROFILE="$_RC_MODEL_PROFILE"
    [[ "$_CLI_AUTOWAIT"     != "true" && -n "${_RC_AUTOWAIT:-}"       ]] && AUTOWAIT="$_RC_AUTOWAIT"
    [[ "$_CLI_AUTOSCHEDULE" != "true" && -n "${_RC_AUTOSCHEDULE:-}"   ]] && AUTOSCHEDULE="$_RC_AUTOSCHEDULE"
    [[ "$_CLI_WAITTIME"     != "true" && -n "${_RC_WAITTIME:-}"       ]] && WAITTIME="$_RC_WAITTIME"
fi

# ------------------------------------------------------------------ #
# Load named profile (profile overrides .orchclauderc; CLI overrides both)
# ------------------------------------------------------------------ #
if [[ -n "$PROFILE_NAME" && "$RESUME_MODE" != "true" ]]; then
    if ! profile_exists "$PROFILE_NAME"; then
        printf "${RED}Profile '%s' not found. Use 'orchclaude profile list'.${NC}\n" "$PROFILE_NAME" >&2
        exit 1
    fi
    eval "$(python3 - <<PYEOF
import json, shlex, os
d = json.load(open("$PROFILES_FILE"))
p = d.get("$PROFILE_NAME", {})
# Only emit values that weren't explicitly set on CLI (caller sets _EXPLICIT_ vars)
def q(v): return shlex.quote(str(v))
print(f"_P_T={q(p.get('t','30m'))}")
print(f"_P_I={int(p.get('i',40))}")
print(f"_P_D={q(p.get('d',''))}")
print(f"_P_V={'true' if p.get('v') else 'false'}")
print(f"_P_NOQA={'true' if p.get('noqa') else 'false'}")
print(f"_P_TOKEN={q(p.get('token','ORCHESTRATION_COMPLETE'))}")
print(f"_P_COOLDOWN={int(p.get('cooldown',5))}")
print(f"_P_BREAKER={int(p.get('breaker',10))}")
print(f"_P_NOPLAN={'true' if p.get('noplan') else 'false'}")
print(f"_P_NOBRANCH={'true' if p.get('nobranch') else 'false'}")
print(f"_P_AGENTS={int(p.get('agents',1))}")
print(f"_P_WEBHOOK={q(p.get('webhook',''))}")
PYEOF
)"
    # Apply profile values (profile overrides .orchclauderc; CLI overrides both)
    [[ "$_CLI_T"            != "true" ]] && T="$_P_T"
    [[ "$_CLI_I"            != "true" ]] && I=$_P_I
    [[ "$_CLI_D"            != "true" ]] && D="$_P_D"
    [[ "$_CLI_V"            != "true" ]] && V="$_P_V"
    [[ "$_CLI_NOQA"         != "true" ]] && NOQA="$_P_NOQA"
    [[ "$_CLI_TOKEN"        != "true" ]] && TOKEN="$_P_TOKEN"
    [[ "$_CLI_COOLDOWN"     != "true" ]] && COOLDOWN=$_P_COOLDOWN
    [[ "$_CLI_BREAKER"      != "true" ]] && BREAKER=$_P_BREAKER
    [[ "$_CLI_NOPLAN"       != "true" ]] && NOPLAN="$_P_NOPLAN"
    [[ "$_CLI_NOBRANCH"     != "true" ]] && NOBRANCH="$_P_NOBRANCH"
    [[ "$_CLI_AGENTS"       != "true" ]] && AGENTS=$_P_AGENTS
    [[ "$_CLI_WEBHOOK"      != "true" ]] && WEBHOOK_URL="$_P_WEBHOOK"
fi

# ---- 7.4: Model Profile Presets (evaluated after RC + profile so all sources are resolved) ----
NO_ESCALATION=false
if [[ -n "$MODEL_PROFILE" ]]; then
    case "${MODEL_PROFILE,,}" in
        fast)     [[ -z "$MODEL_OVERRIDE" ]] && MODEL_OVERRIDE="light" ;;
        quality)  [[ -z "$MODEL_OVERRIDE" ]] && MODEL_OVERRIDE="heavy" ;;
        balanced) NO_ESCALATION=true ;;
        auto)     ;;
        *)
            printf "${RED}Unknown -modelprofile '%s'. Valid values: fast, balanced, quality, auto${NC}\n" "$MODEL_PROFILE" >&2
            exit 1
            ;;
    esac
fi

# ------------------------------------------------------------------ #
# Validate agents flag
# ------------------------------------------------------------------ #
if [[ ! "$AGENTS" =~ ^[0-9]+$ ]] || [[ "$AGENTS" -lt 1 ]]; then
    printf "${RED}Bad -agents value '%s'. Must be a positive integer.${NC}\n" "$AGENTS" >&2
    exit 1
fi
if [[ "$AGENTS" -gt 20 ]]; then
    printf "${RED}Bad -agents value '%s'. Maximum supported is 20 parallel agents.${NC}\n" "$AGENTS" >&2
    exit 1
fi
if [[ "$AGENTS" -gt 1 && "$NOPLAN" == "true" ]]; then
    printf "${RED}-agents requires the planning phase. Remove -noplan or set -agents 1.${NC}\n" >&2
    exit 1
fi
if [[ "$AGENTS" -gt 1 && "$RESUME_MODE" == "true" ]]; then
    printf "${YELLOW}WARNING: -agents is not supported in resume mode. Running single-agent.${NC}\n"
    AGENTS=1
fi

# ------------------------------------------------------------------ #
# Template command
# ------------------------------------------------------------------ #
if [[ "$COMMAND" == "template" ]]; then
    BUILTIN_TPL_DIR="$(dirname "$0")/templates"
    USER_TPL_DIR="$HOME/.orchclaude/templates"
    TPL_SUBCMD="${PROMPT_ARG,,}"  # lower-case

    get_template_map() {
        # Print "name|path|source" lines for every .md template found
        for dir_entry in "$BUILTIN_TPL_DIR" "$USER_TPL_DIR"; do
            local src="built-in"
            [[ "$dir_entry" == "$USER_TPL_DIR" ]] && src="custom"
            if [[ -d "$dir_entry" ]]; then
                while IFS= read -r -d '' f; do
                    local name
                    name=$(basename "$f" .md)
                    printf '%s|%s|%s\n' "$name" "$f" "$src"
                done < <(find "$dir_entry" -maxdepth 1 -name "*.md" -print0 | sort -z)
            fi
        done
    }

    if [[ "$TPL_SUBCMD" == "list" ]]; then
        printf "\n${CYAN}%s${NC}\n" "======================================================="
        printf "${CYAN}  orchclaude templates${NC}\n"
        printf "${CYAN}%s${NC}\n\n" "======================================================="
        found=0
        while IFS='|' read -r tname tpath tsrc; do
            found=1
            tag=""
            [[ "$tsrc" == "custom" ]] && tag=" [custom]"
            # grab first non-blank line, strip the "# orchclaude template: " prefix
            desc=$(grep -m1 '\S' "$tpath" 2>/dev/null | sed 's/^#*[[:space:]]*orchclaude template:[[:space:]]*//')
            printf "  ${WHITE}%-20s${NC} %s%s\n" "$tname" "$desc" "$tag"
        done < <(get_template_map)
        if [[ "$found" -eq 0 ]]; then
            printf "  ${YELLOW}No templates found.${NC}\n"
            printf "  ${DGRAY}Built-in templates should be in: %s${NC}\n" "$BUILTIN_TPL_DIR"
        fi
        printf "\n  ${DGRAY}Usage:${NC}\n"
        printf "  ${DGRAY}  orchclaude template show <name>           -- view the prompt${NC}\n"
        printf "  ${DGRAY}  orchclaude template run  <name> [flags]   -- run with this template${NC}\n"
        printf "\n  ${DGRAY}Add custom templates: place .md files in %s${NC}\n\n" "$USER_TPL_DIR"
        exit 0

    elif [[ "$TPL_SUBCMD" == "show" ]]; then
        if [[ -z "$SUBARG" ]]; then
            printf "${RED}Usage: orchclaude template show <name>${NC}\n" >&2; exit 1
        fi
        TPL_PATH=""
        TPL_SRC=""
        while IFS='|' read -r tname tpath tsrc; do
            if [[ "$tname" == "$SUBARG" ]]; then TPL_PATH="$tpath"; TPL_SRC="$tsrc"; fi
        done < <(get_template_map)
        if [[ -z "$TPL_PATH" ]]; then
            printf "${RED}Template '%s' not found. Run 'orchclaude template list' to see available templates.${NC}\n" "$SUBARG" >&2
            exit 1
        fi
        printf "\n${CYAN}%s${NC}\n" "======================================================="
        printf "${CYAN}  Template: %s  (%s)${NC}\n" "$SUBARG" "$TPL_SRC"
        printf "${CYAN}%s${NC}\n\n" "======================================================="
        cat "$TPL_PATH"
        printf "\n${DGRAY}%s${NC}\n" "======================================================="
        printf "${DGRAY}  Run it: orchclaude template run %s -t 1h -d <project-dir>${NC}\n\n" "$SUBARG"
        exit 0

    elif [[ "$TPL_SUBCMD" == "run" ]]; then
        if [[ -z "$SUBARG" ]]; then
            printf "${RED}Usage: orchclaude template run <name> [flags]${NC}\n" >&2; exit 1
        fi
        TPL_PATH=""
        TPL_SRC=""
        while IFS='|' read -r tname tpath tsrc; do
            if [[ "$tname" == "$SUBARG" ]]; then TPL_PATH="$tpath"; TPL_SRC="$tsrc"; fi
        done < <(get_template_map)
        if [[ -z "$TPL_PATH" ]]; then
            printf "${RED}Template '%s' not found. Run 'orchclaude template list' to see available templates.${NC}\n" "$SUBARG" >&2
            exit 1
        fi
        PROMPT_ARG=$(cat "$TPL_PATH")
        COMMAND="run"
        printf "\n${CYAN}Template  : %s (%s)${NC}\n" "$SUBARG" "$TPL_SRC"
        printf "${DGRAY}Prompt    : loaded from %s${NC}\n\n" "$TPL_PATH"
        # fall through to run logic

    else
        printf "${RED}Unknown template subcommand '%s'. Use: list, show, run${NC}\n" "$TPL_SUBCMD" >&2
        exit 1
    fi
fi

# ------------------------------------------------------------------ #
# Validate command
# ------------------------------------------------------------------ #
if [[ "$RESUME_MODE" != "true" && "$COMMAND" != "run" ]]; then
    printf "${RED}Unknown command '%s'. Use: orchclaude run, resume, status, explain, diff, template, history, help, profile${NC}\n" "$COMMAND" >&2
    exit 1
fi

# ------------------------------------------------------------------ #
# Parse timeout
# ------------------------------------------------------------------ #
TIMEOUT_SECONDS=1800
if [[ "$T" =~ ^([0-9]+)(m|h)$ ]]; then
    num="${BASH_REMATCH[1]}"
    unit="${BASH_REMATCH[2]}"
    if [[ "$num" -eq 0 ]]; then
        printf "${RED}Bad -t value '%s'. Timeout must be greater than zero.${NC}\n" "$T" >&2; exit 1
    fi
    if [[ "$unit" == "m" ]]; then TIMEOUT_SECONDS=$((num * 60))
    else                          TIMEOUT_SECONDS=$((num * 3600)); fi
else
    printf "${RED}Bad -t value '%s'. Use format like: 5m or 2h${NC}\n" "$T" >&2; exit 1
fi

# ------------------------------------------------------------------ #
# Load prompt (fresh run only)
# ------------------------------------------------------------------ #
if [[ "$RESUME_MODE" != "true" ]]; then
    BASE_PROMPT=""
    if [[ -n "$F" ]]; then
        if [[ ! -f "$F" ]]; then printf "${RED}File not found: %s${NC}\n" "$F" >&2; exit 1; fi
        BASE_PROMPT=$(cat "$F")
        [[ -z "$BASE_PROMPT" ]] && { printf "${RED}File '%s' is empty.${NC}\n" "$F" >&2; exit 1; }
    elif [[ -n "$PROMPT_ARG" ]]; then
        BASE_PROMPT="$PROMPT_ARG"
    else
        printf "${RED}Provide a prompt: orchclaude run \"your prompt\" or use -f file.md${NC}\n" >&2
        exit 1
    fi
fi

# ------------------------------------------------------------------ #
# Validate max iterations
# ------------------------------------------------------------------ #
if [[ ! "$I" =~ ^[0-9]+$ ]] || [[ "$I" -le 0 ]]; then
    printf "${RED}Bad -i value '%s'. Must be a positive integer.${NC}\n" "$I" >&2; exit 1
fi

# ------------------------------------------------------------------ #
# Working directory
# ------------------------------------------------------------------ #
if [[ "$RESUME_MODE" != "true" ]]; then
    WORK_DIR="${D:-$(pwd)}"
fi
if [[ ! -d "$WORK_DIR" ]]; then
    printf "${RED}Directory not found: %s${NC}\n" "$WORK_DIR" >&2; exit 1
fi

# ------------------------------------------------------------------ #
# Git worktree isolation
# ------------------------------------------------------------------ #
IS_GIT_REPO=false
USE_WORKTREE=false
WORKTREE_PATH=""
WORKTREE_BRANCH=""
ORIGINAL_BRANCH=""
ORIGINAL_WORK_DIR="$WORK_DIR"
START_COMMIT=""

if [[ "$NOBRANCH" != "true" && "$RESUME_MODE" != "true" && "$DRYRUN" != "true" ]]; then
    if git -C "$WORK_DIR" rev-parse --git-dir > /dev/null 2>&1; then
        IS_GIT_REPO=true
        START_COMMIT=$(git -C "$WORK_DIR" rev-parse HEAD 2>/dev/null || echo "")
        GIT_ROOT=$(git -C "$WORK_DIR" rev-parse --show-toplevel 2>/dev/null)
        ORIGINAL_BRANCH=$(git -C "$WORK_DIR" branch --show-current 2>/dev/null || echo "HEAD")
        [[ -z "$ORIGINAL_BRANCH" ]] && ORIGINAL_BRANCH="HEAD"

        TS=$(date '+%Y%m%d-%H%M%S')
        WORKTREE_BRANCH="orchclaude/$TS"
        WT_ROOT="/tmp/orchclaude-wt-$TS"

        if git -C "$WORK_DIR" worktree add "$WT_ROOT" -b "$WORKTREE_BRANCH" > /dev/null 2>&1; then
            USE_WORKTREE=true
            WORKTREE_PATH="$WT_ROOT"
            # Preserve subdir if workDir was not the repo root
            if [[ "$WORK_DIR" != "$GIT_ROOT" ]]; then
                REL="${WORK_DIR#$GIT_ROOT}"
                REL="${REL#/}"
                WORK_DIR="$WT_ROOT/$REL"
            else
                WORK_DIR="$WT_ROOT"
            fi
        else
            printf "${YELLOW}Could not create git worktree — writing directly to %s${NC}\n" "$WORK_DIR"
        fi
    else
        printf "${DGRAY}Not a git repository — writing directly to %s (use -nobranch to suppress)${NC}\n" "$WORK_DIR"
    fi
fi

# ------------------------------------------------------------------ #
# Setup files
# ------------------------------------------------------------------ #
LOG_FILE="$WORK_DIR/orchclaude-log.txt"
PROGRESS_FILE="$WORK_DIR/orchclaude-progress.txt"
SESSION_FILE="$WORK_DIR/orchclaude-session.json"
PLAN_FILE="$WORK_DIR/orchclaude-plan.txt"

if [[ "$RESUME_MODE" == "true" ]]; then
    if [[ -f "$WORK_DIR/orchclaude-progress-restore.tmp" ]]; then
        mv "$WORK_DIR/orchclaude-progress-restore.tmp" "$PROGRESS_FILE"
    else
        printf '' > "$PROGRESS_FILE"
    fi
elif [[ "$DRYRUN" != "true" ]]; then
    printf '' > "$PROGRESS_FILE" 2>/dev/null \
        || { printf "${RED}Cannot write to '%s'${NC}\n" "$WORK_DIR" >&2; exit 1; }
fi

SCRIPT_START=$SECONDS   # bash built-in: seconds since shell started
START_TIME=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
TIMEOUT_DISPLAY="$T"

TOTAL_INPUT_WORDS=0
TOTAL_OUTPUT_WORDS=0

ORCHESTRATION_INSTRUCTIONS="
---
## ORCHESTRATION CONTRACT (non-negotiable)
1. Do NOT stop early. You will be re-run until you output the completion token.
2. Read existing files before writing — you may have done parts already.
3. Make real file changes using your tools (Edit, Write, Bash).
4. After each major step print: PROGRESS: <what you just completed>
5. When ALL requirements are done, output exactly this on its own line:
   $TOKEN
---"

# ------------------------------------------------------------------ #
# Dry run
# ------------------------------------------------------------------ #
if [[ "$DRYRUN" == "true" ]]; then
    DRY_PROMPT="${BASE_PROMPT}
${ORCHESTRATION_INSTRUCTIONS}"
    printf "\n"
    printf "${CYAN}DRY RUN - prompt that would be sent to Claude:${NC}\n"
    printf "${CYAN}%s${NC}\n" "======================================================="
    printf "%s\n" "$DRY_PROMPT"
    printf "${CYAN}%s${NC}\n" "======================================================="
    printf "\n"
    printf "${DGRAY}No Claude call made. No files created or modified.${NC}\n"
    exit 0
fi

QA_TOKEN="QA_COMPLETE"

# ------------------------------------------------------------------ #
# Banner
# ------------------------------------------------------------------ #
if [[ "$RESUME_MODE" == "true" ]]; then
    write_banner "orchclaude [RESUME]"
else
    write_banner "orchclaude"
fi

write_log "Timeout   : $TIMEOUT_DISPLAY  (${TIMEOUT_SECONDS}s)" "$CYAN"
write_log "Max iters : $I" "$CYAN"
write_log "Work dir  : $WORK_DIR" "$CYAN"
write_log "QA pass   : $( [[ "$NOQA" == "true" ]] && echo 'disabled (-noqa)' || echo 'enabled' )" "$CYAN"
write_log "Cooldown  : $( [[ "$COOLDOWN" -eq 0 ]] && echo 'disabled (-cooldown 0)' || echo "${COOLDOWN}s between iterations" )" "$CYAN"
write_log "Breaker   : $( [[ "$BREAKER" -eq 0 ]] && echo 'disabled (-breaker 0)' || echo "fires after ${BREAKER} stalled iterations" )" "$CYAN"
write_log "Planning  : $( [[ "$NOPLAN" == "true" ]] && echo 'disabled (-noplan)' || echo 'enabled (use -noplan to skip)' )" "$CYAN"
write_log "Ctx guard : enabled (compresses progress log when prompt exceeds ~150k tokens)" "$CYAN"
if [[ "$NOBRANCH" == "true" ]]; then
    write_log "Worktree  : disabled (-nobranch)" "$CYAN"
elif [[ "$USE_WORKTREE" == "true" ]]; then
    write_log "Worktree  : branch $WORKTREE_BRANCH" "$CYAN"
elif [[ "$IS_GIT_REPO" == "true" ]]; then
    write_log "Worktree  : git repo detected but worktree creation failed — writing directly" "$CYAN"
else
    write_log "Worktree  : not a git repo — writing directly" "$CYAN"
fi
write_log "Agents    : $( [[ "$AGENTS" -gt 1 ]] && echo "$AGENTS parallel agents (independent tasks split from plan)" || echo '1 (sequential, default)' )" "$CYAN"
if [[ -n "$MODEL_PROFILE" ]]; then
    case "${MODEL_PROFILE,,}" in
        fast)     _mp_desc="-modelprofile fast (all iterations: haiku)" ;;
        quality)  _mp_desc="-modelprofile quality (all iterations: opus)" ;;
        balanced) _mp_desc="-modelprofile balanced (classifier, no escalation)" ;;
        auto)     _mp_desc="-modelprofile auto (classifier + adaptive escalation: haiku->sonnet->opus on stall)" ;;
        *)        _mp_desc="-modelprofile $MODEL_PROFILE" ;;
    esac
    write_log "Model     : $_mp_desc" "$CYAN"
elif [[ -n "$MODEL_OVERRIDE" ]]; then
    write_log "Model     : fixed override: $MODEL_OVERRIDE" "$CYAN"
else
    write_log "Model     : auto (classifier + adaptive escalation: haiku->sonnet->opus on stall)" "$CYAN"
fi
write_log "Budget    : $( [[ "$BUDGET" != "0" && -n "$BUDGET" ]] && echo "\$$BUDGET limit — pause and confirm if cost exceeds threshold" || echo 'disabled (use -budget <amount> to set a limit)' )" "$CYAN"
write_log "Webhook   : $( [[ -n "$WEBHOOK_URL" ]] && echo "$WEBHOOK_URL (Slack/Discord/generic JSON on run end)" || echo 'disabled (use -webhook <url> to notify on completion)' )" "$CYAN"
if [[ "$AUTOWAIT" == "true" ]]; then
    write_log "UsageLimit: autowait (sleep in-process, $WAITTIME min wait)" "$CYAN"
elif [[ "$AUTOSCHEDULE" == "true" ]]; then
    write_log "UsageLimit: autoschedule (at job, $WAITTIME min wait)" "$CYAN"
else
    write_log "UsageLimit: manual resume (orchclaude resume)" "$CYAN"
fi
[[ "$RC_LOADED" == "true" ]] && write_log "RC file   : $RC_FILE" "$CYAN"
[[ -n "$PROFILE_NAME" ]] && write_log "Profile   : $PROFILE_NAME (loaded from $PROFILES_FILE)" "$CYAN"
write_log "Webhook   : $( [[ -n "$WEBHOOK_URL" ]] && echo "$WEBHOOK_URL (Slack/Discord/generic JSON on run end)" || echo 'disabled (use -webhook <url> to notify on completion)' )" "$CYAN"
write_log "Log       : $LOG_FILE" "$CYAN"
[[ "$RESUME_MODE" == "true" ]] && write_log "Resuming  : starting at iteration $START_ITER" "$CYAN"

# ------------------------------------------------------------------ #
# Initial session write
# ------------------------------------------------------------------ #
write_session "running" "$((START_ITER - 1))"

# ================================================================== #
# PLANNING PHASE
# ================================================================== #
if [[ "$NOPLAN" != "true" && "$RESUME_MODE" != "true" ]]; then
    write_banner "PLANNING PHASE" "$BLUE"
    write_log "Running pre-planning call..." "$BLUE"

    PLANNING_PROMPT="## PLANNING PHASE

Break the following task into a numbered list of subtasks with dependencies.
Output ONLY the plan in the exact format below. No code, no files, no preamble, no explanations.

Format (strict):
PLAN:
1. [task description] | depends: none
2. [task description] | depends: 1
3. [task description] | depends: 1,2

Task:
$BASE_PROMPT"

    TOTAL_INPUT_WORDS=$((TOTAL_INPUT_WORDS + $(get_word_count "$PLANNING_PROMPT")))
    write_log "MODEL: haiku (planning)" "$DCYAN"
    PLAN_OUTPUT=$(invoke_claude "$PLANNING_PROMPT" "plan" "$(resolve_model_id light)")
    TOTAL_OUTPUT_WORDS=$((TOTAL_OUTPUT_WORDS + $(get_word_count "$PLAN_OUTPUT")))

    PLAN_CONTENT="$PLAN_OUTPUT"
    if echo "$PLAN_OUTPUT" | grep -q "^PLAN:"; then
        PLAN_CONTENT=$(echo "$PLAN_OUTPUT" | sed -n '/^PLAN:/,$p')
    fi

    printf '%s\n' "$PLAN_CONTENT" > "$PLAN_FILE"
    echo "--- Planning phase ---" >> "$LOG_FILE"
    echo "$PLAN_CONTENT"         >> "$LOG_FILE"
    echo ""                      >> "$LOG_FILE"

    printf "\n"
    printf "${BLUE}PROJECT PLAN:${NC}\n"
    printf "${BLUE}%s${NC}\n" "-------------------------------------------------------"
    while IFS= read -r pline; do
        printf "  %s\n" "$pline"
    done <<< "$PLAN_CONTENT"
    printf "${BLUE}%s${NC}\n" "-------------------------------------------------------"
    printf "\n"
    write_log "Plan saved to: $PLAN_FILE" "$BLUE"

elif [[ "$RESUME_MODE" == "true" && -f "$PLAN_FILE" ]]; then
    write_log "Planning  : using saved plan from previous session ($PLAN_FILE)" "$BLUE"
elif [[ "$NOPLAN" == "true" ]]; then
    write_log "Planning phase skipped (-noplan)." "$DGRAY"
fi

# ================================================================== #
# PARALLEL AGENTS MODE
# ================================================================== #
if [[ "$AGENTS" -gt 1 && "$RESUME_MODE" != "true" ]]; then
    write_banner "PARALLEL AGENTS MODE  ($AGENTS agents)" "$CYAN"

    # Parse plan for independent tasks
    ALL_PLAN_LINES=()
    INDEPENDENT_LINES=()
    DEPENDENT_LINES=()
    while IFS= read -r pline; do
        if [[ "$pline" =~ ^[0-9] ]]; then
            ALL_PLAN_LINES+=("$pline")
            if echo "$pline" | grep -qi "depends:[[:space:]]*none"; then
                INDEPENDENT_LINES+=("$pline")
            elif echo "$pline" | grep -qi "depends:"; then
                DEPENDENT_LINES+=("$pline")
            fi
        fi
    done < "$PLAN_FILE"

    if [[ "${#INDEPENDENT_LINES[@]}" -eq 0 ]]; then
        write_log "No independent tasks (depends: none) found in plan. Falling back to single-agent mode." "$YELLOW"
        AGENTS=1
    fi
fi

if [[ "$AGENTS" -gt 1 && "$RESUME_MODE" != "true" ]]; then
    NUM_AGENTS=$AGENTS
    if [[ "${#INDEPENDENT_LINES[@]}" -lt "$NUM_AGENTS" ]]; then
        NUM_AGENTS="${#INDEPENDENT_LINES[@]}"
        write_log "Only ${#INDEPENDENT_LINES[@]} independent task(s) found — using $NUM_AGENTS agent(s)." "$YELLOW"
    fi

    write_log "Independent tasks: ${#INDEPENDENT_LINES[@]}  |  Dependent tasks: ${#DEPENDENT_LINES[@]}  |  Agents: $NUM_AGENTS" "$CYAN"

    # Split independent tasks round-robin across agents
    agent_tasks=()
    for (( a=0; a<NUM_AGENTS; a++ )); do agent_tasks[$a]=""; done
    tidx=0
    for task in "${INDEPENDENT_LINES[@]}"; do
        aidx=$((tidx % NUM_AGENTS))
        if [[ -n "${agent_tasks[$aidx]}" ]]; then
            agent_tasks[$aidx]="${agent_tasks[$aidx]}
$task"
        else
            agent_tasks[$aidx]="$task"
        fi
        ((tidx++)) || true
    done

    # Spawn background agents
    agent_pids=()
    agent_output_files=()
    for (( a=1; a<=NUM_AGENTS; a++ )); do
        agent_log="$WORK_DIR/orchclaude-log-agent${a}.txt"
        agent_worksubdir="$WORK_DIR/agent-$a"
        agent_output_file="/tmp/orchclaude_agent${a}_output_$$.txt"
        agent_output_files[$a]="$agent_output_file"

        printf 'orchclaude parallel agent %d log\nStarted: %s\n\n' "$a" "$(date)" > "$agent_log"
        mkdir -p "$agent_worksubdir"

        task_text="${agent_tasks[$((a-1))]}"

        AGENT_PROMPT="## PARALLEL AGENT $a of $NUM_AGENTS

You are one of $NUM_AGENTS parallel Claude agents working on the same project simultaneously.
Work ONLY on the subtasks assigned to you below. Do NOT implement tasks assigned to other agents.

## YOUR ASSIGNED SUBTASKS:
$task_text

## FULL PROJECT CONTEXT:
$BASE_PROMPT

## YOUR WORKING SUBDIRECTORY:
Create your output files under: $agent_worksubdir
When referencing the project root, use: $WORK_DIR

$ORCHESTRATION_INSTRUCTIONS

Remember: work ONLY on your assigned subtasks above."

        (
            out=$(invoke_claude "$AGENT_PROMPT" "agent${a}")
            printf '%s' "$out" > "${agent_output_files[$a]}"
            {
                echo "--- Agent $a Claude output ---"
                echo "$out"
                echo ""
                echo "Finished: $(date)"
            } >> "$agent_log"
        ) &
        agent_pids[$a]=$!
        write_log "Agent $a started  |  log: orchclaude-log-agent${a}.txt" "$CYAN"
    done

    # Wait for all agents
    write_log "Waiting for $NUM_AGENTS agent(s) to complete..." "$YELLOW"
    agent_outputs=()
    for (( a=1; a<=NUM_AGENTS; a++ )); do
        elapsed=$((SECONDS - SCRIPT_START))
        remaining=$((TIMEOUT_SECONDS - elapsed))
        remaining=$((remaining < 10 ? 10 : remaining))

        if wait "${agent_pids[$a]}" 2>/dev/null; then
            agent_out=$(cat "${agent_output_files[$a]}" 2>/dev/null || echo "")
            TOTAL_OUTPUT_WORDS=$((TOTAL_OUTPUT_WORDS + $(get_word_count "$agent_out")))
            agent_outputs[$a]="$agent_out"
            write_log "Agent $a finished." "$GREEN"
        else
            agent_outputs[$a]="(AGENT TIMED OUT)"
            write_log "Agent $a timed out." "$RED"
            kill "${agent_pids[$a]}" 2>/dev/null || true
        fi
        rm -f "${agent_output_files[$a]}"
    done

    # Log agent outputs
    for (( a=1; a<=NUM_AGENTS; a++ )); do
        echo "--- Parallel agent $a output ---" >> "$LOG_FILE"
        echo "${agent_outputs[$a]}"             >> "$LOG_FILE"
        echo ""                                 >> "$LOG_FILE"
    done

    # Build summary for merge
    AGENT_SUMMARY_BLOCKS=""
    for (( a=1; a<=NUM_AGENTS; a++ )); do
        AGENT_SUMMARY_BLOCKS="${AGENT_SUMMARY_BLOCKS}

=== AGENT $a OUTPUT ===
${agent_outputs[$a]}"
    done

    DEPENDENT_SECTION=""
    if [[ "${#DEPENDENT_LINES[@]}" -gt 0 ]]; then
        DEPENDENT_SECTION="

## REMAINING DEPENDENT TASKS (not yet done — complete these now):
$(printf '%s\n' "${DEPENDENT_LINES[@]}")"
    fi

    # Check timeout before merge
    elapsed=$((SECONDS - SCRIPT_START))
    if [[ "$elapsed" -ge "$TIMEOUT_SECONDS" ]]; then
        write_banner "TIMEOUT before merge phase" "$RED"
        write_session "timeout" "$I"
        show_cost_estimate
        show_worktree_branch_info
        send_webhook "timeout"
        write_history "timeout"
        exit 1
    fi

    write_banner "MERGE PHASE" "$CYAN"
    write_log "Integrating agent outputs..." "$CYAN"

    MERGE_PROMPT="## MERGE PHASE — Parallel Agent Integration

You are integrating the work of $NUM_AGENTS parallel agents that each completed different independent subtasks of the same project.

## ORIGINAL TASK:
$BASE_PROMPT

## AGENT OUTPUTS:
$AGENT_SUMMARY_BLOCKS
$DEPENDENT_SECTION

## YOUR JOB:
1. Read all files in $WORK_DIR and its agent-* subdirectories.
2. Integrate each agent's output into the main project under $WORK_DIR.
3. Resolve any conflicts. For conflicts requiring human review, print: CONFLICT: <description>
4. Complete any remaining dependent tasks listed above (they depend on the agents' work).
5. Verify the integrated result is coherent and complete.
6. When done, output exactly: $TOKEN"

    TOTAL_INPUT_WORDS=$((TOTAL_INPUT_WORDS + $(get_word_count "$MERGE_PROMPT")))
    write_log "Calling Claude (merge)..." "$CYAN"
    write_log "MODEL: sonnet (merge)" "$DCYAN"
    MERGE_OUTPUT=$(invoke_claude "$MERGE_PROMPT" "merge" "$(resolve_model_id standard)")
    TOTAL_OUTPUT_WORDS=$((TOTAL_OUTPUT_WORDS + $(get_word_count "$MERGE_OUTPUT")))

    [[ "$V" == "true" ]] && printf '%s\n' "$MERGE_OUTPUT"

    while IFS= read -r mline; do
        [[ "$mline" =~ ^CONFLICT: ]] && write_log "$mline" "$RED"
        if [[ "$mline" =~ ^PROGRESS: ]]; then
            echo "$mline" >> "$PROGRESS_FILE"
            write_log "$mline" "$GREEN"
        fi
    done <<< "$MERGE_OUTPUT"

    echo "--- Merge phase ---"  >> "$LOG_FILE"
    echo "$MERGE_OUTPUT"        >> "$LOG_FILE"
    echo ""                     >> "$LOG_FILE"

    if echo "$MERGE_OUTPUT" | grep -qF "$TOKEN"; then
        write_banner "Parallel build complete — agents merged" "$GREEN"
        write_session "complete" "$I"
    else
        write_banner "Merge phase did not produce completion token — check log" "$RED"
        write_session "timeout" "$I"
        show_cost_estimate
        show_worktree_branch_info
        send_webhook "failed"
        write_history "failed"
        exit 1
    fi

    # QA in parallel mode
    if [[ "$NOQA" != "true" ]]; then
        # 7.3: Budget check before QA phase
        check_budget "$I"

        write_banner "PHASE 2 - QA + EDGE CASE EVALUATION" "$MAGENTA"
        elapsed=$((SECONDS - SCRIPT_START))
        if [[ "$elapsed" -ge "$TIMEOUT_SECONDS" ]]; then
            write_session "timeout" "$I"
            write_banner "TIMEOUT before QA phase could run" "$RED"
            show_cost_estimate
            show_worktree_branch_info
            send_webhook "timeout"
            write_history "timeout"
            exit 1
        fi
        remaining_min=$(python3 -c "print(round(($TIMEOUT_SECONDS - $elapsed) / 60, 1))" 2>/dev/null || echo "?")
        write_log "Running QA pass...  ${remaining_min}m remaining" "$MAGENTA"

        QA_PROMPT="## QA PHASE - Error Cases and Edge Case Evaluation

The build phase is complete. Working directory: $WORK_DIR

Your job now is to act as a QA engineer and adversarial tester.

### What to do:
1. Read every output file that was just produced in: $WORK_DIR
2. Think through error cases and edge cases — things a normal user or bad input could trigger.
3. For EACH issue found: fix it directly in the file(s). Do not just report — fix.
4. Print each finding as: QA_FINDING: <description of issue and fix applied>

### Edge case categories to check (apply what is relevant):
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
  $QA_TOKEN"

        TOTAL_INPUT_WORDS=$((TOTAL_INPUT_WORDS + $(get_word_count "$QA_PROMPT")))
        write_log "MODEL: sonnet (QA)" "$DCYAN"
        QA_OUT=$(invoke_claude "$QA_PROMPT" "qa_parallel" "$(resolve_model_id standard)")
        TOTAL_OUTPUT_WORDS=$((TOTAL_OUTPUT_WORDS + $(get_word_count "$QA_OUT")))

        [[ "$V" == "true" ]] && printf '%s\n' "$QA_OUT"
        while IFS= read -r qline; do
            [[ "$qline" =~ ^QA_FINDING: ]] && write_log "$qline" "$DYELLOW"
            [[ "$qline" =~ ^QA_SUMMARY: ]] && write_log "$qline" "$CYAN"
        done <<< "$QA_OUT"
        echo "--- QA pass (parallel mode) ---" >> "$LOG_FILE"
        echo "$QA_OUT"                         >> "$LOG_FILE"
        echo ""                                >> "$LOG_FILE"
        if echo "$QA_OUT" | grep -qF "$QA_TOKEN"; then
            write_log "QA pass complete." "$GREEN"
        else
            write_log "QA pass did not output $QA_TOKEN — check log for details." "$RED"
        fi
    else
        write_banner "QA skipped (-noqa flag)" "$DGRAY"
    fi

    write_session "complete" "$I"
    TOTAL_TIME=$(python3 -c "s=$((SECONDS - SCRIPT_START)); print(f'{s//60:02d}:{s%60:02d}')" 2>/dev/null || echo "?")
    show_cost_estimate
    write_banner "ALL DONE  |  $TOTAL_TIME total" "$GREEN"
    send_webhook "complete"
    write_history "complete"

    if [[ "$USE_WORKTREE" == "true" ]]; then
        printf "\n"
        read -r -p "Merge branch '$WORKTREE_BRANCH' into '$ORIGINAL_BRANCH'? (y/n): " merge_choice
        if [[ "${merge_choice,,}" == "y" ]]; then
            write_log "Removing worktree and merging $WORKTREE_BRANCH into $ORIGINAL_BRANCH..." "$CYAN"
            git -C "$ORIGINAL_WORK_DIR" worktree remove "$WORKTREE_PATH" --force > /dev/null 2>&1 || true
            if git -C "$ORIGINAL_WORK_DIR" merge "$WORKTREE_BRANCH" --no-ff -m "orchclaude: merge $WORKTREE_BRANCH" > /dev/null 2>&1; then
                write_log "Merge complete. Branch '$WORKTREE_BRANCH' merged into '$ORIGINAL_BRANCH'." "$GREEN"
                git -C "$ORIGINAL_WORK_DIR" branch -d "$WORKTREE_BRANCH" > /dev/null 2>&1 || true
            else
                write_log "Merge failed. Branch '$WORKTREE_BRANCH' preserved." "$RED"
                write_log "To merge manually: git -C \"$ORIGINAL_WORK_DIR\" merge $WORKTREE_BRANCH" "$YELLOW"
            fi
        else
            write_log "Merge skipped. Branch '$WORKTREE_BRANCH' preserved." "$YELLOW"
            write_log "To merge later: git -C \"$ORIGINAL_WORK_DIR\" merge $WORKTREE_BRANCH" "$YELLOW"
            git -C "$ORIGINAL_WORK_DIR" worktree remove "$WORKTREE_PATH" --force > /dev/null 2>&1 || true
        fi
    fi
    exit 0
fi

# ================================================================== #
# PHASE 1 — BUILD
# ================================================================== #
write_banner "PHASE 1 - BUILD" "$YELLOW"

COMPLETED=false
FAILURE_STREAK=0

# 7.2 — Adaptive Escalation state
ESCALATION_FLOOR=""
ESCALATED_TO_STANDARD=false
ESCALATED_TO_HEAVY=false
NO_PROGRESS_STREAK=0

for (( iter=START_ITER; iter<=I; iter++ )); do

    elapsed=$((SECONDS - SCRIPT_START))
    if [[ "$elapsed" -ge "$TIMEOUT_SECONDS" ]]; then
        elapsed_min=$(python3 -c "print(round($elapsed/60,1))" 2>/dev/null || echo "?")
        write_banner "TIMEOUT in build phase after ${elapsed_min} min" "$RED"
        write_session "timeout" "$iter"
        show_cost_estimate
        send_webhook "timeout"
        write_history "timeout"
        break
    fi

    remaining_min=$(python3 -c "print(round(($TIMEOUT_SECONDS - $elapsed) / 60, 1))" 2>/dev/null || echo "?")
    write_banner "Build iteration $iter / $I  -  ${remaining_min}m left" "$YELLOW"

    PRIOR_PROGRESS=""
    [[ -f "$PROGRESS_FILE" ]] && PRIOR_PROGRESS=$(cat "$PROGRESS_FILE")
    PROGRESS_COUNT_BEFORE=0
    [[ -f "$PROGRESS_FILE" ]] && PROGRESS_COUNT_BEFORE=$(grep -cE '\S' "$PROGRESS_FILE" 2>/dev/null || echo 0)

    SAVED_PLAN=""
    [[ -f "$PLAN_FILE" ]] && SAVED_PLAN=$(cat "$PLAN_FILE")
    PLAN_SECTION=""
    [[ -n "$SAVED_PLAN" ]] && PLAN_SECTION="## PROJECT PLAN (follow this order):
$SAVED_PLAN

"

    if [[ -n "$PRIOR_PROGRESS" ]]; then
        FULL_PROMPT="${PLAN_SECTION}${BASE_PROMPT}
${ORCHESTRATION_INSTRUCTIONS}

## PRIOR PROGRESS (completed in earlier iterations - do not redo):
$PRIOR_PROGRESS

Continue from where you left off. Output $TOKEN when everything is done."
    else
        FULL_PROMPT="${PLAN_SECTION}${BASE_PROMPT}
${ORCHESTRATION_INSTRUCTIONS}"
    fi

    # ---- Context Window Guard ----
    ESTIMATED_WORDS=$(get_word_count "$FULL_PROMPT")
    ESTIMATED_TOKENS=$(python3 -c "print(round($ESTIMATED_WORDS * 1.33))" 2>/dev/null || echo 0)
    if [[ "$ESTIMATED_TOKENS" -gt 150000 && -n "$PRIOR_PROGRESS" ]]; then
        write_log "CONTEXT GUARD: prompt is ~${ESTIMATED_TOKENS} tokens — compressing progress log..." "$DYELLOW"

        COMPRESSION_PROMPT="Summarize these progress notes in 10 concise bullet points. Output only the bullet points, no preamble, no explanation:

$PRIOR_PROGRESS"
        TOTAL_INPUT_WORDS=$((TOTAL_INPUT_WORDS + $(get_word_count "$COMPRESSION_PROMPT")))
        write_log "MODEL: haiku (context compression)" "$DCYAN"
        COMPRESSED_RAW=$(invoke_claude "$COMPRESSION_PROMPT" "compress_${iter}" "$(resolve_model_id light)")
        TOTAL_OUTPUT_WORDS=$((TOTAL_OUTPUT_WORDS + $(get_word_count "$COMPRESSED_RAW")))

        if [[ -n "$COMPRESSED_RAW" ]]; then
            printf '%s\n' "$COMPRESSED_RAW" > "$PROGRESS_FILE"
            COMPRESSED_LINES=$(grep -cE '\S' "$PROGRESS_FILE" 2>/dev/null || echo 0)
            write_log "CONTEXT GUARD: progress compressed to $COMPRESSED_LINES lines. Continuing." "$DYELLOW"
            echo "--- Context Guard compression at iteration $iter ---" >> "$LOG_FILE"
            echo "$COMPRESSED_RAW"                                       >> "$LOG_FILE"
            echo ""                                                       >> "$LOG_FILE"

            PRIOR_PROGRESS=$(cat "$PROGRESS_FILE")
            FULL_PROMPT="${PLAN_SECTION}${BASE_PROMPT}
${ORCHESTRATION_INSTRUCTIONS}
## PRIOR PROGRESS (completed in earlier iterations - do not redo):
$PRIOR_PROGRESS

Continue from where you left off. Output $TOKEN when everything is done."
        else
            write_log "CONTEXT GUARD: compression returned empty result — continuing with original." "$RED"
        fi
    fi

    has_prior="$( [[ -n "$PRIOR_PROGRESS" ]] && echo true || echo false )"
    BUILD_TIER="$( [[ -n "$MODEL_OVERRIDE" ]] && echo "$MODEL_OVERRIDE" || get_task_tier "$FULL_PROMPT" "$iter" "$has_prior" )"

    # 7.2: Apply escalation floor
    if [[ -z "$MODEL_OVERRIDE" && "$NO_ESCALATION" == "false" ]]; then
        if   [[ "$ESCALATION_FLOOR" == "heavy"    && "$BUILD_TIER" != "heavy"    ]]; then BUILD_TIER="heavy"
        elif [[ "$ESCALATION_FLOOR" == "standard" && "$BUILD_TIER" == "light"    ]]; then BUILD_TIER="standard"
        fi
    fi

    BUILD_MODEL_ID="$(resolve_model_id "$BUILD_TIER")"
    BUILD_LABEL="$(tier_label "$BUILD_MODEL_ID")"
    write_log "MODEL: $BUILD_LABEL (build iter $iter)" "$DCYAN"
    echo "[$(date +%H:%M:%S)] MODEL: $BUILD_LABEL (build iter $iter)" >> "$LOG_FILE"
    write_log "Calling Claude (build)..." "$YELLOW"
    TOTAL_INPUT_WORDS=$((TOTAL_INPUT_WORDS + $(get_word_count "$FULL_PROMPT")))
    OUTPUT=$(invoke_claude "$FULL_PROMPT" "build_${iter}" "$BUILD_MODEL_ID")
    TOTAL_OUTPUT_WORDS=$((TOTAL_OUTPUT_WORDS + $(get_word_count "$OUTPUT")))

    # ---- 1.6: Usage Limit Detection ----
    if test_usage_limit_error "$OUTPUT"; then
        if handle_usage_limit "$iter"; then
            continue  # autowait completed — re-run this iteration
        fi
        break  # non-autowait paths already called exit
    fi

    [[ "$V" == "true" ]] && printf '%s\n' "$OUTPUT"

    while IFS= read -r oline; do
        if [[ "$oline" =~ ^PROGRESS: ]]; then
            echo "$oline" >> "$PROGRESS_FILE"
            write_log "$oline" "$GREEN"
        fi
    done <<< "$OUTPUT"

    echo "--- Build iteration $iter ---" >> "$LOG_FILE"
    echo "$OUTPUT"                       >> "$LOG_FILE"
    echo ""                              >> "$LOG_FILE"

    PROGRESS_COUNT_AFTER=$(grep -cE '\S' "$PROGRESS_FILE" 2>/dev/null || echo 0)

    if [[ "$PROGRESS_COUNT_AFTER" -gt "$PROGRESS_COUNT_BEFORE" ]]; then
        FAILURE_STREAK=0
        NO_PROGRESS_STREAK=0

        # Auto-Commit Checkpoint (3.2)
        if [[ "$USE_WORKTREE" == "true" ]]; then
            GIT_STATUS=$(git -C "$WORKTREE_PATH" status --porcelain 2>/dev/null || echo "")
            if [[ -n "$GIT_STATUS" ]]; then
                LAST_PROGRESS_LINE=$(grep -E '\S' "$PROGRESS_FILE" 2>/dev/null | tail -1 || echo "iteration $iter")
                COMMIT_MSG="orchclaude checkpoint: $LAST_PROGRESS_LINE"
                git -C "$WORKTREE_PATH" add -A > /dev/null 2>&1 || true
                if git -C "$WORKTREE_PATH" commit -m "$COMMIT_MSG" > /dev/null 2>&1; then
                    COMMIT_HASH=$(git -C "$WORKTREE_PATH" rev-parse --short HEAD 2>/dev/null || echo "?")
                    write_log "Checkpoint committed [$COMMIT_HASH]: $LAST_PROGRESS_LINE" "$DCYAN"
                    echo "--- Checkpoint commit $COMMIT_HASH (iter $iter) ---" >> "$LOG_FILE"
                else
                    write_log "Checkpoint commit failed (no changes or git error)." "$DYELLOW"
                fi
            fi
        fi
    else
        FAILURE_STREAK=$((FAILURE_STREAK + 1))
        NO_PROGRESS_STREAK=$((NO_PROGRESS_STREAK + 1))

        # 7.2: Adaptive Escalation — escalate after 2 consecutive no-progress iterations
        if [[ -z "$MODEL_OVERRIDE" && "$NO_ESCALATION" == "false" && "$NO_PROGRESS_STREAK" -ge 2 ]]; then
            if [[ "$BUILD_TIER" == "light" && "$ESCALATED_TO_STANDARD" == "false" ]]; then
                ESCALATED_TO_STANDARD=true
                ESCALATION_FLOOR="standard"
                NO_PROGRESS_STREAK=0
                ESC_MSG="ESCALATED: haiku -> sonnet (no progress after 2 iterations)"
                write_log "$ESC_MSG" "$YELLOW"
                echo "[$(date +%H:%M:%S)] $ESC_MSG" >> "$LOG_FILE"
            elif [[ "$BUILD_TIER" == "standard" && "$ESCALATED_TO_HEAVY" == "false" ]]; then
                ESCALATED_TO_HEAVY=true
                ESCALATION_FLOOR="heavy"
                NO_PROGRESS_STREAK=0
                ESC_MSG="ESCALATED: sonnet -> opus (no progress after 2 iterations)"
                write_log "$ESC_MSG" "$YELLOW"
                echo "[$(date +%H:%M:%S)] $ESC_MSG" >> "$LOG_FILE"
            fi
        fi
    fi

    write_session "running" "$iter"

    if echo "$OUTPUT" | grep -qF "$TOKEN"; then
        BUILD_ELAPSED=$((SECONDS - SCRIPT_START))
        BUILD_TIME=$(python3 -c "s=$BUILD_ELAPSED; print(f'{s//60:02d}:{s%60:02d}')" 2>/dev/null || echo "?")
        write_banner "Build complete — $iter iteration(s)  |  $BUILD_TIME elapsed" "$GREEN"
        COMPLETED=true
        break
    fi

    # Circuit breaker
    if [[ "$BREAKER" -gt 0 && "$FAILURE_STREAK" -ge "$BREAKER" ]]; then
        write_banner "CIRCUIT BREAKER: Claude has not made progress in $FAILURE_STREAK iterations" "$RED"
        ALL_PROGRESS=()
        [[ -f "$PROGRESS_FILE" ]] && while IFS= read -r pline; do
            [[ "$pline" =~ [^[:space:]] ]] && ALL_PROGRESS+=("$pline")
        done < "$PROGRESS_FILE"
        printf "${YELLOW}Last known progress:${NC}\n"
        if [[ "${#ALL_PROGRESS[@]}" -eq 0 ]]; then
            printf "${DGRAY}  (no progress lines logged yet)${NC}\n"
        else
            for pline in "${ALL_PROGRESS[@]: -3}"; do
                printf "${YELLOW}  %s${NC}\n" "$pline"
            done
        fi
        printf "\n"
        read -r -p "Continue? (y/n/new prompt): " user_choice
        case "${user_choice,,}" in
            n)
                write_log "User stopped run at circuit breaker." "$RED"
                write_session "timeout" "$iter"
                show_cost_estimate
                show_worktree_branch_info
                send_webhook "failed"
                write_history "failed"
                exit 1
                ;;
            ""|y)
                write_log "User chose to continue. Resetting failure streak." "$CYAN"
                FAILURE_STREAK=0
                ;;
            *)
                BASE_PROMPT="${BASE_PROMPT}

## Additional instruction from user:
${user_choice}"
                write_log "User added prompt: $user_choice" "$CYAN"
                FAILURE_STREAK=0
                ;;
        esac
    fi

    # 7.3: Budget check before next iteration
    check_budget "$iter"

    write_log "Token not found. Looping..." "$MAGENTA"
    [[ "$COOLDOWN" -gt 0 ]] && sleep "$COOLDOWN"
done

if [[ "$COMPLETED" != "true" ]]; then
    write_session "timeout" "$I"
    write_banner "BUILD INCOMPLETE — did not finish. See log: $LOG_FILE" "$RED"
    show_cost_estimate
    send_webhook "failed"
    write_history "failed"
    show_worktree_branch_info
    printf "${YELLOW}  Run 'orchclaude resume' to continue this session.${NC}\n"
    exit 1
fi

# ================================================================== #
# PHASE 2 — QA
# ================================================================== #
if [[ "$NOQA" == "true" ]]; then
    write_banner "QA skipped (-noqa flag)" "$DGRAY"
else
    # 7.3: Budget check before QA phase
    check_budget "$I"

    write_banner "PHASE 2 - QA + EDGE CASE EVALUATION" "$MAGENTA"

    elapsed=$((SECONDS - SCRIPT_START))
    if [[ "$elapsed" -ge "$TIMEOUT_SECONDS" ]]; then
        write_session "timeout" "$I"
        write_banner "TIMEOUT before QA phase could run" "$RED"
        show_cost_estimate
        show_worktree_branch_info
        send_webhook "timeout"
        write_history "timeout"
        exit 1
    fi

    remaining_min=$(python3 -c "print(round(($TIMEOUT_SECONDS - $elapsed) / 60, 1))" 2>/dev/null || echo "?")
    write_log "Running QA pass...  ${remaining_min}m remaining" "$MAGENTA"

    QA_PROMPT="## QA PHASE - Error Cases and Edge Case Evaluation

The build phase is complete. Working directory: $WORK_DIR

Your job now is to act as a QA engineer and adversarial tester.

### What to do:
1. Read every output file that was just produced in: $WORK_DIR
2. Think through error cases and edge cases — things a normal user or bad input could trigger.
3. For EACH issue found: fix it directly in the file(s). Do not just report — fix.
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
  $QA_TOKEN"

    TOTAL_INPUT_WORDS=$((TOTAL_INPUT_WORDS + $(get_word_count "$QA_PROMPT")))
    write_log "MODEL: sonnet (QA)" "$DCYAN"
    QA_OUTPUT=$(invoke_claude "$QA_PROMPT" "qa" "$(resolve_model_id standard)")
    TOTAL_OUTPUT_WORDS=$((TOTAL_OUTPUT_WORDS + $(get_word_count "$QA_OUTPUT")))

    [[ "$V" == "true" ]] && printf '%s\n' "$QA_OUTPUT"

    while IFS= read -r qline; do
        [[ "$qline" =~ ^QA_FINDING: ]] && write_log "$qline" "$DYELLOW"
        [[ "$qline" =~ ^QA_SUMMARY: ]] && write_log "$qline" "$CYAN"
    done <<< "$QA_OUTPUT"

    echo "--- QA pass ---" >> "$LOG_FILE"
    echo "$QA_OUTPUT"     >> "$LOG_FILE"
    echo ""               >> "$LOG_FILE"

    if echo "$QA_OUTPUT" | grep -qF "$QA_TOKEN"; then
        write_log "QA pass complete." "$GREEN"
    else
        write_log "QA pass did not output $QA_TOKEN — check log for details." "$RED"
    fi
fi

# ================================================================== #
# DONE
# ================================================================== #
write_session "complete" "$I"
TOTAL_ELAPSED=$((SECONDS - SCRIPT_START))
TOTAL_TIME=$(python3 -c "s=$TOTAL_ELAPSED; print(f'{s//60:02d}:{s%60:02d}')" 2>/dev/null || echo "?")
show_cost_estimate
write_banner "ALL DONE  |  $TOTAL_TIME total" "$GREEN"
send_webhook "complete"
write_history "complete"

if [[ "$USE_WORKTREE" == "true" ]]; then
    printf "\n"
    read -r -p "Merge branch '$WORKTREE_BRANCH' into '$ORIGINAL_BRANCH'? (y/n): " merge_choice
    if [[ "${merge_choice,,}" == "y" ]]; then
        write_log "Removing worktree and merging $WORKTREE_BRANCH into $ORIGINAL_BRANCH..." "$CYAN"
        git -C "$ORIGINAL_WORK_DIR" worktree remove "$WORKTREE_PATH" --force > /dev/null 2>&1 || true
        if git -C "$ORIGINAL_WORK_DIR" merge "$WORKTREE_BRANCH" --no-ff -m "orchclaude: merge $WORKTREE_BRANCH" > /dev/null 2>&1; then
            write_log "Merge complete. Branch '$WORKTREE_BRANCH' merged into '$ORIGINAL_BRANCH'." "$GREEN"
            git -C "$ORIGINAL_WORK_DIR" branch -d "$WORKTREE_BRANCH" > /dev/null 2>&1 || true
        else
            write_log "Merge failed. Branch '$WORKTREE_BRANCH' preserved." "$RED"
            write_log "To merge manually: git -C \"$ORIGINAL_WORK_DIR\" merge $WORKTREE_BRANCH" "$YELLOW"
        fi
    else
        write_log "Merge skipped. Branch '$WORKTREE_BRANCH' preserved." "$YELLOW"
        write_log "To merge later: git -C \"$ORIGINAL_WORK_DIR\" merge $WORKTREE_BRANCH" "$YELLOW"
        git -C "$ORIGINAL_WORK_DIR" worktree remove "$WORKTREE_PATH" --force > /dev/null 2>&1 || true
    fi
fi
