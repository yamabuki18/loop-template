#!/usr/bin/env bash
# Shared helpers for the parallel-dev toolkit. Sourced by every script.
# shellcheck disable=SC2034  # vars here (CANONICAL/REVIEW_DIR/SKILLS_DIR/...) are used by the
#                            # scripts that source this lib, so they look "unused" to a lone check.
set -euo pipefail

CONTROL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$CONTROL_DIR/.." && pwd)"
STATE_DIR="$ROOT/state"
EXCHANGE_DIR="$ROOT/exchange"
CANONICAL="$ROOT/canonical"
REVIEW_DIR="$ROOT/review"
SKILLS_DIR="$ROOT/skills"
MEMORY_DIR="$ROOT/memory"
LOG_DIR="$STATE_DIR/logs"

# --- load config + secret (no error if absent) ---
if [ -f "$CONTROL_DIR/config.env" ]; then source "$CONTROL_DIR/config.env"; fi
if [ -f "$CONTROL_DIR/secret.env" ]; then source "$CONTROL_DIR/secret.env"; fi

: "${PROJECT_NAME:=claudeparallel}"
: "${IMAGE:=claude-worker:latest}"
: "${WORKER_COUNT:=3}"
: "${BASE_BRANCH:=main}"
: "${SESSION:=$PROJECT_NAME}"
: "${ANTHROPIC_API_KEY:=}"
: "${CLAUDE_CODE_OAUTH_TOKEN:=}"
: "${GATE_CACHE:=1}"
: "${PROTECTED_PATHS:=tests/}"
# Loop knobs (defaults mirror config.env so loop scripts work even on an older config).
: "${MAX_FEEDBACK_ROUNDS:=4}"
: "${LOOP_MAX_CYCLES:=0}"
: "${GATE_CONCURRENCY:=2}"
: "${LOOP_POLL_SECS:=5}"
: "${AUTO_SYNC:=1}"
: "${PLANNER_ENABLED:=1}"
: "${PLANNER_MAX_SLICES:=3}"
: "${NOTIFY:=1}"
: "${CLAUDE_CODE_VERSION:=}"
: "${BROKER_PORT:=8080}"
: "${WORKER_EGRESS:=open}"

# --- naming ---
cname()      { echo "cw-${PROJECT_NAME}-$1"; }     # container name
volname()    { echo "cwvol-${PROJECT_NAME}-$1"; }  # /work volume name
gatecache()  { echo "gatecache-${PROJECT_NAME}"; } # shared package-manager download cache
branch_for() { echo "work/$1"; }                   # default branch per task
brokername() { echo "cw-${PROJECT_NAME}-broker"; } # secret-broker container
netname()    { echo "cwnet-${PROJECT_NAME}"; }     # worker<->broker network (internal if egress=broker-only)
extnetname() { echo "cwnet-${PROJECT_NAME}-ext"; } # broker's outbound (internet) network when egress is locked

net_exists() { docker network inspect "$1" >/dev/null 2>&1; }

# Ensure the worker network exists with the right reachability for WORKER_EGRESS.
# open        -> a normal bridge (workers get internet + can reach the broker by name).
# broker-only -> an --internal bridge (workers can reach ONLY containers on it, no internet).
ensure_worker_network() {
  local n; n="$(netname)"
  if ! net_exists "$n"; then
    if [ "${WORKER_EGRESS:-open}" = "broker-only" ]; then
      docker network create --internal "$n" >/dev/null
    else
      docker network create "$n" >/dev/null
    fi
  fi
}

# --- predicates (safe under set -e because used in if/while) ---
container_exists()  { docker ps -a --format '{{.Names}}' | grep -qx "$(cname "$1")"; }
container_running() { docker ps    --format '{{.Names}}' | grep -qx "$(cname "$1")"; }

die() { echo "ERROR: $*" >&2; exit 1; }

