#!/usr/bin/env bash
# Shared helpers for the parallel-dev toolkit. Sourced by every script.
# shellcheck disable=SC2034  # vars here (CANONICAL/REVIEW_DIR/SKILLS_DIR/...) are used by the
#                            # scripts that source this lib, so they look "unused" to a lone check.
set -euo pipefail

CONTROL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_DIR="$(cd "$CONTROL_DIR/.." && pwd)"

# --- project resolution: one engine, many workspaces ------------------------------------------
# Two layouts are supported:
#   workspace : the engine is installed once (e.g. ~/.loop/loop-template) and each project is a
#               small PAYLOAD directory (config.env + secret.env + skills/ + memory/ + runtime
#               state), marked by a `.loop-workspace` file (created by `loop init`). Resolved via
#               $LOOP_PROJECT, else by searching upward from $PWD for the marker.
#   legacy    : the whole template was copied into the project (scaffold.sh). ROOT is control/'s
#               parent and config/secret live inside control/ — exactly the historical behavior.
# Every script goes through $ROOT / $CONFIG_DIR / $CONTROL_DIR; none may hardcode layout.
ROOT=""; CONFIG_DIR=""
if [ -n "${LOOP_PROJECT:-}" ]; then
  [ -d "$LOOP_PROJECT" ] || { echo "ERROR: LOOP_PROJECT='$LOOP_PROJECT' is not a directory" >&2; exit 1; }
  ROOT="$(cd "$LOOP_PROJECT" && pwd)"; CONFIG_DIR="$ROOT"
else
  _d="$PWD"
  while [ "$_d" != "/" ]; do
    if [ -f "$_d/.loop-workspace" ]; then ROOT="$_d"; CONFIG_DIR="$_d"; break; fi
    _d="$(dirname "$_d")"
  done
  unset _d
fi
if [ -z "$ROOT" ]; then  # legacy copy-deployed layout
  ROOT="$ENGINE_DIR"; CONFIG_DIR="$CONTROL_DIR"
fi

STATE_DIR="$ROOT/state"
EXCHANGE_DIR="$ROOT/exchange"
CANONICAL="$ROOT/canonical"
REVIEW_DIR="$ROOT/review"
SKILLS_DIR="$ROOT/skills"
MEMORY_DIR="$ROOT/memory"
LOG_DIR="$STATE_DIR/logs"

# --- load config + secret (no error if absent) ---
if [ -f "$CONFIG_DIR/config.env" ]; then source "$CONFIG_DIR/config.env"; fi
if [ -f "$CONFIG_DIR/secret.env" ]; then source "$CONFIG_DIR/secret.env"; fi

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
# Context-hygiene knobs: cap what the loop feeds back into LLM contexts (planner/worker).
: "${PROGRESS_MAX_LINES:=400}"   # compact memory/PROGRESS.md when it grows past this
: "${PROGRESS_KEEP_LINES:=200}"  # ... keeping this many recent events verbatim
: "${FEEDBACK_MAX_LINES:=200}"   # cap the gate log routed into a worker's feedback.md
: "${WIKI_ENABLED:=1}"           # scoped LLM wiki: slice-owned wiki/modules/ pages + scripted index
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
  local f="$CONFIG_DIR/secret.gate.env" line
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
  progress_compact
}

