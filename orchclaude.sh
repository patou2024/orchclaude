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

invoke_claude() {
    local prompt="$1" label="$2"
    local pfile
    pfile=$(mktemp "/tmp/orchclaude_prompt_$$_${label}.XXXXXX")
    printf '%s' "$prompt" > "$pfile"
    local out
    out=$(claude -p "$(cat "$pfile")" \
        --allowedTools "Edit,Bash,Read,Write,Glob,Grep" \
        --max-turns 50 2>&1) || true
    rm -f "$pfile"
    printf '%s' "$out"
}

show_worktree_branch_info() {
    [[ "$USE_WORKTREE" != "true" ]] && return
    write_log "Worktree branch '$WORKTREE_BRANCH' left intact for inspection." "$YELLOW"
    write_log "Worktree path  : $WORKTREE_PATH" "$YELLOW"
    write_log "To merge later : git -C \"$ORIGINAL_WORK_DIR\" merge $WORKTREE_BRANCH" "$YELLOW"
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
    python3 -c "
import json, sys
d = json.load(open('$PROFILES_FILE')) if __import__('os').path.exists('$PROFILES_FILE') else {}
sys.exit(0 if '$name' in d else 1)
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
SUBARG=""
SHOW_HELP=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        -f)        F="${2:-}";           shift 2 ;;
        -t)        T="${2:-}";           shift 2 ;;
        -i)        I="${2:-}";           shift 2 ;;
        -v)        V=true;               shift   ;;
        -d)        D="${2:-}";           shift 2 ;;
        -noqa)     NOQA=true;            shift   ;;
        -token)    TOKEN="${2:-}";       shift 2 ;;
        -cooldown) COOLDOWN="${2:-}";    shift 2 ;;
        -breaker)  BREAKER="${2:-}";     shift 2 ;;
        -dryrun)   DRYRUN=true;          shift   ;;
        -noplan)   NOPLAN=true;          shift   ;;
        -nobranch) NOBRANCH=true;        shift   ;;
        -profile)  PROFILE_NAME="${2:-}"; shift 2 ;;
        -agents)   AGENTS="${2:-}";      shift 2 ;;
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
        printf "\nFlags: -t -i -f -d -v -noqa -token -cooldown -breaker -dryrun -noplan -nobranch -profile -agents\n"
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
            updated=$(python3 - <<PYEOF
import json, sys
d = $profiles_json
d["$SUBARG"] = {
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
            updated=$(python3 -c "
import json
d = $profiles_json
d.pop('$SUBARG', None)
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
# Load named profile
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
PYEOF
)"
    # Apply profile values (CLI defaults win over profile only if CLI was explicitly set)
    [[ "$T"        == "30m"                    ]] && T="$_P_T"
    [[ "$I"        == "40"                     ]] && I=$_P_I
    [[ -z "$D"                                 ]] && D="$_P_D"
    [[ "$V"        == "false"                  ]] && V="$_P_V"
    [[ "$NOQA"     == "false"                  ]] && NOQA="$_P_NOQA"
    [[ "$TOKEN"    == "ORCHESTRATION_COMPLETE" ]] && TOKEN="$_P_TOKEN"
    [[ "$COOLDOWN" == "5"                      ]] && COOLDOWN=$_P_COOLDOWN
    [[ "$BREAKER"  == "10"                     ]] && BREAKER=$_P_BREAKER
    [[ "$NOPLAN"   == "false"                  ]] && NOPLAN="$_P_NOPLAN"
    [[ "$NOBRANCH" == "false"                  ]] && NOBRANCH="$_P_NOBRANCH"
    [[ "$AGENTS"   == "1"                      ]] && AGENTS=$_P_AGENTS
fi

# ------------------------------------------------------------------ #
# Validate agents flag
# ------------------------------------------------------------------ #
if [[ ! "$AGENTS" =~ ^[0-9]+$ ]] || [[ "$AGENTS" -lt 1 ]]; then
    printf "${RED}Bad -agents value '%s'. Must be a positive integer.${NC}\n" "$AGENTS" >&2
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
# Validate command
# ------------------------------------------------------------------ #
if [[ "$RESUME_MODE" != "true" && "$COMMAND" != "run" ]]; then
    printf "${RED}Unknown command '%s'. Use: orchclaude run, resume, status, help, profile${NC}\n" "$COMMAND" >&2
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

if [[ "$NOBRANCH" != "true" && "$RESUME_MODE" != "true" && "$DRYRUN" != "true" ]]; then
    if git -C "$WORK_DIR" rev-parse --git-dir > /dev/null 2>&1; then
        IS_GIT_REPO=true
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
[[ -n "$PROFILE_NAME" ]] && write_log "Profile   : $PROFILE_NAME (loaded from $PROFILES_FILE)" "$CYAN"
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
    PLAN_OUTPUT=$(invoke_claude "$PLANNING_PROMPT" "plan")
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
    MERGE_OUTPUT=$(invoke_claude "$MERGE_PROMPT" "merge")
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
        exit 1
    fi

    # QA in parallel mode
    if [[ "$NOQA" != "true" ]]; then
        write_banner "PHASE 2 - QA + EDGE CASE EVALUATION" "$MAGENTA"
        elapsed=$((SECONDS - SCRIPT_START))
        if [[ "$elapsed" -ge "$TIMEOUT_SECONDS" ]]; then
            write_session "timeout" "$I"
            write_banner "TIMEOUT before QA phase could run" "$RED"
            show_cost_estimate
            show_worktree_branch_info
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
        QA_OUT=$(invoke_claude "$QA_PROMPT" "qa_parallel")
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

for (( iter=START_ITER; iter<=I; iter++ )); do

    elapsed=$((SECONDS - SCRIPT_START))
    if [[ "$elapsed" -ge "$TIMEOUT_SECONDS" ]]; then
        elapsed_min=$(python3 -c "print(round($elapsed/60,1))" 2>/dev/null || echo "?")
        write_banner "TIMEOUT in build phase after ${elapsed_min} min" "$RED"
        write_session "timeout" "$iter"
        show_cost_estimate
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
        COMPRESSED_RAW=$(invoke_claude "$COMPRESSION_PROMPT" "compress_${iter}")
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

    write_log "Calling Claude (build)..." "$YELLOW"
    TOTAL_INPUT_WORDS=$((TOTAL_INPUT_WORDS + $(get_word_count "$FULL_PROMPT")))
    OUTPUT=$(invoke_claude "$FULL_PROMPT" "build_${iter}")
    TOTAL_OUTPUT_WORDS=$((TOTAL_OUTPUT_WORDS + $(get_word_count "$OUTPUT")))

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

    write_log "Token not found. Looping..." "$MAGENTA"
    [[ "$COOLDOWN" -gt 0 ]] && sleep "$COOLDOWN"
done

if [[ "$COMPLETED" != "true" ]]; then
    write_session "timeout" "$I"
    write_banner "BUILD INCOMPLETE — did not finish. See log: $LOG_FILE" "$RED"
    show_cost_estimate
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
    write_banner "PHASE 2 - QA + EDGE CASE EVALUATION" "$MAGENTA"

    elapsed=$((SECONDS - SCRIPT_START))
    if [[ "$elapsed" -ge "$TIMEOUT_SECONDS" ]]; then
        write_session "timeout" "$I"
        write_banner "TIMEOUT before QA phase could run" "$RED"
        show_cost_estimate
        show_worktree_branch_info
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
    QA_OUTPUT=$(invoke_claude "$QA_PROMPT" "qa")
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