# --- credential / billing mode -------------------------------------------------------------
# Two ways to power the in-container Claude (planner + workers):
#   subscription : CLAUDE_CODE_OAUTH_TOKEN set (from `claude setup-token`, Pro/Max) -> draws on
#                  your subscription quota (planner `-p` uses the monthly Agent SDK credit;
#                  interactive workers use the regular interactive limits). NO metered API bill.
#   api          : ANTHROPIC_API_KEY set -> pay-as-you-go metered API billing.
# CRITICAL (Claude Code auth precedence): if ANTHROPIC_API_KEY is present it WINS and forces API
# billing. So in subscription mode we must inject ONLY the OAuth token and NOT the API key.
auth_mode() {
  if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then echo subscription
  elif [ -n "${ANTHROPIC_API_KEY:-}" ]; then echo api
  else echo none; fi
}
have_credential() { [ "$(auth_mode)" != none ]; }

# Emit the docker `-e` flags for the chosen credential, one token per line (mapfile-friendly).
# Exactly one credential is injected; the other is deliberately omitted (see precedence above).
cred_docker_args() {
  if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
    printf '%s\n' "-e" "CLAUDE_CODE_OAUTH_TOKEN=${CLAUDE_CODE_OAUTH_TOKEN}"
  elif [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    printf '%s\n' "-e" "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}"
  fi
}

# Emit docker `-e KEY=VALUE` flags from control/secret.gate.env (KEY=VALUE lines). These secrets
# are injected ONLY into the gate container, which runs deterministic checks (NOT Claude) — so a
# test can use, e.g., a DB URL or test API key that the worker Claude never sees. mapfile-friendly.
gate_secret_docker_args() {
  local f="$CONTROL_DIR/secret.gate.env" line
  [ -f "$f" ] || return 0
  while IFS= read -r line; do
    line="${line%%$'\r'}"
    case "$line" in ''|'#'*) continue ;; esac
    [ "${line#*=}" != "$line" ] || continue
    printf '%s\n' "-e" "$line"
  done < "$f"
}

# --- loop helpers (shared by loop.sh / watch.sh / plan.sh / sync.sh) ---

# All known worker task ids (from state/*.env), one per line.
worker_tasks() {
  shopt -s nullglob
  local f t
  for f in "$STATE_DIR"/*.env; do
    t="$(basename "$f" .env)"; echo "$t"
  done
}

# UTC timestamp (no Math.random/Date restrictions here — this is bash).
now_utc() { date -u +%FT%TZ 2>/dev/null || echo "unknown"; }

# Append one event to memory/PROGRESS.md (the loop's external memory). Tab-separated.
#   progress_log <EVENT> <task/slice> <branch@sha-or-->  <free text note>
progress_log() {
  local ev="${1:-?}" who="${2:--}" ref="${3:--}" note="${4:-}"
  mkdir -p "$MEMORY_DIR"
  [ -f "$MEMORY_DIR/PROGRESS.md" ] || printf '# PROGRESS\n\n## Log\n' > "$MEMORY_DIR/PROGRESS.md"
  printf '%s\t%s\t%s\t%s\t%s\n' "$(now_utc)" "$ev" "$who" "$ref" "$note" >> "$MEMORY_DIR/PROGRESS.md"
}

# mtime (epoch) of a worker's push-event marker, or 0 if none yet. The exchange post-receive
# hook bumps this on every worker push; host-side loops poll it (cheap, mount-safe on WSL2).
marker_mtime() { stat -c %Y "$EXCHANGE_DIR/$1.git/push-event" 2>/dev/null || echo 0; }

# Best-effort, non-blocking notification. Never fails the caller.
notify() {
  local msg="$*"
  [ "${NOTIFY:-1}" = "1" ] || return 0
  tmux has-session -t "$SESSION" 2>/dev/null && tmux display-message "loop: $msg" 2>/dev/null || true
  printf '\a' 2>/dev/null || true
  command -v wsl-notify-send.exe >/dev/null 2>&1 && wsl-notify-send.exe "$msg" >/dev/null 2>&1 || true
  command -v wsl-notify-send    >/dev/null 2>&1 && wsl-notify-send    "$msg" >/dev/null 2>&1 || true
  return 0
}