# Keep PROGRESS.md a bounded, planner-friendly context: the planner reads the WHOLE file every
# cycle, so unbounded append-only growth silently burns tokens and buries fresh signal in stale
# noise. Past PROGRESS_MAX_LINES, fold events older than the last PROGRESS_KEEP_LINES into one
# `# [compacted ...]` count line — except ESCALATED / LAND_FAIL events, which stay verbatim
# (they are unresolved work a future plan must see). Header/summary lines are always preserved.
progress_compact() {
  local f="$MEMORY_DIR/PROGRESS.md"
  [ -f "$f" ] || return 0
  local total; total="$(wc -l < "$f")"
  [ "$total" -gt "${PROGRESS_MAX_LINES:-400}" ] || return 0
  local tmp; tmp="$(mktemp)"
  awk -v keep="${PROGRESS_KEEP_LINES:-200}" -v now="$(now_utc)" '
    # An "event" is a TSV line starting with a UTC timestamp; everything else is header.
    # No {n} interval regex here — mawk (a common /usr/bin/awk) may not support it.
    { line[NR]=$0; isev[NR] = ($0 ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9:]+Z\t/) ? 1 : 0; ev_total += isev[NR] }
    END {
      cutoff = ev_total - keep                 # events beyond this index (1-based) stay verbatim
      seen = 0
      # First: header lines + the summary of folded events, in original order.
      for (i = 1; i <= NR; i++) if (!isev[i]) print line[i]
      # Count folded events (skipping the always-kept kinds).
      for (i = 1; i <= NR; i++) {
        if (!isev[i]) continue
        seen++
        if (seen > cutoff) break
        split(line[i], f_, "\t")
        if (f_[2] == "ESCALATED" || f_[2] == "LAND_FAIL") { keepline[i] = 1; continue }
        cnt[f_[2]]++; folded++
      }
      if (folded > 0) {
        s = "# [compacted " now "] " folded " older events folded:"
        for (k in cnt) s = s " " k "=" cnt[k]
        print s
      }
      # Then: preserved ESCALATED/LAND_FAIL from the folded range + the recent tail, in order.
      seen = 0
      for (i = 1; i <= NR; i++) {
        if (!isev[i]) continue
        seen++
        if (seen <= cutoff) { if (keepline[i]) print line[i]; continue }
        print line[i]
      }
    }' "$f" > "$tmp" && mv "$tmp" "$f"
}

# mtime (epoch) of a worker's push-event marker, or 0 if none yet. The exchange post-receive
# hook bumps this on every worker push; host-side loops poll it (cheap, mount-safe on WSL2).
marker_mtime() { stat -c %Y "$EXCHANGE_DIR/$1.git/push-event" 2>/dev/null || echo 0; }

# Deterministically validate a planner slices.json BEFORE any worker burns tokens on it.
# The prompt asks for disjoint, protected-free paths (advisory, L1); this is the structural
# check (L3) that catches a planner that ignored it — a bad plan otherwise surfaces later as
# merge conflicts (gate exit 3) or land denial (exit 4), each costing a full feedback round.
# Checks: (a) schema — name/brief strings, non-empty paths[], optional tests[];
#         (b) no slice path under/over a PROTECTED_PATHS prefix;
#         (c) paths disjoint ACROSS slices (prefix-overlap in either direction).
# Prints each violation to stderr; returns non-zero on any.
validate_slices() {
  local f="$1"
  jq -e 'type=="array" and length>=1' "$f" >/dev/null 2>&1 \
    || { echo "slices: not a non-empty JSON array" >&2; return 1; }
  jq -e 'all(.[];
        (.name  | type=="string" and length>0)
    and (.brief | type=="string" and length>0)
    and (.paths | type=="array" and length>0 and all(.[]; type=="string" and length>0))
    and ((.tests // []) | type=="array" and all(.[]; type=="string")))' "$f" >/dev/null 2>&1 \
    || { echo "slices: schema violation — every slice needs name, brief, non-empty paths[] (tests[] optional array)" >&2; return 1; }
  jq -r 'to_entries[] | .key as $i | .value.paths[] | "\($i)\t\(.)"' "$f" \
    | awk -F'\t' -v prot="${PROTECTED_PATHS:-}" '
      { idx[NR]=$1; p=$2; sub(/^\.\//, "", p); path[NR]=p }
      END {
        bad = 0
        n = split(prot, pr, /[[:space:]]+/)
        for (i = 1; i <= NR; i++) {
          for (k = 1; k <= n; k++) {
            if (pr[k] != "" && (index(path[i], pr[k]) == 1 || index(pr[k], path[i]) == 1)) {
              printf "slices: slice %s claims protected path: %s (protected: %s)\n", idx[i], path[i], pr[k] > "/dev/stderr"; bad = 1
            }
          }
          for (j = i + 1; j <= NR; j++) {
            if (idx[i] != idx[j] && (index(path[i], path[j]) == 1 || index(path[j], path[i]) == 1)) {
              printf "slices: paths overlap across slices %s and %s: %s vs %s\n", idx[i], idx[j], path[i], path[j] > "/dev/stderr"; bad = 1
            }
          }
        }
        exit bad
      }'
}

# Regenerate memory/REPO_MAP.md from canonical — a deterministic structural map (no Claude, no
# tokens). Called after every land and at setup, so the planner reads a CURRENT map instead of
# exploring /repo from scratch each cycle (and instead of trusting a hand-written, rotting one).
repo_map_refresh() {
  [ -d "$CANONICAL/.git" ] || return 0
  mkdir -p "$MEMORY_DIR"
  {
    echo "# REPO_MAP — auto-generated structural map. Do not edit (regenerated on every land)."
    echo
    echo "Base: $BASE_BRANCH @ $(git -C "$CANONICAL" rev-parse --short HEAD 2>/dev/null || echo '?')  ($(now_utc))"
    echo
    echo "## Directories (tracked-file counts, depth <= 3)"
    echo '```'
    git -C "$CANONICAL" ls-files 2>/dev/null \
      | awk -F/ '{
          if (NF == 1) c["(root)"]++
          else { p = ""; for (i = 1; i < NF && i <= 3; i++) { p = p $i "/"; c[p]++ } }
        } END { for (k in c) printf "%6d  %s\n", c[k], k }' \
      | sort -k2
    echo '```'
  } > "$MEMORY_DIR/REPO_MAP.md"
}

# One-line token-usage note from a `claude -p --output-format json` result file. Field paths
# verified empirically against Claude Code 2.1.x. Prints nothing (and still returns 0) if the
# file is missing or unparsable (e.g. the planner timed out mid-write) — never fails the caller.
plan_usage_note() {
  local f="${1:-}"
  [ -n "$f" ] && [ -f "$f" ] || return 0
  jq -r 'select(type=="object" and .usage != null)
         | "in=\(.usage.input_tokens // 0) out=\(.usage.output_tokens // 0)"
         + " cache_read=\(.usage.cache_read_input_tokens // 0)"
         + " cache_write=\(.usage.cache_creation_input_tokens // 0)"
         + " turns=\(.num_turns // 0) cost_usd=\(.total_cost_usd // 0)"' \
    "$f" 2>/dev/null || true
}

# Deterministically (re)generate wiki/index.md in canonical from each page's frontmatter —
# zero tokens, zero merge conflicts. This is the scoped "LLM wiki" pattern: workers keep their
# slice's wiki/modules/<name>.md fresh as part of DONE (the moment they still hold the full
# implementation context — the cheap moment to write it down), the planner reads index +
# relevant pages instead of re-exploring the codebase, and the index — the one file everyone
# would fight over — is owned by this script instead of any LLM.
wiki_index_refresh() {
  [ "${WIKI_ENABLED:-1}" = 1 ] || return 0
  local wdir="$CANONICAL/wiki"
  [ -d "$wdir" ] || return 0
  local tmp; tmp="$(mktemp)"
  {
    echo "# Wiki Index"
    echo
    echo "> AUTO-GENERATED from page frontmatter on every land — edits here are overwritten."
    echo "> Read this index first, then open ONLY the pages you need. Never bulk-load the wiki."
    local sec t hdr f rel fm typ title sources printed
    for sec in module:Modules concept:Concepts entity:Entities summary:Summaries other:Other; do
      t="${sec%%:*}"; hdr="${sec#*:}"; printed=0
      while IFS= read -r f; do
        rel="${f#"$wdir"/}"
        fm="$(awk '/^---$/{c++; next} c==1{print} c>=2{exit}' "$f")"
        typ="$(sed -n 's/^type:[[:space:]]*//p' <<<"$fm" | head -1 | awk '{print $1}')"
        case "$t" in
          other) case "$typ" in module|concept|entity|summary) continue ;; esac ;;
          *)     [ "$typ" = "$t" ] || continue ;;
        esac
        title="$(sed -n 's/^title:[[:space:]]*//p' <<<"$fm" | head -1)"
        [ -n "$title" ] || title="$(basename "$f" .md)"
        sources="$(awk '/^sources:/{s=1; next} s && /^[^ ]/{s=0} s && /^[[:space:]]*- /{sub(/^[[:space:]]*- /, ""); printf "%s%s", (n++ ? ", " : ""), $0}' <<<"$fm")"
        [ "$printed" = 1 ] || { echo; echo "## $hdr"; printed=1; }
        printf -- '- [%s](%s)%s\n' "$title" "$rel" "${sources:+ — sources: $sources}"
      done < <(find "$wdir" -name '*.md' ! -name 'index.md' | sort)
    done
  } > "$tmp" && mv "$tmp" "$wdir/index.md"
}

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
